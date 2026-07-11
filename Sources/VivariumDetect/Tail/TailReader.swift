import Foundation

public enum TailError: Error {
    case fileVanished
}

/// Incremental byte-offset reader for growing JSONL files. Not Sendable — owned by one monitor actor.
public final class TailReader {
    public private(set) var offset: UInt64 = 0

    /// True when the most recent `drainNewLines()` reset the cursor to 0 (in-place truncation or
    /// file replacement). Lets a record-reassembling caller discard stale buffered state.
    public private(set) var didResetOnLastDrain = false

    /// Lines whose bytes weren't valid UTF-8, skipped silently.
    private(set) var skippedInvalidLineCount = 0

    private let url: URL
    private var fileDescriptor: Int32 = -1
    private var fileIdentity: FileIdentity?
    /// Bytes of the trailing partial line, carried across drains until its newline arrives.
    private var remainder: [UInt8] = []
    /// When true, the remainder overflowed (or a backscan started mid-line): drop bytes until the next newline.
    private var isResyncing = false

    private static let chunkSize = 64 * 1024
    private static let maxRemainderBytes = 4 * 1024 * 1024

    private struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    public init(url: URL) {
        self.url = url
    }

    deinit {
        closeFile()
    }

    /// Reads any new complete lines appended since the last call. Handles growth, truncation
    /// (size < offset → reset to 0), replacement (inode change → reopen from 0), and deletion
    /// (throws `TailError.fileVanished`).
    public func drainNewLines() throws -> [String] {
        didResetOnLastDrain = false
        let size = try prepareFile()
        return try readLines(upTo: size)
    }

    /// Seeds a newly-discovered large file near EOF: positions at max(0, size − backscanBytes),
    /// discards the first partial line, and returns the backscan lines for silent state rebuild.
    /// Leaves the reader positioned at EOF (trailing partial held in the remainder buffer).
    public func seedNearEnd(backscanBytes: Int = 262_144) throws -> [String] {
        let size = try prepareFile()
        remainder.removeAll()
        isResyncing = false
        let back = UInt64(max(0, backscanBytes))
        offset = size > back ? size - back : 0
        if offset > 0 && offset < size {
            // Started strictly mid-file: everything up to the first newline is (part of) a line we
            // can't trust. When offset == size (e.g. backscanBytes == 0) we're parked at a clean EOF
            // boundary — arming resync there would drop the first subsequently appended line.
            isResyncing = true
        }
        return try readLines(upTo: size)
    }

    // MARK: - File lifecycle

    /// Ensures an open descriptor pointing at the current file at `url`, resetting state on
    /// replacement or truncation. Returns the current file size.
    private func prepareFile() throws -> UInt64 {
        var pathStat = stat()
        guard stat(url.path, &pathStat) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                closeFile()
                throw TailError.fileVanished
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let pathIdentity = FileIdentity(device: pathStat.st_dev, inode: pathStat.st_ino)
        if let current = fileIdentity, current != pathIdentity {
            // The path now names a different file: the old one was replaced.
            closeFile()
            resetPosition()
        }

        if fileDescriptor < 0 {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else {
                let code = errno
                if code == ENOENT || code == ENOTDIR {
                    throw TailError.fileVanished
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            fileDescriptor = fd
        }

        var fdStat = stat()
        guard fstat(fileDescriptor, &fdStat) == 0 else {
            let code = errno
            closeFile()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        fileIdentity = FileIdentity(device: fdStat.st_dev, inode: fdStat.st_ino)

        let size = fdStat.st_size > 0 ? UInt64(fdStat.st_size) : 0
        if size < offset {
            // Truncated in place.
            resetPosition()
        }
        return size
    }

    private func resetPosition() {
        offset = 0
        remainder.removeAll()
        isResyncing = false
        didResetOnLastDrain = true
    }

    private func closeFile() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        fileIdentity = nil
    }

    // MARK: - Reading

    private func readLines(upTo size: UInt64) throws -> [String] {
        var lines: [String] = []
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while offset < size {
            let wanted = Int(min(UInt64(Self.chunkSize), size - offset))
            let readCount = buffer.withUnsafeMutableBytes { raw in
                pread(fileDescriptor, raw.baseAddress, wanted, off_t(offset))
            }
            if readCount < 0 {
                let code = errno
                if code == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            if readCount == 0 { break }
            offset += UInt64(readCount)
            consume(chunk: buffer[0..<readCount], into: &lines)
        }
        return lines
    }

    private func consume(chunk: ArraySlice<UInt8>, into lines: inout [String]) {
        var lower = chunk.startIndex
        while lower < chunk.endIndex, let newline = chunk[lower...].firstIndex(of: 0x0A) {
            if isResyncing {
                // Drop everything up to and including this newline; the next byte starts a clean line.
                isResyncing = false
            } else {
                remainder.append(contentsOf: chunk[lower..<newline])
                emitLine(into: &lines)
            }
            lower = chunk.index(after: newline)
        }
        guard !isResyncing else { return }
        remainder.append(contentsOf: chunk[lower...])
        if remainder.count > Self.maxRemainderBytes {
            remainder.removeAll(keepingCapacity: false)
            isResyncing = true
        }
    }

    private func emitLine(into lines: inout [String]) {
        var bytes = remainder
        remainder.removeAll(keepingCapacity: true)
        if bytes.last == 0x0D {
            bytes.removeLast()
        }
        if let line = String(bytes: bytes, encoding: .utf8) {
            lines.append(line)
        } else {
            skippedInvalidLineCount += 1
        }
    }
}
