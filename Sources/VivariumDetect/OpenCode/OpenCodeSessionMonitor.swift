import Foundation
import VivariumCore

/// Configuration for the OpenCode SQLite monitor. Overridable for tests.
public struct OpenCodeMonitorConfig: Sendable {
    /// Path to `opencode.db`. May point at a not-yet-created file — the monitor opens it lazily
    /// once it appears, so starting Vivarium before OpenCode still works.
    public var databasePath: String?
    /// Sessions last updated longer ago than this at startup are ignored (already over).
    public var startupWindow: TimeInterval
    /// A session discovered at runtime is replayed from the start (to animate it coming alive) only
    /// if it was created this recently; older sessions being resumed are seeded silently instead.
    public var replayWindow: TimeInterval
    /// A session quiet for this long is considered ended.
    public var endedAfter: TimeInterval
    /// After a turn ends with no new events, promote to waitingForUser.
    public var waitingAfter: TimeInterval
    /// Poll cadence for the event-log cursor.
    public var pollInterval: Duration

    public init(
        databasePath: String?,
        startupWindow: TimeInterval = 1800,
        replayWindow: TimeInterval = 120,
        endedAfter: TimeInterval = 1800,
        waitingAfter: TimeInterval = 10,
        pollInterval: Duration = .seconds(2)
    ) {
        self.databasePath = databasePath
        self.startupWindow = startupWindow
        self.replayWindow = replayWindow
        self.endedAfter = endedAfter
        self.waitingAfter = waitingAfter
        self.pollInterval = pollInterval
    }

    public static func standard() -> OpenCodeMonitorConfig {
        OpenCodeMonitorConfig(databasePath: defaultDatabasePath)
    }

    /// `$XDG_DATA_HOME/opencode/opencode.db`, falling back to `~/.local/share/opencode/opencode.db`.
    /// Returned even if the file does not yet exist.
    public static var defaultDatabasePath: String? {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
        }
        return base.appendingPathComponent("opencode/opencode.db").path
    }
}

