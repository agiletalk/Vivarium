import SwiftUI
import Testing
@testable import Vivarium
import VivariumCore

@MainActor
@Suite("Shoal design tokens & labels")
struct ShoalStyleTests {
    // MARK: - Fatigue color ramp

    @Test("Fatigue ramp switches green < 0.4, yellow < 0.75, amber above")
    func fatigueRampBands() {
        // Same band → same color.
        #expect(Shoal.fatigue(0.0) == Shoal.fatigue(0.39))
        #expect(Shoal.fatigue(0.4) == Shoal.fatigue(0.74))
        #expect(Shoal.fatigue(0.75) == Shoal.fatigue(1.0))
        // Crossing a boundary → different color.
        #expect(Shoal.fatigue(0.39) != Shoal.fatigue(0.4))
        #expect(Shoal.fatigue(0.74) != Shoal.fatigue(0.75))
        // The low band is the shared "active" green.
        #expect(Shoal.fatigue(0.1) == Shoal.active)
    }

    // MARK: - AmbientPhase UI extensions

    @Test("cycled advances dawn → day → evening → night → dawn")
    func ambientCycle() {
        #expect(AmbientPhase.dawn.cycled == .day)
        #expect(AmbientPhase.day.cycled == .evening)
        #expect(AmbientPhase.evening.cycled == .night)
        #expect(AmbientPhase.night.cycled == .dawn)
        // Four steps return to the start.
        #expect(AmbientPhase.dawn.cycled.cycled.cycled.cycled == .dawn)
    }

    @Test("Every phase has a distinct emoji and a Korean lighting label")
    func ambientLabels() {
        let phases = AmbientPhase.allCases
        #expect(Set(phases.map(\.emoji)).count == phases.count)
        #expect(phases.allSatisfy { !$0.emoji.isEmpty })
        #expect(Set(phases.map(\.lightingLabel)).count == phases.count)
        #expect(phases.allSatisfy { $0.lightingLabel.hasSuffix("조명") })
        #expect(AmbientPhase.day.lightingLabel == "낮 조명")
    }

    // MARK: - Status & reef labels (exhaustive via CaseIterable)

    @Test("Every AgentStatus has a distinct, non-empty humanized label")
    func statusHumanized() {
        let all = AgentStatus.allCases
        #expect(all.allSatisfy { !$0.humanized.isEmpty })
        #expect(Set(all.map(\.humanized)).count == all.count)
        // Spot-check the design copy.
        #expect(AgentStatus.coding.humanized == "Editing…")
        #expect(AgentStatus.testing.humanized == "Running tests…")
        #expect(AgentStatus.waiting.humanized == "Waiting for you")
    }

    @Test("Every ReefStage has a distinct, non-empty display name")
    func reefDisplayNames() {
        let all = ReefStage.allCases
        #expect(all.allSatisfy { !$0.displayName.isEmpty })
        #expect(Set(all.map(\.displayName)).count == all.count)
        #expect(ReefStage.sand.displayName == "Sandy Bottom")
        #expect(ReefStage.grandAquarium.displayName == "Grand Aquarium")
    }
}
