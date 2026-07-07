import Foundation

/// One achievement's metadata plus an optional state predicate. Predicate-less entries are
/// unlocked directly by the event handler (e.g. shark-slayer); both paths share `unlock(id:)`.
struct AchievementDefinition: Sendable {
    let id: String
    let title: String
    let detail: String
    /// Checked every tick with (state, events emitted so far this advance, now, calendar).
    let predicate: (@Sendable (EcosystemState, [EcosystemEvent], Date, Calendar) -> Bool)?

    init(
        id: String,
        title: String,
        detail: String,
        predicate: (@Sendable (EcosystemState, [EcosystemEvent], Date, Calendar) -> Bool)? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.predicate = predicate
    }
}

enum AchievementCatalog {
    static let all: [AchievementDefinition] = [
        AchievementDefinition(
            id: "first-task",
            title: "First Catch",
            detail: "Complete your first task.",
            predicate: { state, _, _, _ in state.totalTasksCompleted >= 1 }
        ),
        AchievementDefinition(
            id: "ten-tasks",
            title: "Ten Feasts",
            detail: "Complete ten tasks.",
            predicate: { state, _, _, _ in state.totalTasksCompleted >= 10 }
        ),
        AchievementDefinition(
            id: "hundred-tasks",
            title: "Century Reef",
            detail: "Complete one hundred tasks.",
            predicate: { state, _, _, _ in state.totalTasksCompleted >= 100 }
        ),
        AchievementDefinition(
            id: "shark-slayer",
            title: "Shark Slayer",
            detail: "Resolve a detected bug and drive the shark away."
        ),
        AchievementDefinition(
            id: "night-owl",
            title: "Night Owl",
            detail: "Complete a task between midnight and 5 AM.",
            predicate: { _, events, now, calendar in
                taskCompleted(in: events) && (0..<5).contains(calendar.component(.hour, from: now))
            }
        ),
        AchievementDefinition(
            id: "weekend-warrior",
            title: "Weekend Warrior",
            detail: "Complete a task on a weekend.",
            predicate: { _, events, now, calendar in
                guard taskCompleted(in: events) else { return false }
                let weekday = calendar.component(.weekday, from: now)
                return weekday == 1 || weekday == 7
            }
        ),
        AchievementDefinition(
            id: "school-of-five",
            title: "Full House",
            detail: "Have five fish in the aquarium at once.",
            predicate: { state, _, _, _ in state.fish.count >= 5 }
        ),
        AchievementDefinition(
            id: "legendary",
            title: "Legend of the Deep",
            detail: "Raise a legendary fish.",
            predicate: { state, _, _, _ in state.fish.contains(where: \.isLegendary) }
        ),
    ]

    static func definition(id: String) -> AchievementDefinition? {
        all.first { $0.id == id }
    }

    /// Shared unlock path: appends the achievement once, emits the event, and logs.
    static func unlock(
        id: String,
        in state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard let definition = definition(id: id),
              !state.achievements.contains(where: { $0.id == id })
        else { return }
        let achievement = Achievement(
            id: definition.id,
            title: definition.title,
            detail: definition.detail,
            unlockedAt: now
        )
        state.achievements.append(achievement)
        events.append(.achievementUnlocked(achievement))
        EngineSupport.log("Achievement unlocked: \(definition.title)", in: &state, now: now)
    }

    /// Evaluates every predicate-backed achievement against the current state; called each tick.
    static func checkAll(
        in state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        calendar: Calendar
    ) {
        for definition in all {
            guard let predicate = definition.predicate,
                  !state.achievements.contains(where: { $0.id == definition.id }),
                  predicate(state, events, now, calendar)
            else { continue }
            unlock(id: definition.id, in: &state, events: &events, now: now)
        }
    }

    /// Whether a task completed during this advance (food is only dropped by taskCompleted).
    private static func taskCompleted(in events: [EcosystemEvent]) -> Bool {
        events.contains { if case .foodDropped = $0 { true } else { false } }
    }
}
