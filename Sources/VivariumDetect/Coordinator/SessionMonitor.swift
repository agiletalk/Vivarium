import Foundation
import VivariumCore

/// Configuration for a transcript-tailing monitor. Overridable for tests.
public struct MonitorConfig: Sendable {
    public var roots: [URL]
    public var maxDepth: Int
    /// Sessions whose files are older than this at startup are ignored.
    public var startupWindow: TimeInterval
    /// A quiet file older than this is considered an ended session.
    public var endedAfter: TimeInterval
    /// After an end-of-turn with no new bytes, promote to waitingForUser.
    public var waitingAfter: TimeInterval
    /// Backbone poll cadence (FSEvents also nudges drains between polls).
    public var pollInterval: Duration

    public init(
        roots: [URL],
        maxDepth: Int,
        startupWindow: TimeInterval = 1800,
        endedAfter: TimeInterval = 1800,
        waitingAfter: TimeInterval = 10,
        pollInterval: Duration = .seconds(2)
    ) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.startupWindow = startupWindow
        self.endedAfter = endedAfter
        self.waitingAfter = waitingAfter
        self.pollInterval = pollInterval
    }

    public static func claude() -> MonitorConfig {
        MonitorConfig(roots: [claudeRoot].compactMap { $0 }, maxDepth: 2)
    }

    public static func codex() -> MonitorConfig {
        MonitorConfig(roots: [codexRoot].compactMap { $0 }, maxDepth: 4)
    }

    static var claudeRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var codexRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Tails one provider's transcript tree and emits semantic `AgentEvent`s.
