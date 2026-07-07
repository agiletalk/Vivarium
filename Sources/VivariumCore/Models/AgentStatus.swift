import Foundation

/// Semantic activity state of an agent session, derived from transcript records.
public enum AgentStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case searching
    case planning
    case coding
    case reviewing
    case testing
    case fixingBug
    case handingOff
    case waiting
    case resting
    case celebrating

    /// Whether the agent is actively doing work (drives fatigue accrual and the menu bar icon).
    public var isActive: Bool {
        switch self {
        case .searching, .planning, .coding, .reviewing, .testing, .fixingBug, .handingOff: true
        case .waiting, .resting, .celebrating: false
        }
    }
}

public enum WaitKind: String, Codable, Sendable, Hashable {
    case endOfTurn
    case question
    case permissionPrompt
}

/// Coarse process-scan activity level (AgentCat-style), for providers with no session files.
public enum ActivityLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case sleeping
    case walking
    case running
    case sprinting

    public var isActive: Bool { self != .sleeping }
}
