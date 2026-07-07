import Foundation
import Testing
@testable import VivariumCore

@Suite("Core vocabulary")
struct ModelTests {
    @Test("Provider species mapping matches the design")
    func speciesMapping() {
        #expect(AgentProvider.claude.species == .whale)
        #expect(AgentProvider.codex.species == .octopus)
        #expect(AgentProvider.gemini.species == .jellyfish)
        #expect(AgentProvider.cursor.species == .pufferfish)
        #expect(AgentProvider.gpt.species == .dolphin)
    }

    @Test("Reef stage thresholds are monotonic")
    func reefThresholds() {
        let stages = ReefStage.allCases
        for (a, b) in zip(stages, stages.dropFirst()) {
            #expect(a.threshold < b.threshold)
        }
        #expect(ReefStage.stage(forCompletedTasks: 0) == .sand)
        #expect(ReefStage.stage(forCompletedTasks: 10) == .coral)
        #expect(ReefStage.stage(forCompletedTasks: 9999) == .grandAquarium)
    }

    @Test("SplitMix64 is deterministic")
    func rngDeterminism() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<100 {
            #expect(a.next() == b.next())
        }
        var c = SplitMix64(seed: 42)
        for _ in 0..<100 {
            let u = c.unit()
            #expect(u >= 0 && u < 1)
        }
    }

    @Test("EcosystemState round-trips through Codable")
    func stateCodable() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = EcosystemState.initial(now: now)
        state.fish.append(
            FishState(
                id: .resident(provider: .claude, projectKey: "/tmp/proj"),
                provider: .claude,
                displayName: "Claude · proj",
                projectKey: "/tmp/proj",
                isResident: true,
                lastActiveAt: now,
                createdAt: now
            )
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EcosystemState.self, from: data)
        #expect(decoded == state)
    }

    @Test("Ambient phase from hour")
    func ambientPhase() {
        #expect(AmbientPhase.phase(forHour: 6) == .dawn)
        #expect(AmbientPhase.phase(forHour: 12) == .day)
        #expect(AmbientPhase.phase(forHour: 18) == .evening)
        #expect(AmbientPhase.phase(forHour: 23) == .night)
        #expect(AmbientPhase.phase(forHour: 2) == .night)
    }
}
