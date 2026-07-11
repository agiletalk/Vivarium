import Foundation
import Testing
import VivariumCore
@testable import Vivarium

@MainActor
@Suite("WaitingNotifier")
struct WaitingNotifierTests {
    private func fish(_ name: String, _ status: AgentStatus) -> FishState {
        FishState(
            id: FishID(rawValue: name),
            provider: .claude,
            displayName: "Claude · \(name)",
            isResident: true,
            status: status,
            lastActiveAt: Date(timeIntervalSince1970: 1),
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    @Test("waitingIDs selects only fish that are waiting for the user")
    func waitingIDsSelectsWaiting() {
        var state = EcosystemState.initial(now: Date(timeIntervalSince1970: 1))
        state.fish = [
            fish("a", .waiting),
            fish("b", .coding),
            fish("c", .waiting),
            fish("d", .resting),
            fish("e", .celebrating),
        ]
        #expect(WaitingNotifier.waitingIDs(in: state) == Set([FishID(rawValue: "a"), FishID(rawValue: "c")]))
    }

    @Test("newlyWaiting returns only fresh entrants, not those leaving or unchanged")
    func newlyWaitingIsEdgeTriggered() {
        let a = FishID(rawValue: "a"), b = FishID(rawValue: "b"), c = FishID(rawValue: "c")
        #expect(WaitingNotifier.newlyWaiting(previous: [a], current: [a, b, c]) == Set([b, c]))
        #expect(WaitingNotifier.newlyWaiting(previous: [a, b], current: [a]).isEmpty) // b left → not new
        #expect(WaitingNotifier.newlyWaiting(previous: [a], current: [a]).isEmpty)    // unchanged
        #expect(WaitingNotifier.newlyWaiting(previous: [], current: []).isEmpty)
    }
}
