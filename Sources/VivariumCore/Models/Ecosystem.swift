import Foundation

public struct FoodPellet: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case falling
        case available
        case eaten
        case missed
    }

    public var id: Int
    public var fish: FishID
    public var state: State
    public var createdAt: Date

    public init(id: Int, fish: FishID, state: State = .falling, createdAt: Date) {
        self.id = id
        self.fish = fish
        self.state = state
        self.createdAt = createdAt
    }
}

/// A handoff pearl: spawned when a fish delegates to a subagent, hovers while it works,
/// and returns (bright) or fades (gray) when the subagent finishes.
public struct Pearl: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case outbound
        case working
        case returned
        case failed
    }

    public var id: Int
    public var fish: FishID
    /// Subagent type/description, e.g. "Explore", "Plan".
    public var label: String
    public var phase: Phase
    public var createdAt: Date

    public init(id: Int, fish: FishID, label: String, phase: Phase = .outbound, createdAt: Date) {
        self.id = id
        self.fish = fish
        self.label = label
        self.phase = phase
        self.createdAt = createdAt
    }
}

public struct SharkThreat: Codable, Sendable, Equatable {
    public var isActive: Bool
    public var label: String
    /// 0...1, scales the vignette/panic intensity.
    public var severity: Double
    public var causeFish: FishID?
    public var since: Date?

    public init(isActive: Bool = false, label: String = "", severity: Double = 0, causeFish: FishID? = nil, since: Date? = nil) {
        self.isActive = isActive
        self.label = label
        self.severity = severity
        self.causeFish = causeFish
        self.since = since
    }
}

/// Reef evolution driven by cumulative completed tasks.
public enum ReefStage: Int, Codable, Sendable, CaseIterable, Comparable {
    case sand = 0
    case coral
    case shells
    case seaweed
    case tropicalFish
    case grandAquarium

    public static func < (lhs: ReefStage, rhs: ReefStage) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Cumulative completed-task threshold to reach this stage.
    public var threshold: Int {
        switch self {
        case .sand: 0
        case .coral: 10
        case .shells: 30
        case .seaweed: 75
        case .tropicalFish: 150
        case .grandAquarium: 300
        }
    }

    public static func stage(forCompletedTasks count: Int) -> ReefStage {
        ReefStage.allCases.last(where: { count >= $0.threshold }) ?? .sand
    }
}

public enum AmbientPhase: String, Codable, Sendable, CaseIterable {
    case dawn
    case day
    case evening
    case night

    /// Wall-clock mapping: dawn 5–8, day 8–17, evening 17–21, night otherwise.
    public static func phase(forHour hour: Int) -> AmbientPhase {
        switch hour {
        case 5..<8: .dawn
        case 8..<17: .day
        case 17..<21: .evening
        default: .night
        }
    }
}

public enum Weather: String, Codable, Sendable, CaseIterable {
    case clear
    case hazy
    case drizzle
}

public struct AmbientState: Codable, Sendable, Equatable {
    public var phase: AmbientPhase
    public var weather: Weather

    public init(phase: AmbientPhase, weather: Weather = .clear) {
        self.phase = phase
        self.weather = weather
    }
}

public struct Achievement: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var unlockedAt: Date?

    public init(id: String, title: String, detail: String, unlockedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.unlockedAt = unlockedAt
    }
}

public struct RareVisitor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case goldenFish
        case legendaryWhale
    }

    public var kind: Kind
    public var appearedAt: Date
    public var until: Date

    public init(kind: Kind, appearedAt: Date, until: Date) {
        self.kind = kind
        self.appearedAt = appearedAt
        self.until = until
    }
}

public struct LogLine: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var message: String
    public var at: Date

    public init(id: Int, message: String, at: Date) {
        self.id = id
        self.message = message
        self.at = at
    }
}

/// A live session bound to a fish. Kept in EcosystemState so the engine stays a pure function.
public struct SessionBinding: Codable, Sendable, Equatable {
    public var key: SessionKey
    public var fishID: FishID
    public var descriptor: SessionDescriptor
    /// Open handoff pearls keyed by spawn order, so handoffReturned can resolve the oldest.
    public var openPearlIDs: [Int]

    public init(key: SessionKey, fishID: FishID, descriptor: SessionDescriptor, openPearlIDs: [Int] = []) {
        self.key = key
        self.fishID = fishID
        self.descriptor = descriptor
        self.openPearlIDs = openPearlIDs
    }
}

/// The whole semantic world. Value type; advanced by `EcosystemEngine.advance`.
public struct EcosystemState: Codable, Sendable, Equatable {
    public var fish: [FishState]
    public var sessions: [SessionBinding]
    public var food: [FoodPellet]
    public var pearls: [Pearl]
    public var shark: SharkThreat
    public var reefStage: ReefStage
    public var ambient: AmbientState
    /// Unlocked achievements only.
    public var achievements: [Achievement]
    public var rareVisitor: RareVisitor?
    public var totalTasksCompleted: Int
    public var totalTasksFailed: Int
    /// Recent activity lines for the popover (capped at 20).
    public var eventLog: [LogLine]
    public var createdAt: Date
    /// Monotonic ID source for food/pearls/log lines.
    public var nextEntityID: Int

    public init(
        fish: [FishState] = [],
        sessions: [SessionBinding] = [],
        food: [FoodPellet] = [],
        pearls: [Pearl] = [],
        shark: SharkThreat = SharkThreat(),
        reefStage: ReefStage = .sand,
        ambient: AmbientState,
        achievements: [Achievement] = [],
        rareVisitor: RareVisitor? = nil,
        totalTasksCompleted: Int = 0,
        totalTasksFailed: Int = 0,
        eventLog: [LogLine] = [],
        createdAt: Date,
        nextEntityID: Int = 1
    ) {
        self.fish = fish
        self.sessions = sessions
        self.food = food
        self.pearls = pearls
        self.shark = shark
        self.reefStage = reefStage
        self.ambient = ambient
        self.achievements = achievements
        self.rareVisitor = rareVisitor
        self.totalTasksCompleted = totalTasksCompleted
        self.totalTasksFailed = totalTasksFailed
        self.eventLog = eventLog
        self.createdAt = createdAt
        self.nextEntityID = nextEntityID
    }

    public static func initial(now: Date, calendar: Calendar = .current) -> EcosystemState {
        let hour = calendar.component(.hour, from: now)
        return EcosystemState(ambient: AmbientState(phase: .phase(forHour: hour)), createdAt: now)
    }

    public func fish(withID id: FishID) -> FishState? {
        fish.first { $0.id == id }
    }
}
