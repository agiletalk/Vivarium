import Foundation
import Testing
@testable import VivariumCore

@Suite("Demo event script")
struct DemoScriptTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func collectBatches(seed: UInt64, count: Int) -> [(delay: Duration, events: [AgentEvent])] {
        var scenario = DemoScenario(seed: seed, startedAt: Self.start)
        var now = Self.start
        var batches: [(delay: Duration, events: [AgentEvent])] = []
        for _ in 0..<count {
            let batch = scenario.nextBatch(now: now)
            let seconds = Double(batch.delay.components.seconds)
                + Double(batch.delay.components.attoseconds) * 1e-18
            now = now.addingTimeInterval(seconds)
            batches.append(batch)
        }
        return batches
    }

    @Test("First batch starts exactly one demo session per provider")
    func firstBatch() {
        var scenario = DemoScenario(seed: 1, startedAt: Self.start)
        let (_, events) = scenario.nextBatch(now: Self.start)

        // One session per real, distinct-species provider (all but the phantom `gpt` dolphin).
        let expectedProviders = Set(AgentProvider.allCases).subtracting([.gpt])
        #expect(events.count == expectedProviders.count)
        var providers: Set<AgentProvider> = []
        let names = ["Reef", "Sonar", "Kelp", "Tide", "Coral", "Cove"]
        for event in events {
            guard case .sessionStarted(let descriptor) = event else {
                Issue.record("Expected sessionStarted, got \(event)")
                continue
            }
            providers.insert(descriptor.key.provider)
            #expect(descriptor.key.sessionID == "demo-\(descriptor.key.provider.rawValue)")
            #expect(descriptor.projectKey == "demo/\(descriptor.key.provider.rawValue)")
            #expect(names.contains(descriptor.projectDisplayName))
            #expect(!descriptor.isSubagent)
            #expect(descriptor.startedAt == Self.start)
        }
        #expect(providers == expectedProviders)
    }

    @Test("200 batches produce only plausible event sequences")
    func validSequences() {
        let batches = collectBatches(seed: 0xF15B, count: 200)

        var knownSessions: Set<SessionKey> = []
        var openHandoffs: Set<SessionKey> = []
        var openBugs: Set<SessionKey> = []
        for (_, events) in batches {
            for event in events {
                switch event {
                case .sessionStarted(let descriptor):
                    knownSessions.insert(descriptor.key)
                case .handoff(let key, _, _):
                    #expect(!openHandoffs.contains(key), "handoff while one is already open")
                    openHandoffs.insert(key)
                case .handoffReturned(let key, _):
                    #expect(openHandoffs.contains(key), "handoffReturned without a preceding handoff")
                    openHandoffs.remove(key)
                case .bugDetected(let key, _):
                    #expect(!openBugs.contains(key), "bugDetected while one is already open")
                    openBugs.insert(key)
                case .bugResolved(let key):
                    #expect(openBugs.contains(key), "bugResolved without a preceding bugDetected")
                    openBugs.remove(key)
                case .statusChanged(let key, let status):
                    if openHandoffs.contains(key) {
                        #expect(status == .handingOff, "status change on a session that is handing off")
                    }
                default:
                    break
                }
                if let key = event.sessionKey {
                    #expect(knownSessions.contains(key), "event for an unknown session")
                }
            }
        }

        let all = batches.flatMap(\.events)
        func contains(_ predicate: (AgentEvent) -> Bool) -> Bool { all.contains(where: predicate) }
        #expect(contains { if case .taskCompleted = $0 { true } else { false } })
        #expect(contains { if case .taskFailed = $0 { true } else { false } })
        #expect(contains { if case .handoff = $0 { true } else { false } })
        #expect(contains { if case .handoffReturned = $0 { true } else { false } })
        #expect(contains { if case .bugDetected = $0 { true } else { false } })
        #expect(contains { if case .bugResolved = $0 { true } else { false } })
        #expect(contains { if case .thought = $0 { true } else { false } })
    }

    @Test("Same seed produces identical first 50 batches")
    func determinism() {
        let a = collectBatches(seed: 42, count: 50)
        let b = collectBatches(seed: 42, count: 50)
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            #expect(x.delay == y.delay)
            #expect(x.events == y.events)
        }
    }

    @Test("Different seeds diverge")
    func seedsDiverge() {
        let a = collectBatches(seed: 1, count: 30)
        let b = collectBatches(seed: 2, count: 30)
        #expect(a.map(\.delay) != b.map(\.delay))
    }

    @Test("Delays stay within 1...180 seconds")
    func delayBounds() {
        let batches = collectBatches(seed: 7, count: 200)
        for (delay, _) in batches {
            #expect(delay >= .seconds(1))
            #expect(delay <= .seconds(180))
        }
    }

    @Test("DemoEventScript streams the scenario's events")
    func streamsEvents() async {
        let expectedProviders = Set(AgentProvider.allCases).subtracting([.gpt])
        let script = DemoEventScript(seed: 9, speed: 5_000)
        var received: [AgentEvent] = []
        for await event in script.events() {
            received.append(event)
            if received.count == expectedProviders.count { break }
        }
        let providers = received.compactMap { event -> AgentProvider? in
            if case .sessionStarted(let descriptor) = event { return descriptor.key.provider }
            return nil
        }
        #expect(Set(providers) == expectedProviders)
    }
}
