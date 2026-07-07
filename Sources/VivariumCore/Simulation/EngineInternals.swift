import Foundation

/// Event application: sessions→fish binding, statuses, thoughts, food, pearls, shark.
/// Placeholder pending the engine module implementation.
enum EngineEventHandler {
    static func apply(
        _ event: AgentEvent,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        rng: inout SplitMix64
    ) {
        // Implemented in the engine module pass.
    }

    static func applyIntent(
        _ intent: SceneIntent,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        // Implemented in the engine module pass.
    }
}

/// Time-based aging: thought expiry, fatigue, food timeout, reef/ambient/visitor/achievements.
/// Placeholder pending the engine module implementation.
enum EngineTicker {
    static func tick(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        rng: inout SplitMix64,
        calendar: Calendar
    ) {
        // Implemented in the engine module pass.
    }
}
