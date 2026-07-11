import Foundation
import VivariumCore

/// Configuration for the Gemini telemetry monitor. Overridable for tests.
public struct GeminiTelemetryConfig: Sendable {
    /// Path to Gemini's telemetry `outfile`. May point at a not-yet-created file — the monitor opens
    /// it lazily once it appears, so starting Vivarium before Gemini runs still works.
    public var outfilePath: String?
    /// After a turn ends with no new records, promote to waitingForUser.
    public var waitingAfter: TimeInterval
    /// A session quiet for this long is considered ended.
    public var endedAfter: TimeInterval
    /// Poll cadence for the outfile.
    public var pollInterval: Duration

    public init(
        outfilePath: String?,
        waitingAfter: TimeInterval = 10,
        endedAfter: TimeInterval = 900,
        pollInterval: Duration = .seconds(2)
    ) {
        self.outfilePath = outfilePath
        self.waitingAfter = waitingAfter
        self.endedAfter = endedAfter
        self.pollInterval = pollInterval
    }

    /// Resolves the outfile from `~/.gemini/settings.json` (`telemetry.outfile`), falling back to
    /// Vivarium's own path. Returned even if the file does not yet exist.
    public static func standard() -> GeminiTelemetryConfig {
        GeminiTelemetryConfig(outfilePath: resolvedOutfilePath())
    }

    /// `~/.gemini/settings.json`.
    public static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json", isDirectory: false)
    }

    /// Vivarium's default telemetry sink when Gemini has no `outfile` configured yet.
    public static var defaultOutfilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vivarium/gemini-telemetry.log", isDirectory: false)
            .path
    }

    /// The `telemetry.outfile` currently configured in `~/.gemini/settings.json`, or Vivarium's
    /// default. Reused (not clobbered) so Vivarium coexists with other telemetry consumers.
    public static func resolvedOutfilePath() -> String {
        if let data = try? Data(contentsOf: settingsURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let telemetry = root["telemetry"] as? [String: Any],
           let outfile = telemetry["outfile"] as? String, !outfile.isEmpty {
            return (outfile as NSString).expandingTildeInPath
        }
        return defaultOutfilePath
    }
}

/// Tails Gemini CLI's single OpenTelemetry `outfile` and emits semantic `AgentEvent`s.
///
/// Gemini keeps no per-session transcript; instead, with local telemetry enabled it appends every
/// session's log records to one `outfile`, each tagged with a `session.id`. This monitor reads new
/// records (reassembled from the pretty-printed lines via `GeminiRecordAssembler`), routes each to a
/// per-`session.id` parse context, and forwards the parser's output. On startup it seeds at EOF so
/// past activity never replays. Sessions have no explicit "end" record, so a quiet-timeout watchdog
/// (plus the coordinator's process-gone grace) reaps them.
public actor GeminiTelemetryMonitor: AgentEventStreaming {
    private struct Tracked {
        var context: GeminiParseContext
        var lastEventAt: Date
        var waitingEmitted: Bool
        var endedEmitted: Bool
    }

    private let config: GeminiTelemetryConfig
    private var reader: TailReader?
    private var assembler = GeminiRecordAssembler()
    private var tracked: [String: Tracked] = [:]
    private var started = false

    public init(config: GeminiTelemetryConfig) {
        self.config = config
    }

    public nonisolated func events() -> AsyncStream<AgentEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<AgentEvent>.Continuation) async {
        guard !started else { return }
        started = true
        while !Task.isCancelled {
            poll(continuation: continuation)
            try? await Task.sleep(for: config.pollInterval)
        }
    }

    /// Opens the outfile lazily once it exists, seeding at EOF so history never replays.
    private func ensureReader() -> TailReader? {
        if let reader { return reader }
        guard let path = config.outfilePath, FileManager.default.fileExists(atPath: path) else { return nil }
        let reader = TailReader(url: URL(fileURLWithPath: path))
        _ = try? reader.seedNearEnd(backscanBytes: 0) // position at EOF; discard history
        self.reader = reader
        assembler = GeminiRecordAssembler()
        return reader
    }

    private func poll(continuation: AsyncStream<AgentEvent>.Continuation) {
        guard let reader = ensureReader() else { return }
        let now = Date()

        let lines: [String]
        do {
            lines = try reader.drainNewLines()
        } catch {
            // The outfile vanished (rotated/deleted): end live sessions and reopen fresh next poll.
            endAll(now: now, continuation: continuation)
            self.reader = nil
            return
        }

        // If the file was truncated in place or replaced, TailReader rewound to 0; drop the stale
        // partial record in the assembler so a mid-record carry never corrupts the next parse.
        if reader.didResetOnLastDrain {
            assembler = GeminiRecordAssembler()
        }

        for recordJSON in assembler.push(lines) {
            handle(recordJSON, now: now, continuation: continuation)
        }
        advanceWatchdogs(now: now, continuation: continuation)
    }

    private func handle(_ recordJSON: String, now: Date, continuation: AsyncStream<AgentEvent>.Continuation) {
        guard let record = GeminiTelemetryParser.decode(recordJSON) else { return }
        let attrs = GeminiTelemetryParser.attributes(of: record)
        guard let sessionID = GeminiTelemetryParser.sessionID(of: attrs, record: record),
              let eventName = GeminiTelemetryParser.eventName(of: attrs, record: record) else { return }

        var entry = tracked[sessionID] ?? Tracked(
            context: GeminiParseContext(sessionID: sessionID),
            lastEventAt: now,
            waitingEmitted: false,
            endedEmitted: false
        )
        let produced = GeminiTelemetryParser.parse(
            eventName: eventName,
            attrs: attrs,
            context: &entry.context,
            receivedAt: now
        )
        entry.lastEventAt = now
        entry.waitingEmitted = false
        entry.endedEmitted = false
        tracked[sessionID] = entry
        for event in produced { continuation.yield(event) }
    }

    /// Promotes quiet finished turns to waiting, and prunes long-stale sessions to ended.
    private func advanceWatchdogs(now: Date, continuation: AsyncStream<AgentEvent>.Continuation) {
        for sessionID in Array(tracked.keys) {
            guard var entry = tracked[sessionID] else { continue }
            guard let descriptor = entry.context.descriptor else {
                // Only descriptor-less records were ever seen for this session.id (e.g. a run that
                // emitted just config/api records and quit). Reap silently once stale so the map
                // never grows without bound; no sessionStarted fired, so emit no sessionEnded.
                if now.timeIntervalSince(entry.lastEventAt) >= config.endedAfter {
                    tracked[sessionID] = nil
                }
                continue
            }
            if !entry.waitingEmitted, entry.context.turnEnded,
               now.timeIntervalSince(entry.lastEventAt) >= config.waitingAfter {
                continuation.yield(.waitingForUser(descriptor.key, kind: .endOfTurn))
                entry.waitingEmitted = true
                tracked[sessionID] = entry
            }
            if !entry.endedEmitted, now.timeIntervalSince(entry.lastEventAt) >= config.endedAfter {
                continuation.yield(.sessionEnded(descriptor.key, at: now))
                tracked[sessionID] = nil
            }
        }
    }

    private func endAll(now: Date, continuation: AsyncStream<AgentEvent>.Continuation) {
        for (_, entry) in tracked where !entry.endedEmitted {
            if let descriptor = entry.context.descriptor {
                continuation.yield(.sessionEnded(descriptor.key, at: now))
            }
        }
        tracked.removeAll()
    }
}
