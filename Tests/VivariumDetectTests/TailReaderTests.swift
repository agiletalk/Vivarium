import Foundation
import Testing
@testable import VivariumDetect

@Suite("TailReaderTests")
struct TailReaderTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VivariumTailTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("Append in chunks holds back the partial trailing line")
    func appendInChunks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        try Data("a\nb".utf8).write(to: file)

        let reader = TailReader(url: file)
        #expect(try reader.drainNewLines() == ["a"])
        #expect(reader.offset == 3)

        try append("c\nd\n", to: file)
        #expect(try reader.drainNewLines() == ["bc", "d"])
        #expect(reader.offset == 7)

        #expect(try reader.drainNewLines() == [])
    }

    @Test("Truncation resets the offset to zero")
    func truncationReset() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        try Data("hello\nworld\n".utf8).write(to: file)

        let reader = TailReader(url: file)
        #expect(try reader.drainNewLines() == ["hello", "world"])
        #expect(reader.offset == 12)

        // Truncate in place (same inode) and write shorter content.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("hi\n".utf8))
        try handle.close()

        #expect(try reader.drainNewLines() == ["hi"])
        #expect(reader.offset == 3)
    }

    @Test("File replacement is detected via inode change")
    func fileReplacement() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        try Data("one\n".utf8).write(to: file)

        let reader = TailReader(url: file)
        #expect(try reader.drainNewLines() == ["one"])

        // Remove and recreate: new inode, content of equal length so only the
        // identity check (not the size check) can catch it.
        try FileManager.default.removeItem(at: file)
        try Data("two\n".utf8).write(to: file)

        #expect(try reader.drainNewLines() == ["two"])
        #expect(reader.offset == 4)
    }

    @Test("seedNearEnd returns only tail lines and positions at EOF")
    func seedNearEnd() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.jsonl")

        // 10_486 fixed-width lines of 100 bytes each (~1 MB).
        let lineLength = 100
        let lineCount = 10_486
        var allLines: [String] = []
        allLines.reserveCapacity(lineCount)
        var blob = Data()
        blob.reserveCapacity(lineCount * lineLength)
        for index in 0..<lineCount {
            let prefix = String(format: "%08d-", index)
            let line = prefix + String(repeating: "x", count: lineLength - 1 - prefix.count)
            allLines.append(line)
            blob.append(Data((line + "\n").utf8))
        }
        try blob.write(to: file)

        let backscan = 262_144
        let reader = TailReader(url: file)
        let seeded = try reader.seedNearEnd(backscanBytes: backscan)

        let size = lineCount * lineLength
        let start = size - backscan
        // The line the backscan start falls inside (or exactly at the start of) is discarded.
        let firstFullLine = start / lineLength + 1
        #expect(seeded == Array(allLines[firstFullLine...]))
        #expect(reader.offset == UInt64(size))

        try append("after-1\nafter-2\n", to: file)
        #expect(try reader.drainNewLines() == ["after-1", "after-2"])
    }

    @Test("seedNearEnd on a small file returns everything from the start")
    func seedNearEndSmallFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("small.jsonl")
        try Data("first\nsecond\n".utf8).write(to: file)

        let reader = TailReader(url: file)
        #expect(try reader.seedNearEnd() == ["first", "second"])
        #expect(reader.offset == 13)
    }

    @Test("Deleted file throws fileVanished")
    func fileVanished() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gone.jsonl")
        try Data("line\n".utf8).write(to: file)

        let reader = TailReader(url: file)
        #expect(try reader.drainNewLines() == ["line"])

        try FileManager.default.removeItem(at: file)
        #expect(throws: TailError.fileVanished) {
            try reader.drainNewLines()
        }
    }

    @Test("Invalid UTF-8 lines are skipped, valid neighbors survive")
    func invalidUTF8Skipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mixed.jsonl")
        var data = Data("ok\n".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x0A])
        data.append(Data("fine\n".utf8))
        try data.write(to: file)

        let reader = TailReader(url: file)
        #expect(try reader.drainNewLines() == ["ok", "fine"])
        #expect(reader.skippedInvalidLineCount == 1)
    }

    @Test("Oversized partial line is dropped and the reader resyncs at the next newline")
    func remainderOverflowResync() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("huge.jsonl")

        // 5 MB with no newline: exceeds the 4 MB remainder cap.
        try Data(repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024).write(to: file)

        let reader = TailReader(url: file)
        #expect(try reader.drainNewLines() == [])

        // The tail of the oversized line is dropped up to its newline; the next line survives.
        try append("still-the-huge-line\nclean\n", to: file)
        #expect(try reader.drainNewLines() == ["clean"])
    }
}