///
/// FSEvents nudges the poll loop when files change; a 2 s backbone poll (statting only tracked
/// files) covers idle→waiting→ended transitions and any FSEvents gaps after sleep/wake. Newly
/// discovered large files are seeded near EOF and their history is rebuilt silently so the
/// aquarium never replays tens of MB of past activity.
public actor AgentSessionMonitor<P: TranscriptParsing>: AgentEventStreaming {
    private struct TrackedFile {
        var reader: TailReader
        var context: P.Context
        var lastLineAt: Date
        var waitingEmitted: Bool
        var endedEmitted: Bool
        var startedForwarded: Bool
        // Codex subagent files surface as the parent's handoff pearl, not a fish.
        var subagentParentKey: SessionKey?
        var subagentHandoffOpen: Bool
    }

    private let config: MonitorConfig
    private var tracked: [String: TrackedFile] = [:]
    private var fileStream: FileActivityStream?
    private var started = false

    public init(config: MonitorConfig) {
        self.config = config
    }

    public nonisolated func events() -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<AgentEvent>.Continuation) async {
        guard !started else { return }
        started = true

        // Seed already-active sessions silently.
        let cutoff = Date().addingTimeInterval(-config.startupWindow)
        for root in config.roots {
            for url in SessionDiscovery.recentSessionFiles(root: root, modifiedAfter: cutoff, maxDepth: config.maxDepth) {
                seedFile(url, continuation: continuation)
            }
        }

        // FSEvents nudges: coalesce into a signal the poll loop drains.
        let nudges: AsyncStream<FileChange>?
        if !config.roots.isEmpty {
            let stream = FileActivityStream(roots: config.roots, latency: 0.5)
            fileStream = stream
            nudges = stream.changes()
        } else {
            nudges = nil
        }

        await withTaskGroup(of: Void.self) { group in
            if let nudges {
                group.addTask { [weak self] in
                    for await change in nudges {
                        guard let self else { break }
                        await self.handleNudge(change, continuation: continuation)
                    }
                }
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    await self.poll(continuation: continuation)
                    try? await Task.sleep(for: self.config.pollInterval)
                }
            }
            for await _ in group {}
        }
        fileStream?.stop()
    }

    private func handleNudge(_ change: FileChange, continuation: AsyncStream<AgentEvent>.Continuation) {
        guard change.path.hasSuffix(".jsonl") else {
            // A directory changed — a new session file may have appeared; rediscover.
            discoverNew(continuation: continuation)
            return
        }
        // FSEvents resolves symlinks (/private/var/…); match tracked files by suffix.
        if let key = tracked.keys.first(where: { change.path.hasSuffix($0) || $0.hasSuffix(change.path) }) {
            drain(key, continuation: continuation)
        } else {
            discoverNew(continuation: continuation)
        }
    }

    private func poll(continuation: AsyncStream<AgentEvent>.Continuation) {
        let now = Date()
        for key in Array(tracked.keys) {
            drain(key, continuation: continuation)
            guard var file = tracked[key] else { continue }

            // Waiting-for-user promotion.
            if !file.waitingEmitted, P.turnEnded(file.context),
               now.timeIntervalSince(file.lastLineAt) >= config.waitingAfter,
               let d = P.descriptor(from: file.context) {
                continuation.yield(.waitingForUser(d.key, kind: .endOfTurn))
                file.waitingEmitted = true
                tracked[key] = file
            } else if !file.waitingEmitted, P.hasPending(file.context),
                      now.timeIntervalSince(file.lastLineAt) >= 15,
                      let d = P.descriptor(from: file.context) {
                continuation.yield(.waitingForUser(d.key, kind: .permissionPrompt))
                file.waitingEmitted = true
                tracked[key] = file
            }

            // Ended-session pruning by file mtime.
            if let mtime = fileModifiedDate(atPath: key),
               now.timeIntervalSince(mtime) >= config.endedAfter,
               !file.endedEmitted {
                emitEnded(&file, key: key, now: now, continuation: continuation)
            }
        }
        discoverNew(continuation: continuation)
    }

    private func discoverNew(continuation: AsyncStream<AgentEvent>.Continuation) {
        let cutoff = Date().addingTimeInterval(-60)
        for root in config.roots {
            for url in SessionDiscovery.recentSessionFiles(root: root, modifiedAfter: cutoff, maxDepth: config.maxDepth)
            where tracked[url.path] == nil {
                trackNew(url, continuation: continuation)
            }
        }
    }

    // MARK: - File lifecycle

    private func seedFile(_ url: URL, continuation: AsyncStream<AgentEvent>.Continuation) {
        guard tracked[url.path] == nil else { return }
        let reader = TailReader(url: url)
        var context = P.makeContext(sessionID: P.sessionID(from: url))
        let now = Date()
        var lastStatus: AgentEvent?
        if let lines = try? reader.seedNearEnd() {
            for line in lines {
                let produced = P.parse(line: line, context: &context, receivedAt: now)
                for event in produced {
                    if case .statusChanged = event { lastStatus = event }
                }
            }
        }
        var file = TrackedFile(
            reader: reader,
            context: context,
            lastLineAt: now,
            waitingEmitted: false,
            endedEmitted: false,
            startedForwarded: false,
            subagentParentKey: nil,
            subagentHandoffOpen: false
        )
        forwardStart(&file, continuation: continuation, now: now)
        if let lastStatus { forward([lastStatus], into: &file, continuation: continuation, now: now) }
        tracked[url.path] = file
    }

    private func trackNew(_ url: URL, continuation: AsyncStream<AgentEvent>.Continuation) {
        guard tracked[url.path] == nil else { return }
        let reader = TailReader(url: url)
        let context = P.makeContext(sessionID: P.sessionID(from: url))
        tracked[url.path] = TrackedFile(
            reader: reader,
            context: context,
            lastLineAt: Date(),
            waitingEmitted: false,
            endedEmitted: false,
            startedForwarded: false,
            subagentParentKey: nil,
            subagentHandoffOpen: false
        )
        drain(url.path, continuation: continuation)
    }

    private func drain(_ key: String, continuation: AsyncStream<AgentEvent>.Continuation) {
        guard var file = tracked[key] else { return }
        let now = Date()
        let lines: [String]
        do {
            lines = try file.reader.drainNewLines()
        } catch {
            emitEnded(&file, key: key, now: now, continuation: continuation)
            return
        }
        guard !lines.isEmpty else { tracked[key] = file; return }

        file.lastLineAt = now
        file.waitingEmitted = false
        var produced: [AgentEvent] = []
        for line in lines {
            produced.append(contentsOf: P.parse(line: line, context: &file.context, receivedAt: now))
        }
        forwardStart(&file, continuation: continuation, now: now)
        forward(produced, into: &file, continuation: continuation, now: now)
        tracked[key] = file
    }

    /// Emits the initial sessionStarted once a descriptor is available, converting Codex
    /// subagent threads into a handoff pearl on the parent fish instead of a new fish.
    private func forwardStart(_ file: inout TrackedFile, continuation: AsyncStream<AgentEvent>.Continuation, now: Date) {
        guard !file.startedForwarded, let d = P.descriptor(from: file.context) else { return }
        file.startedForwarded = true
        if d.isSubagent, let parentID = d.parentSessionID {
            let parentKey = SessionKey(provider: P.provider, sessionID: parentID)
            file.subagentParentKey = parentKey
            file.subagentHandoffOpen = true
            continuation.yield(.handoff(parentKey, subagentType: d.title ?? "subagent", description: d.projectDisplayName))
        } else {
            continuation.yield(.sessionStarted(d))
        }
    }

    /// Forwards parsed events, suppressing everything from a subagent file except the pearl.
    private func forward(_ events: [AgentEvent], into file: inout TrackedFile, continuation: AsyncStream<AgentEvent>.Continuation, now: Date) {
        if let parentKey = file.subagentParentKey {
            // Subagent activity is invisible except its completion, which closes the pearl.
            for event in events {
                switch event {
                case .taskCompleted, .sessionEnded:
                    if file.subagentHandoffOpen {
                        continuation.yield(.handoffReturned(parentKey, success: true))
                        file.subagentHandoffOpen = false
                    }
                default:
                    continue
                }
            }
            return
        }
        for event in events {
            if case .sessionStarted = event { continue } // already forwarded via forwardStart
            continuation.yield(event)
        }
    }

    private func emitEnded(_ file: inout TrackedFile, key: String, now: Date, continuation: AsyncStream<AgentEvent>.Continuation) {
        guard !file.endedEmitted else { tracked[key] = file; return }
        file.endedEmitted = true
        if let parentKey = file.subagentParentKey {
            if file.subagentHandoffOpen {
                continuation.yield(.handoffReturned(parentKey, success: true))
            }
        } else if let d = P.descriptor(from: file.context) {
            continuation.yield(.sessionEnded(d.key, at: now))
        }
        tracked[key] = nil
    }

    private func fileModifiedDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
}
