import Foundation
import Testing
@testable import VivariumDetect

@Suite("DiscoveryTests")
struct DiscoveryTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VivariumDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createFile(at url: URL, modifiedAt date: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: url)
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    @Test("Only recent non-subagent jsonl files within maxDepth are returned")
    func claudeStyleTree() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let cutoff = now.addingTimeInterval(-3600)
        let old = now.addingTimeInterval(-86_400)

        let recent = root.appendingPathComponent("proj1/recent.jsonl")
        let topLevel = root.appendingPathComponent("top.jsonl")
        try createFile(at: recent, modifiedAt: now)
        try createFile(at: topLevel, modifiedAt: now)

        try createFile(at: root.appendingPathComponent("proj1/stale.jsonl"), modifiedAt: old)
        try createFile(at: root.appendingPathComponent("proj1/notes.txt"), modifiedAt: now)
        try createFile(at: root.appendingPathComponent("subagents/sneaky.jsonl"), modifiedAt: now)
        try createFile(at: root.appendingPathComponent("memory/mem.jsonl"), modifiedAt: now)
        try createFile(at: root.appendingPathComponent("proj1/subagents/nested.jsonl"), modifiedAt: now)
        try createFile(at: root.appendingPathComponent("deep/a/toodeep.jsonl"), modifiedAt: now)
        try createFile(at: root.appendingPathComponent(".hidden/h.jsonl"), modifiedAt: now)

        let found = SessionDiscovery.recentSessionFiles(root: root, modifiedAfter: cutoff, maxDepth: 2)
        let names = found.map(\.lastPathComponent)
        #expect(names == ["recent.jsonl", "top.jsonl"])
    }

    @Test("Codex-style depth-4 tree is reachable with maxDepth 4")
    func codexStyleTree() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let cutoff = now.addingTimeInterval(-3600)

        try createFile(at: root.appendingPathComponent("2026/07/07/rollout.jsonl"), modifiedAt: now)
        try createFile(at: root.appendingPathComponent("2026/07/07/extra/nope.jsonl"), modifiedAt: now)

        let found = SessionDiscovery.recentSessionFiles(root: root, modifiedAfter: cutoff, maxDepth: 4)
        #expect(found.map(\.lastPathComponent) == ["rollout.jsonl"])
    }

    @Test("Missing root yields an empty result")
    func missingRoot() {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("VivariumDiscoveryTests-missing-\(UUID().uuidString)")
        let found = SessionDiscovery.recentSessionFiles(root: ghost, modifiedAfter: .distantPast, maxDepth: 2)
        #expect(found.isEmpty)
    }
}

@Suite("FileActivityStreamTests")
struct FileActivityStreamTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VivariumFSEventsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Races `operation` against a deadline so a broken stream can never hang the suite.
    private func within(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test("A file write is observed within 5s")
    func observesWrite() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("touch.jsonl")

        let stream = FileActivityStream(roots: [dir], latency: 0.05)
        let changes = stream.changes()
        defer { stream.stop() }

        // Re-touch periodically so a write racing FSEventStreamStart still gets observed.
        let toucher = Task {
            for tick in 0..<8 {
                try? Data("tick \(tick)\n".utf8).write(to: target)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { toucher.cancel() }

        let found = await within(seconds: 5) {
            for await change in changes where change.path.hasSuffix("touch.jsonl") {
                return true
            }
            return false
        }
        #expect(found)
    }

    @Test("stop() finishes the stream")
    func stopEndsStream() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = FileActivityStream(roots: [dir], latency: 0.05)
        let changes = stream.changes()
        stream.stop()

        // If stop() didn't finish the stream this drain would block and the race returns false.
        let ended = await within(seconds: 5) {
            for await _ in changes { }
            return true
        }
        #expect(ended)
    }
}
