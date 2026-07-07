import Foundation
import Testing
import VivariumCore
@testable import VivariumDetect

@Suite("DetectionCoordinator")
struct CoordinatorTests {
    /// A scripted source for driving the coordinator deterministically.
    private struct ScriptedSource: AgentEventStreaming {
        let scripted: [AgentEvent]
        func events() -> AsyncStream<AgentEvent> {
            AsyncStream { continuation in
                for event in scripted { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func descriptor(_ id: String, provider: AgentProvider = .claude) -> SessionDescriptor {
        SessionDescriptor(
            key: SessionKey(provider: provider, sessionID: id),
            projectKey: "/tmp/proj",
            projectDisplayName: "proj",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func collect(_ coordinator: DetectionCoordinator, limit: Int) async -> [AgentEvent] {
        var out: [AgentEvent] = []
        for await event in coordinator.events() {
            out.append(event)
            if out.count >= limit { break }
        }
        return out
    }

    @Test("Forwards session events and rate-limits thoughts per session")
    func rateLimitsThoughts() async {
        let key = SessionKey(provider: .claude, sessionID: "s1")
        let source = ScriptedSource(scripted: [
            .sessionStarted(descriptor("s1")),
            .thought(key, message: "one"),
            .thought(key, message: "two"),   // dropped: within 2s of "one"
            .thought(key, message: "three"), // dropped
            .taskCompleted(key, domain: .swift, summary: nil),
        ])
        let coordinator = DetectionCoordinator(sources: [source], processScanner: nil)
        let events = await collect(coordinator, limit: 3)

        let thoughts = events.filter { if case .thought = $0 { return true }; return false }
        #expect(thoughts.count == 1)
        #expect(events.contains { if case .sessionStarted = $0 { return true }; return false })
        #expect(events.contains { if case .taskCompleted = $0 { return true }; return false })
    }

    @Test("Passes non-thought events through untouched")
    func passthrough() async {
        let key = SessionKey(provider: .codex, sessionID: "c1")
        let source = ScriptedSource(scripted: [
            .sessionStarted(descriptor("c1", provider: .codex)),
            .statusChanged(key, .coding),
            .handoff(key, subagentType: "Explore", description: nil),
            .taskFailed(key, reason: "boom"),
        ])
        let coordinator = DetectionCoordinator(sources: [source], processScanner: nil)
        let events = await collect(coordinator, limit: 4)
        #expect(events.count == 4)
    }
}
