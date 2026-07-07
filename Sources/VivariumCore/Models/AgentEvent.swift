import Foundation

/// Semantic events produced by VivariumDetect (or the demo script) and consumed by the ecosystem engine.
public enum AgentEvent: Sendable, Equatable {
    case sessionStarted(SessionDescriptor)
    case sessionUpdated(SessionDescriptor)
    case sessionEnded(SessionKey, at: Date)
    case statusChanged(SessionKey, AgentStatus)
    /// Short thought-bubble text (≤ 60 chars), e.g. "Running tests…", "Editing FishNode.swift".
    case thought(SessionKey, message: String)
    case taskCompleted(SessionKey, domain: MemoryDomain?, summary: String?)
    case taskFailed(SessionKey, reason: String?)
    case waitingForUser(SessionKey, kind: WaitKind)
    /// A subagent was spawned (Claude `Task` tool / Codex subagent thread) → pearl animation.
    case handoff(SessionKey, subagentType: String, description: String?)
    case handoffReturned(SessionKey, success: Bool)
    /// Test-classified command failed → the bug shark appears.
    case bugDetected(SessionKey, evidence: String)
    case bugResolved(SessionKey)
    /// Process-scan signal for providers without session files (gemini/cursor/unknown).
    case providerActivity(AgentProvider, score: Double, level: ActivityLevel, processCount: Int)

    /// The session this event belongs to, when it has one.
    public var sessionKey: SessionKey? {
        switch self {
        case .sessionStarted(let d), .sessionUpdated(let d): d.key
        case .sessionEnded(let k, _): k
        case .statusChanged(let k, _): k
        case .thought(let k, _): k
        case .taskCompleted(let k, _, _): k
        case .taskFailed(let k, _): k
        case .waitingForUser(let k, _): k
        case .handoff(let k, _, _): k
        case .handoffReturned(let k, _): k
        case .bugDetected(let k, _): k
        case .bugResolved(let k): k
        case .providerActivity: nil
        }
    }
}

/// Anything that can produce a stream of agent events (real monitors, the merged coordinator, demo script).
public protocol AgentEventStreaming: Sendable {
    func events() -> AsyncStream<AgentEvent>
}
