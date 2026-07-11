import Foundation

/// Stable fish identity. Resident memory fish are keyed by (provider, projectKey) so they persist
/// across sessions; ephemeral schoolmates are keyed by session; process-scan fish by provider.
public struct FishID: Hashable, Sendable, Codable, RawRepresentable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func resident(provider: AgentProvider, projectKey: String) -> FishID {
        FishID(rawValue: "resident|\(provider.rawValue)|\(projectKey)")
    }

    public static func ephemeral(provider: AgentProvider, sessionID: String) -> FishID {
        FishID(rawValue: "ephemeral|\(provider.rawValue)|\(sessionID)")
    }

    public static func provider(_ provider: AgentProvider) -> FishID {
        FishID(rawValue: "provider|\(provider.rawValue)")
    }

    public static func demo(_ name: String) -> FishID {
        FishID(rawValue: "demo|\(name)")
    }

    public var isDemo: Bool { rawValue.hasPrefix("demo|") }
}

/// Expertise domains a Memory Fish can accumulate. Rendered as colored stripes on the body.
public enum MemoryDomain: String, Codable, Sendable, CaseIterable, Hashable {
    case swift
    case ui
    case backend
    case testing
    case planning
    case review
    case search
}

public struct MemoryTrait: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var domain: MemoryDomain
    /// 1...5; grows as the fish completes tasks in this domain.
    public var level: Int

    public var id: MemoryDomain { domain }

    public init(domain: MemoryDomain, level: Int) {
        self.domain = domain
        self.level = level
    }
}

public struct ThoughtBubble: Codable, Sendable, Equatable {
    public var message: String
    public var expiresAt: Date

    public init(message: String, expiresAt: Date) {
        self.message = message
        self.expiresAt = expiresAt
    }
}

/// Semantic state of one fish. Positions/velocities live in the SpriteKit scene, never here.
public struct FishState: Codable, Sendable, Equatable, Identifiable {
    public var id: FishID
    public var provider: AgentProvider
    public var species: FishSpecies
    /// e.g. "Claude · Vivarium"
    public var displayName: String
    public var projectKey: String?
    /// Resident memory fish persist and accumulate expertise; ephemeral schoolmates don't.
    public var isResident: Bool
    public var status: AgentStatus
    /// Why the agent is `.waiting`, when known. `.permissionPrompt` is heuristic (a tool has been
    /// quiet a while) and indistinguishable from a slow autonomous tool, so the notifier ignores it.
    public var waitKind: WaitKind?
    public var thought: ThoughtBubble?
    /// Body scale, 1.0...1.45. Grows with eaten food.
    public var size: Double
    /// 0...1. Slows and desaturates the fish; recovers while resting.
    public var fatigue: Double
    public var tasksCompleted: Int
    public var tasksFailed: Int
    public var memory: [MemoryTrait]
    public var isLegendary: Bool
    /// Coarse level for process-scan-only fish; file-backed fish derive activity from status.
    public var activityLevel: ActivityLevel
    public var lastActiveAt: Date
    public var createdAt: Date
    public var sessionCount: Int
    public var currentSessionTitle: String?
    public var gitBranch: String?
    public var model: String?

    public init(
        id: FishID,
        provider: AgentProvider,
        displayName: String,
        projectKey: String? = nil,
        isResident: Bool,
        status: AgentStatus = .resting,
        waitKind: WaitKind? = nil,
        thought: ThoughtBubble? = nil,
        size: Double = 1.0,
        fatigue: Double = 0,
        tasksCompleted: Int = 0,
        tasksFailed: Int = 0,
        memory: [MemoryTrait] = [],
        isLegendary: Bool = false,
        activityLevel: ActivityLevel = .sleeping,
        lastActiveAt: Date,
        createdAt: Date,
        sessionCount: Int = 0,
        currentSessionTitle: String? = nil,
        gitBranch: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.species = provider.species
        self.displayName = displayName
        self.projectKey = projectKey
        self.isResident = isResident
        self.status = status
        self.waitKind = waitKind
        self.thought = thought
        self.size = size
        self.fatigue = fatigue
        self.tasksCompleted = tasksCompleted
        self.tasksFailed = tasksFailed
        self.memory = memory
        self.isLegendary = isLegendary
        self.activityLevel = activityLevel
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.sessionCount = sessionCount
        self.currentSessionTitle = currentSessionTitle
        self.gitBranch = gitBranch
        self.model = model
    }

    /// Just the project portion of `displayName` (the part after the last " · "), or the whole
    /// label when there is no project (e.g. a process-scan agent). Used by compact row/panel labels.
    public var projectTitle: String {
        if let range = displayName.range(of: " · ", options: .backwards) {
            return String(displayName[range.upperBound...])
        }
        return displayName
    }
}
