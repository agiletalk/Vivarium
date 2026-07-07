import Foundation
import Testing
@testable import VivariumCore

@Suite("EcosystemEngine")
struct EngineTests {
    // 2023-11-14 22:13:20 UTC == 2023-11-15 07:13:20 KST (Wednesday, hour 7 → dawn).
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let projectKey = "/Users/dev/Vivarium"

    static let seoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    func makeState() -> EcosystemState {
        EcosystemState.initial(now: t0, calendar: Self.seoul)
    }

    func key(_ sessionID: String = "s1", provider: AgentProvider = .claude) -> SessionKey {
        SessionKey(provider: provider, sessionID: sessionID)
    }

    func descriptor(_ sessionID: String = "s1", provider: AgentProvider = .claude) -> SessionDescriptor {
        SessionDescriptor(
            key: key(sessionID, provider: provider),
            projectKey: projectKey,
            projectDisplayName: "Vivarium",
            startedAt: t0
        )
    }

    func advance(_ state: EcosystemState, _ events: [AgentEvent], at now: Date, seed: UInt64 = 7) -> EngineOutput {
        var rng = SplitMix64(seed: seed)
        return EcosystemEngine.advance(state, events: events, now: now, rng: &rng, calendar: Self.seoul)
    }

    func contains(_ events: [EcosystemEvent], _ predicate: (EcosystemEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }

    @Test("Sequential sessions reuse the same resident fish")
    func residentReuse() {
        var out = advance(makeState(), [.sessionStarted(descriptor("s1"))], at: t0)
        let residentID = FishID.resident(provider: .claude, projectKey: projectKey)
        #expect(out.state.fish.count == 1)
        #expect(out.state.fish[0].id == residentID)
        #expect(out.state.fish[0].isResident)
        #expect(out.state.fish[0].sessionCount == 1)
        #expect(out.state.fish[0].status == .planning)
        #expect(contains(out.events) { if case .fishAdded = $0 { true } else { false } })

        out = advance(out.state, [.sessionEnded(key("s1"), at: t0.addingTimeInterval(10))], at: t0.addingTimeInterval(10))
        #expect(out.state.sessions.isEmpty)
        #expect(out.state.fish.count == 1)
        #expect(out.state.fish[0].status == .resting)
        #expect(out.state.fish[0].currentSessionTitle == nil)

        out = advance(out.state, [.sessionStarted(descriptor("s2"))], at: t0.addingTimeInterval(20))
        #expect(out.state.fish.count == 1)
        #expect(out.state.fish[0].id == residentID)
        #expect(out.state.fish[0].sessionCount == 2)
        #expect(out.state.fish[0].status == .planning)
        #expect(out.events.contains(.fishStatusChanged(residentID, .planning)))
    }

    @Test("Concurrent second session spawns an ephemeral fish removed on end")
    func concurrentEphemeral() {
        var out = advance(
            makeState(),
            [.sessionStarted(descriptor("s1")), .sessionStarted(descriptor("s2"))],
            at: t0
        )
        let ephemeralID = FishID.ephemeral(provider: .claude, sessionID: "s2")
        #expect(out.state.fish.count == 2)
        #expect(out.state.sessions.count == 2)
        let ephemeral = out.state.fish(withID: ephemeralID)
        #expect(ephemeral != nil)
        #expect(ephemeral?.isResident == false)
        #expect(ephemeral?.size == 0.85)

        out = advance(out.state, [.sessionEnded(key("s2"), at: t0.addingTimeInterval(5))], at: t0.addingTimeInterval(5))
        #expect(out.state.fish.count == 1)
        #expect(out.state.fish(withID: ephemeralID) == nil)
        #expect(out.events.contains(.fishRemoved(ephemeralID)))
        #expect(out.state.sessions.count == 1)
    }

    @Test("taskCompleted drops food, bumps counters, and evolves the reef exactly once")
    func taskCompletedReef() {
        var out = advance(makeState(), [.sessionStarted(descriptor())], at: t0)
        var state = out.state
        state.totalTasksCompleted = 9

        let t1 = t0.addingTimeInterval(1)
        out = advance(state, [.taskCompleted(key(), domain: .swift, summary: "Wired the reef")], at: t1)
        #expect(out.state.totalTasksCompleted == 10)
        #expect(out.state.fish[0].tasksCompleted == 1)
        #expect(out.state.fish[0].status == .celebrating)
        #expect(out.state.food.count == 1)
        #expect(contains(out.events) { if case .foodDropped = $0 { true } else { false } })
        let reefChanges = out.events.filter { if case .reefStageChanged = $0 { true } else { false } }
        #expect(reefChanges == [.reefStageChanged(.coral)])
        #expect(out.state.reefStage == .coral)
        #expect(out.state.fish[0].memory == [MemoryTrait(domain: .swift, level: 1)])

        out = advance(out.state, [.taskCompleted(key(), domain: .swift, summary: nil)], at: t1.addingTimeInterval(1))
        #expect(out.state.totalTasksCompleted == 11)
        #expect(!contains(out.events) { if case .reefStageChanged = $0 { true } else { false } })
        #expect(out.state.reefStage == .coral)
    }

    @Test("foodEaten grows a resident, relieves fatigue, and caps size at 1.45")
    func foodEatenIntent() {
        var state = makeState()
        let fishID = FishID.resident(provider: .claude, projectKey: projectKey)
        state.fish = [
            FishState(
                id: fishID,
                provider: .claude,
                displayName: "Claude · Vivarium",
                projectKey: projectKey,
                isResident: true,
                status: .waiting,
                fatigue: 0.5,
                lastActiveAt: t0,
                createdAt: t0
            )
        ]
        state.food = [FoodPellet(id: 1, fish: fishID, createdAt: t0)]
        state.nextEntityID = 2

        var out = EcosystemEngine.apply(intent: .foodEaten(id: 1, by: fishID), to: state, now: t0)
        #expect(out.state.food[0].state == .eaten)
        #expect(abs(out.state.fish[0].size - 1.055) < 1e-9)
        #expect(abs(out.state.fish[0].fatigue - 0.38) < 1e-9)
        #expect(contains(out.events) { if case .fishGrew(fishID, _) = $0 { true } else { false } })
        #expect(contains(out.events) { if case .fishFatigueChanged(fishID, _) = $0 { true } else { false } })
        #expect(out.state.fish[0].thought?.message == "Yum!")
        #expect(out.events.contains(.fishThought(fishID, "Yum!")))

        state = out.state
        state.fish[0].size = 1.44
        state.food.append(FoodPellet(id: 2, fish: fishID, createdAt: t0))
        out = EcosystemEngine.apply(intent: .foodEaten(id: 2, by: fishID), to: state, now: t0)
        #expect(out.state.fish[0].size == 1.45)

        // Already-eaten pellets are ignored.
        let before = out.state
        out = EcosystemEngine.apply(intent: .foodEaten(id: 2, by: fishID), to: before, now: t0)
        #expect(out.state == before)
        #expect(out.events.isEmpty)
    }

    @Test("taskFailed marks the newest pellet of that fish as missed")
    func taskFailedMissesNewestPellet() {
        var out = advance(makeState(), [.sessionStarted(descriptor())], at: t0)
        let t1 = t0.addingTimeInterval(1)
        out = advance(
            out.state,
            [
                .taskCompleted(key(), domain: nil, summary: nil),
                .taskCompleted(key(), domain: nil, summary: nil),
            ],
            at: t1
        )
        #expect(out.state.food.count == 2)
        let ids = out.state.food.map(\.id)

        out = advance(out.state, [.taskFailed(key(), reason: "tests red")], at: t1.addingTimeInterval(1))
        #expect(out.state.totalTasksFailed == 1)
        #expect(out.state.fish[0].tasksFailed == 1)
        #expect(out.state.food.first { $0.id == ids[1] }?.state == .missed)
        #expect(out.state.food.first { $0.id == ids[0] }?.state == .falling)
        #expect(out.events.contains(.foodMissed(id: ids[1])))
    }

    @Test("handoff spawns an outbound pearl that returns via handoffReturned")
    func handoffPearlLifecycle() {
        var out = advance(makeState(), [.sessionStarted(descriptor())], at: t0)
        out = advance(out.state, [.handoff(key(), subagentType: "Explore", description: nil)], at: t0)
        #expect(out.state.pearls.count == 1)
        let pearlID = out.state.pearls[0].id
        #expect(out.state.pearls[0].phase == .outbound)
        #expect(out.state.pearls[0].label == "Explore")
        #expect(out.state.sessions[0].openPearlIDs == [pearlID])
        #expect(out.state.fish[0].status == .handingOff)
        #expect(contains(out.events) { if case .pearlSpawned = $0 { true } else { false } })
        let afterHandoff = out.state

        // Outbound pearls start working after 2 s.
        out = advance(afterHandoff, [], at: t0.addingTimeInterval(2.5))
        #expect(out.state.pearls[0].phase == .working)
        #expect(out.events.contains(.pearlPhaseChanged(id: pearlID, phase: .working)))

        out = advance(afterHandoff, [.handoffReturned(key(), success: true)], at: t0.addingTimeInterval(1))
        #expect(out.state.pearls[0].phase == .returned)
        #expect(out.state.sessions[0].openPearlIDs.isEmpty)
        #expect(out.events.contains(.pearlPhaseChanged(id: pearlID, phase: .returned)))
    }

    @Test("Shark appears on bugDetected, escalates on repeats, and leaves on bugResolved")
    func sharkLifecycle() {
        var out = advance(makeState(), [.sessionStarted(descriptor())], at: t0)
        let fishID = out.state.fish[0].id
        let evidence = String(repeating: "x", count: 60)

        let t1 = t0.addingTimeInterval(1)
        out = advance(out.state, [.bugDetected(key(), evidence: evidence)], at: t1)
        #expect(out.state.shark.isActive)
        #expect(out.state.shark.severity == 0.5)
        #expect(out.state.shark.label.count <= 40)
        #expect(out.state.shark.causeFish == fishID)
        #expect(out.state.fish[0].status == .fixingBug)
        #expect(out.events.contains(.sharkAppeared(label: out.state.shark.label, severity: 0.5)))

        out = advance(out.state, [.bugDetected(key(), evidence: "again")], at: t1.addingTimeInterval(1))
        #expect(out.state.shark.severity == 0.75)

        out = advance(out.state, [.bugResolved(key())], at: t1.addingTimeInterval(2))
        #expect(!out.state.shark.isActive)
        #expect(out.events.contains(.sharkLeft))
        #expect(out.state.fish[0].status == .celebrating)
        let unlocked = out.state.achievements.filter { $0.id == "shark-slayer" }
        #expect(unlocked.count == 1)

        // Resolving again with no active shark is a no-op.
        out = advance(out.state, [.bugResolved(key())], at: t1.addingTimeInterval(3))
        #expect(!out.events.contains(.sharkLeft))
        #expect(out.state.achievements.filter { $0.id == "shark-slayer" }.count == 1)
    }

    @Test("Fatigue accrues while coding, recovers while resting, and triggers auto-rest")
    func fatigueLifecycle() {
        var out = advance(makeState(), [.sessionStarted(descriptor()), .statusChanged(key(), .coding)], at: t0)
        let fishID = out.state.fish[0].id
        #expect(abs(out.state.fish[0].fatigue - 0.0025) < 1e-9)

        out = advance(out.state, [.statusChanged(key(), .resting)], at: t0.addingTimeInterval(1))
        #expect(out.state.fish[0].fatigue == 0)

        // Quantized emission: 0.049 → 0.0515 crosses the 0.05 bucket boundary…
        var state = out.state
        state.fish[0].status = .coding
        state.fish[0].fatigue = 0.049
        out = advance(state, [], at: t0.addingTimeInterval(2))
        #expect(contains(out.events) { if case .fishFatigueChanged(fishID, _) = $0 { true } else { false } })
        // …but the next tick inside the same bucket stays silent.
        out = advance(out.state, [], at: t0.addingTimeInterval(2.5))
        #expect(!contains(out.events) { if case .fishFatigueChanged = $0 { true } else { false } })

        // Auto-rest at 0.95.
        state = out.state
        state.fish[0].status = .coding
        state.fish[0].fatigue = 0.95
        out = advance(state, [], at: t0.addingTimeInterval(3))
        #expect(out.state.fish[0].status == .resting)
        #expect(out.state.fish[0].thought?.message == "Taking a breather…")
        #expect(out.events.contains(.fishStatusChanged(fishID, .resting)))
    }

    @Test("Achievements unlock exactly once")
    func achievementsUnlockOnce() {
        var out = advance(makeState(), [.sessionStarted(descriptor())], at: t0)
        out = advance(out.state, [.taskCompleted(key(), domain: nil, summary: nil)], at: t0.addingTimeInterval(1))
        let unlocked = out.events.compactMap { event -> Achievement? in
            if case .achievementUnlocked(let achievement) = event { achievement } else { nil }
        }
        #expect(unlocked.count == 1)
        #expect(unlocked.first?.id == "first-task")
        #expect(unlocked.first?.unlockedAt == t0.addingTimeInterval(1))

        out = advance(out.state, [], at: t0.addingTimeInterval(2))
        #expect(!contains(out.events) { if case .achievementUnlocked = $0 { true } else { false } })
        #expect(out.state.achievements.count == 1)
    }

    @Test("Ambient phase change emits when the hour crosses a boundary")
    func ambientBoundary() {
        var out = advance(makeState(), [], at: t0)
        #expect(out.state.ambient.phase == .dawn)
        #expect(!contains(out.events) { if case .ambientChanged = $0 { true } else { false } })

        // 07:13 → 08:13 KST crosses dawn → day.
        out = advance(out.state, [], at: t0.addingTimeInterval(3600))
        #expect(out.state.ambient.phase == .day)
        #expect(out.events.contains(.ambientChanged(AmbientState(phase: .day))))
    }

    @Test("Provider fish appears on walking activity and is removed after 10 idle minutes")
    func providerFishLifecycle() {
        let gemini = FishID.provider(.gemini)
        var out = advance(
            makeState(),
            [.providerActivity(.gemini, score: 0.4, level: .walking, processCount: 1)],
            at: t0
        )
        #expect(out.state.fish(withID: gemini)?.status == .searching)
        #expect(out.state.fish(withID: gemini)?.activityLevel == .walking)
        #expect(contains(out.events) { if case .fishAdded = $0 { true } else { false } })

        out = advance(
            out.state,
            [.providerActivity(.gemini, score: 0, level: .sleeping, processCount: 0)],
            at: t0.addingTimeInterval(10)
        )
        #expect(out.state.fish(withID: gemini)?.status == .resting)
        #expect(out.events.contains(.fishStatusChanged(gemini, .resting)))

        out = advance(out.state, [], at: t0.addingTimeInterval(700))
        #expect(out.state.fish(withID: gemini) == nil)
        #expect(out.events.contains(.fishRemoved(gemini)))
    }
}
