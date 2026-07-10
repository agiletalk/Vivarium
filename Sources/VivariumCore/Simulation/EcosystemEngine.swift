import Foundation

/// Result of one engine step: the next world state plus the diff events the scene needs.
public struct EngineOutput: Sendable {
    public var state: EcosystemState
    public var events: [EcosystemEvent]

    public init(state: EcosystemState, events: [EcosystemEvent]) {
        self.state = state
        self.events = events
    }
}

/// Pure ecosystem state machine. All mutation happens through `advance` and `apply(intent:)`
/// so the entire simulation is unit-testable without UI.
public enum EcosystemEngine {
    /// Advances the world one semantic tick (~0.5 s): applies detection events, ages thoughts,
    /// accrues/recovers fatigue, times out food, resolves the shark, evolves the reef,
    /// updates ambience from the wall clock, rolls for rare visitors, checks achievements.
    public static func advance(
        _ state: EcosystemState,
        events: [AgentEvent],
        now: Date,
        rng: inout SplitMix64,
        calendar: Calendar = .current
    ) -> EngineOutput {
        var next = state
        var out: [EcosystemEvent] = []
        for event in events {
            apply(event, to: &next, events: &out, now: now, rng: &rng)
        }
        tick(&next, events: &out, now: now, rng: &rng, calendar: calendar)
        return EngineOutput(state: next, events: out)
    }

    /// Applies a spatial intent reported by the scene (eat detection, selection).
    public static func apply(
        intent: SceneIntent,
        to state: EcosystemState,
        now: Date
    ) -> EngineOutput {
        var next = state
        var out: [EcosystemEvent] = []
        applyIntent(intent, to: &next, events: &out, now: now)
        return EngineOutput(state: next, events: out)
    }

    /// Drops a food pellet for every visible fish — the aquarium HUD "feed" test control.
    /// Routes through the same food primitive as real task completion so fish eat and grow identically.
    public static func feedAll(_ state: EcosystemState, now: Date) -> EngineOutput {
        var next = state
        var out: [EcosystemEvent] = []
        for id in next.fish.map(\.id) {
            EngineSupport.dropFood(for: id, in: &next, events: &out, now: now)
        }
        return EngineOutput(state: next, events: out)
    }

    // MARK: - Implementation seams (filled in by the engine module)

    static func apply(
        _ event: AgentEvent,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        rng: inout SplitMix64
    ) {
        EngineEventHandler.apply(event, to: &state, events: &events, now: now, rng: &rng)
    }

    static func tick(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        rng: inout SplitMix64,
        calendar: Calendar
    ) {
        EngineTicker.tick(&state, events: &events, now: now, rng: &rng, calendar: calendar)
    }

    static func applyIntent(
        _ intent: SceneIntent,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        EngineEventHandler.applyIntent(intent, to: &state, events: &events, now: now)
    }
}
