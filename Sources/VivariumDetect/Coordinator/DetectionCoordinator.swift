import Foundation
import VivariumCore

/// Merges the Claude/Codex transcript monitors and the process scanner into one event stream.
/// Rate-limits thought bubbles, suppresses process-scan activity for providers that already have
/// live file-backed sessions (avoiding double counting), and forwards everything else verbatim.
public actor DetectionCoordinator: AgentEventStreaming {
    private let sources: [any AgentEventStreaming]
    private let processScanner: ProcessScanner?
    private let scanInterval: Duration

    /// Providers with at least one live session — their process activity is redundant.
    private var fileBackedProviders: Set<AgentProvider> = []
    /// Last thought timestamp per session, for the 1-per-2s rate limit.
    private var lastThoughtAt: [SessionKey: Date] = [:]
    private var lastProviderLevel: [AgentProvider: ActivityLevel] = [:]
    /// Live transcript sessions per file-backed provider, so we can end them promptly when the
    /// provider's process disappears (the CLI was closed) rather than waiting for the file to go
    /// stale — fish should vanish shortly after the agent actually stops.
    private var liveFileSessions: [AgentProvider: Set<String>] = [:]
    private var processGoneSince: [AgentProvider: Date] = [:]
    /// How long a file-backed provider must show zero processes before its sessions are ended.
    private let processGoneGrace: TimeInterval = 45
    private static let fileBacked: [AgentProvider] = [.claude, .codex]

    public init(
        sources: [any AgentEventStreaming],
        processScanner: ProcessScanner? = ProcessScanner(),
        scanInterval: Duration = .seconds(5)
    ) {
        self.sources = sources
        self.processScanner = processScanner
        self.scanInterval = scanInterval
    }

    /// Builds the standard coordinator: Claude + Codex file monitors plus process scanning.
    public static func standard() -> DetectionCoordinator {
        DetectionCoordinator(sources: [
            AgentSessionMonitor<ClaudeParsing>(config: .claude()),
            AgentSessionMonitor<CodexParsing>(config: .codex()),
        ])
    }

    public nonisolated func events() -> AsyncStream<AgentEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<AgentEvent>.Continuation) async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                let stream = source.events()
                group.addTask { [weak self] in
                    for await event in stream {
                        guard let self else { break }
                        await self.forward(event, continuation: continuation)
                    }
                }
            }
            if let scanner = processScanner {
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { break }
                        await self.scan(scanner, continuation: continuation)
                        try? await Task.sleep(for: self.scanInterval)
                    }
                }
            }
            for await _ in group {}
        }
    }

    private func forward(_ event: AgentEvent, continuation: AsyncStream<AgentEvent>.Continuation) {
        switch event {
        case .sessionStarted(let d):
            fileBackedProviders.insert(d.key.provider)
            if Self.fileBacked.contains(d.key.provider) {
                liveFileSessions[d.key.provider, default: []].insert(d.key.sessionID)
                processGoneSince[d.key.provider] = nil
            }
        case .sessionEnded(let key, _):
            // The store handles roster truth; we keep fileBackedProviders set so process scan stays
            // suppressed while the CLI is installed. Drop the session from our liveness tracking.
            liveFileSessions[key.provider]?.remove(key.sessionID)
        case .thought(let key, _):
            let now = Date()
            if let last = lastThoughtAt[key], now.timeIntervalSince(last) < 2 { return }
            lastThoughtAt[key] = now
        default:
            break
        }
        continuation.yield(event)
    }

    private func scan(_ scanner: ProcessScanner, continuation: AsyncStream<AgentEvent>.Continuation) async {
        guard let samples = try? await scanner.sample() else { return }
        for (provider, sample) in samples {
            // File-backed providers (claude/codex) get richer state from transcripts.
            guard !fileBackedProviders.contains(provider) else { continue }
            // Only surface providers without a transcript source — detected purely by process scan.
            guard provider == .gemini || provider == .cursor
                    || provider == .opencode || provider == .copilot else { continue }
            if lastProviderLevel[provider] == sample.level { continue }
            lastProviderLevel[provider] = sample.level
            continuation.yield(.providerActivity(
                provider,
                score: sample.score,
                level: sample.level,
                processCount: sample.processCount
            ))
        }
        endStaleFileSessions(samples, continuation: continuation)
    }

    /// Ends live transcript sessions whose CLI process has been gone for the grace period, so their
    /// fish disappear shortly after the agent actually stops (not only when the file goes stale).
    private func endStaleFileSessions(
        _ samples: [AgentProvider: ProviderSample],
        continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        let now = Date()
        for provider in Self.fileBacked {
            guard let live = liveFileSessions[provider], !live.isEmpty else {
                processGoneSince[provider] = nil
                continue
            }
            let count = samples[provider]?.processCount ?? 0
            if count > 0 {
                processGoneSince[provider] = nil
                continue
            }
            if let since = processGoneSince[provider] {
                if now.timeIntervalSince(since) >= processGoneGrace {
                    for sessionID in live {
                        continuation.yield(.sessionEnded(SessionKey(provider: provider, sessionID: sessionID), at: now))
                    }
                    liveFileSessions[provider] = []
                    processGoneSince[provider] = nil
                }
            } else {
                processGoneSince[provider] = now
            }
        }
    }
}