/// Polls OpenCode's event-sourced SQLite log and emits semantic `AgentEvent`s.
///
/// OpenCode does not tail like Claude/Codex/Copilot — it writes an `event` table with a monotonic
/// `seq` per session. Each poll reads `event_sequence` for the current cursor per session and drains
/// only rows past the last one seen, threading them through `OpenCodeEventParser`. On startup, live
/// sessions are seeded from their `session` row (descriptor + turn state) without replaying history
/// so the aquarium never re-animates past work. The read-only connection is safe alongside the
/// running CLI's WAL.
public actor OpenCodeSessionMonitor: AgentEventStreaming {
    private struct Tracked {
        var context: OpenCodeParseContext
        var lastSeq: Int64
        var lastEventAt: Date
        var lastUpdatedMs: Int64
        var waitingEmitted: Bool
        var endedEmitted: Bool
    }

    private let config: OpenCodeMonitorConfig
    private var tracked: [String: Tracked] = [:]
    /// Subagent (`parent_id`-bearing) session ids we deliberately do not surface as fish.
    private var ignoredSessions: Set<String> = []
    private var db: OpenCodeDatabase?
    /// Inode of the open database file, so a delete/recreate at the same path is detected and reopened.
    private var dbInode: UInt64?
    private var started = false

    /// Fresh activity after a quiet gap this long re-announces the session, in case the coordinator
    /// grace-ended it out-of-band (CLI quit → relaunch → resume the same persistent session).
    private let reannounceAfter: TimeInterval = 40

    public init(config: OpenCodeMonitorConfig) {
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

        seedExisting(continuation: continuation)

        while !Task.isCancelled {
            reopenIfReplaced(continuation: continuation)
            poll(continuation: continuation)
            try? await Task.sleep(for: config.pollInterval)
        }
    }

    /// Opens the database lazily; returns nil until the file exists.
    private func ensureDatabase() -> OpenCodeDatabase? {
        if let db { return db }
        guard let path = config.databasePath, FileManager.default.fileExists(atPath: path) else { return nil }
        guard let opened = OpenCodeDatabase(path: path) else { return nil }
        db = opened
        dbInode = fileInode(path)
        return db
    }

    /// If opencode.db is deleted or replaced (uninstall/reset) mid-run, the cached read-only handle
    /// would point at a dead inode forever. Detect that, end the now-orphaned sessions, and drop the
    /// handle so ensureDatabase reopens the fresh file.
    private func reopenIfReplaced(continuation: AsyncStream<AgentEvent>.Continuation) {
        guard db != nil, let path = config.databasePath else { return }
        let current = fileInode(path)
        guard current != dbInode else { return }
        let now = Date()
        for (_, t) in tracked where !t.endedEmitted {
            if let descriptor = t.context.descriptor {
                continuation.yield(.sessionEnded(descriptor.key, at: now))
            }
        }
        tracked.removeAll()
        ignoredSessions.removeAll()
        db = nil
        dbInode = nil
    }

    private func fileInode(_ path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    // MARK: - Seeding

    /// Seeds still-active sessions silently: build the descriptor from the session row, set the
    /// cursor to the current max seq (so no history replays), and infer the turn state.
    private func seedExisting(continuation: AsyncStream<AgentEvent>.Continuation) {
        guard let db = ensureDatabase() else { return }
        let now = Date()
        for (sessionID, seq) in db.sessionSequences() {
            guard tracked[sessionID] == nil, let row = db.session(id: sessionID) else { continue }
            guard !isSubagent(sessionID, row: row) else { continue }
            let updated = Date(timeIntervalSince1970: Double(row.timeUpdatedMs) / 1000)
            guard now.timeIntervalSince(updated) < config.startupWindow else { continue }
            seed(sessionID: sessionID, seq: seq, row: row, at: updated, continuation: continuation)
        }
    }

    /// Subagent sessions (spawned by a parent's `task` tool) carry a `parent_id`; they are suppressed
    /// so the subagent shows only as a handoff pearl on the parent, never as a second free fish.
    private func isSubagent(_ sessionID: String, row: OpenCodeDatabase.SessionRow) -> Bool {
        guard let parent = row.parentID, !parent.isEmpty else { return false }
        ignoredSessions.insert(sessionID)
        return true
    }

    private func seed(
        sessionID: String,
        seq: Int64,
        row: OpenCodeDatabase.SessionRow,
        at updated: Date,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        guard let db else { return }
        var context = OpenCodeParseContext(sessionID: sessionID)
        let descriptor = OpenCodeEventParser.makeDescriptor(
            sessionID: sessionID,
            directory: row.directory,
            title: row.title,
            model: row.model,
            startedAt: Date(timeIntervalSince1970: Double(row.timeCreatedMs) / 1000)
        )
        context.descriptor = descriptor
        // Seeding restores the turn state but not in-flight tool state, so a session seeded while
        // blocked on a tool shows as .coding rather than waiting until the next event flows. This is
        // cosmetic and self-limited (a resumed or ended session corrects it), so it is left as-is.
        let finish = db.latestAssistantFinish(sessionID: sessionID)
        let ended = finish?.finish == "stop" && finish?.completed == true
        context.turnEnded = ended
        tracked[sessionID] = Tracked(
            context: context,
            lastSeq: seq,
            lastEventAt: updated,
            lastUpdatedMs: row.timeUpdatedMs,
            waitingEmitted: false,
            endedEmitted: false
        )
        continuation.yield(.sessionStarted(descriptor))
        // A session mid-turn should look busy immediately; a finished one waits for the watchdog.
        if !ended {
            context.lastStatus = .coding
            tracked[sessionID]?.context = context
            continuation.yield(.statusChanged(descriptor.key, .coding))
        }
    }

    // MARK: - Polling

    private func poll(continuation: AsyncStream<AgentEvent>.Continuation) {
        guard let db = ensureDatabase() else { return }
        let now = Date()

        for (sessionID, seq) in db.sessionSequences() {
            if ignoredSessions.contains(sessionID) { continue }
            if tracked[sessionID] != nil {
                drain(sessionID: sessionID, upTo: seq, db: db, now: now, continuation: continuation)
            } else {
                discover(sessionID: sessionID, seq: seq, db: db, now: now, continuation: continuation)
            }
        }

        advanceWatchdogs(now: now, continuation: continuation)
    }

    /// Reads events past the tracked cursor and forwards their parsed output.
    private func drain(
        sessionID: String,
        upTo seq: Int64,
        db: OpenCodeDatabase,
        now: Date,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        guard var tracked = tracked[sessionID], seq > tracked.lastSeq else { return }
        let rows = db.events(sessionID: sessionID, afterSeq: tracked.lastSeq)
        guard !rows.isEmpty else { return }
        // Fresh activity after the session went quiet: the coordinator may have grace-ended it when
        // the CLI process disappeared (and OpenCode resumes the same persistent session on relaunch).
        // Re-announce so the engine rebinds the fish — applySessionStarted treats a live duplicate as
        // a harmless update, so this is safe whether or not the fish was actually reaped.
        let resumed = tracked.waitingEmitted || now.timeIntervalSince(tracked.lastEventAt) >= reannounceAfter
        var produced: [AgentEvent] = []
        if resumed, let descriptor = tracked.context.descriptor {
            produced.append(.sessionStarted(descriptor))
        }
        for row in rows {
            produced += OpenCodeEventParser.parse(
                type: row.type,
                data: decode(row.data),
                context: &tracked.context,
                receivedAt: now
            )
            tracked.lastSeq = max(tracked.lastSeq, row.seq)
        }
        tracked.lastEventAt = now
        tracked.waitingEmitted = false
        if let row = db.session(id: sessionID) { tracked.lastUpdatedMs = row.timeUpdatedMs }
        self.tracked[sessionID] = tracked
        for event in produced { continuation.yield(event) }
    }

    /// A session id not seen before: replay it from the start if it was just created (so the fish
    /// animates in), otherwise seed it silently (an old session being resumed).
    private func discover(
        sessionID: String,
        seq: Int64,
        db: OpenCodeDatabase,
        now: Date,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        guard let row = db.session(id: sessionID) else { return }
        guard !isSubagent(sessionID, row: row) else { return }
        let updated = Date(timeIntervalSince1970: Double(row.timeUpdatedMs) / 1000)
        guard now.timeIntervalSince(updated) < config.endedAfter else { return }
        let created = Date(timeIntervalSince1970: Double(row.timeCreatedMs) / 1000)
        if now.timeIntervalSince(created) <= config.replayWindow {
            tracked[sessionID] = Tracked(
                context: OpenCodeParseContext(sessionID: sessionID),
                lastSeq: -1,
                lastEventAt: now,
                lastUpdatedMs: row.timeUpdatedMs,
                waitingEmitted: false,
                endedEmitted: false
            )
            drain(sessionID: sessionID, upTo: seq, db: db, now: now, continuation: continuation)
        } else {
            seed(sessionID: sessionID, seq: seq, row: row, at: updated, continuation: continuation)
        }
    }

    /// Promotes quiet finished turns to waiting, and prunes long-stale sessions to ended.
    private func advanceWatchdogs(now: Date, continuation: AsyncStream<AgentEvent>.Continuation) {
        for sessionID in Array(tracked.keys) {
            guard var t = tracked[sessionID], let descriptor = t.context.descriptor else { continue }

            if !t.waitingEmitted, t.context.turnEnded,
               now.timeIntervalSince(t.lastEventAt) >= config.waitingAfter {
                continuation.yield(.waitingForUser(descriptor.key, kind: .endOfTurn))
                t.waitingEmitted = true
                tracked[sessionID] = t
            } else if !t.waitingEmitted, t.context.hasPending,
                      now.timeIntervalSince(t.lastEventAt) >= 15 {
                continuation.yield(.waitingForUser(descriptor.key, kind: .permissionPrompt))
                t.waitingEmitted = true
                tracked[sessionID] = t
            }

            let updated = Date(timeIntervalSince1970: Double(t.lastUpdatedMs) / 1000)
            if !t.endedEmitted, now.timeIntervalSince(updated) >= config.endedAfter {
                continuation.yield(.sessionEnded(descriptor.key, at: now))
                tracked[sessionID] = nil
            }
        }
    }

    private func decode(_ json: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
