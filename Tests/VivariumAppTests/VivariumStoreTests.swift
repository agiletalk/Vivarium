import Foundation
import Testing
@testable import Vivarium
import VivariumCore

/// A canned event source: yields the scripted events once, then finishes.
private final class ScriptedSource: AgentEventStreaming, @unchecked Sendable {
    private let scripted: [AgentEvent]
    init(_ scripted: [AgentEvent]) { self.scripted = scripted }
    func events() -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@MainActor
@Suite("VivariumStore")
struct VivariumStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func freshDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "viv.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func descriptor(_ sessionID: String = "s1", provider: AgentProvider = .claude) -> SessionDescriptor {
        SessionDescriptor(
            key: SessionKey(provider: provider, sessionID: sessionID),
            projectKey: "/Users/dev/Proj",
            projectDisplayName: "Proj",
            startedAt: t0
        )
    }

    private func waitingFish(_ id: String, status: AgentStatus, waitKind: WaitKind? = nil, idleSeconds: TimeInterval) -> FishState {
        FishState(
            id: FishID(rawValue: id),
            provider: .claude,
            displayName: "Claude · \(id)",
            isResident: true,
            status: status,
            waitKind: waitKind,
            lastActiveAt: t0.addingTimeInterval(-idleSeconds),
            createdAt: t0.addingTimeInterval(-idleSeconds)
        )
    }

    @Test("settledWaitingCount counts only long-settled, non-permission-prompt waits")
    func settledWaitingCount() {
        let fish: [FishState] = [
            waitingFish("settled", status: .waiting, idleSeconds: 30),                              // ✓
            waitingFish("fresh", status: .waiting, idleSeconds: 3),                                 // ✗ between-turn blip
            waitingFish("permission", status: .waiting, waitKind: .permissionPrompt, idleSeconds: 60), // ✗ excluded kind
            waitingFish("coding", status: .coding, idleSeconds: 30),                                // ✗ not waiting
            waitingFish("endturn", status: .waiting, waitKind: .endOfTurn, idleSeconds: 30),        // ✓
        ]
        #expect(VivariumStore.settledWaitingCount(fish: fish, now: t0) == 2)
        #expect(VivariumStore.settledWaitingCount(fish: [], now: t0) == 0)
    }

    private func makeStore(
        liveSource: (any AgentEventStreaming)? = nil,
        demoSource: (any AgentEventStreaming)? = nil,
        persistence: StatePersistence? = nil,
        forceDemo: Bool = false,
        defaults: UserDefaults
    ) -> VivariumStore {
        VivariumStore(
            liveSource: liveSource,
            demoSource: demoSource,
            persistence: persistence,
            forceDemo: forceDemo,
            defaults: defaults,
            now: t0
        )
    }

    private func poll(timeout: Duration = .seconds(5), until: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if until() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return until()
    }

    // MARK: - Initial data-source mode

    @Test("Fresh install with a demo source starts in demo mode")
    func startsInDemoMode() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = makeStore(demoSource: ScriptedSource([]), defaults: d)
        #expect(store.dataSourceMode == .demo)
    }

    @Test("No demo source and no prior state starts idle")
    func startsIdleWithoutDemoSource() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = makeStore(defaults: d)
        #expect(store.dataSourceMode == .idle)
    }

    @Test("Having seen a real event before suppresses the first-run demo")
    func seenRealEventSuppressesDemo() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: "hasSeenRealEvent")
        let store = makeStore(demoSource: ScriptedSource([]), defaults: d)
        #expect(store.dataSourceMode == .idle)
    }

    @Test("Persisted state suppresses the first-run demo")
    func persistedStateSuppressesDemo() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = dir.appendingPathComponent("state.json")
        let persistence = StatePersistence(fileURL: fileURL)
        try? persistence.save(EcosystemState.initial(now: t0))
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeStore(demoSource: ScriptedSource([]), persistence: persistence, defaults: d)
        #expect(store.dataSourceMode == .idle)
    }

    @Test("forceDemo overrides prior state and shows the demo")
    func forceDemoOverrides() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: "hasSeenRealEvent")
        let store = makeStore(demoSource: ScriptedSource([]), forceDemo: true, defaults: d)
        #expect(store.dataSourceMode == .demo)
    }

    // MARK: - Synchronous surface

    @Test("Selecting a fish is handled locally, not through the engine")
    func fishSelectionIntent() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = makeStore(defaults: d)
        let id = FishID.resident(provider: .claude, projectKey: "x")
        store.apply(.fishSelected(id))
        #expect(store.selectedFishID == id)
        store.apply(.fishSelected(nil))
        #expect(store.selectedFishID == nil)
    }

    @Test("A no-op engine intent neither bumps the version nor emits events")
    func noOpIntentIsSilent() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = makeStore(defaults: d)
        var emitted = 0
        store.onEcosystemEvents = { _ in emitted += 1 }
        let before = store.stateVersion
        // No such pellet/fish exists in the initial state, so the engine returns unchanged.
        store.apply(.foodEaten(id: 999, by: FishID.resident(provider: .claude, projectKey: "x")))
        #expect(store.stateVersion == before)
        #expect(emitted == 0)
    }

    @Test("feedAll is a no-op with an empty tank")
    func feedAllEmptyTankIsNoOp() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = makeStore(defaults: d)
        var emitted = 0
        store.onEcosystemEvents = { _ in emitted += 1 }
        let before = store.stateVersion
        store.feedAll()
        #expect(store.stateVersion == before)
        #expect(emitted == 0)
    }

    @Test("resetAquarium clears selection, reinitializes, and reconciles the scene")
    func resetAquarium() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = makeStore(defaults: d)
        store.selectedFishID = FishID.resident(provider: .claude, projectKey: "x")
        var reconciled = false
        store.onReconcile = { _ in reconciled = true }
        let before = store.stateVersion

        store.resetAquarium()

        #expect(store.selectedFishID == nil)
        #expect(store.state.fish.isEmpty)
        #expect(store.stateVersion == before &+ 1)
        #expect(reconciled)
    }

    @Test("saveNow writes a snapshot that loads back")
    func saveNowPersists() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = dir.appendingPathComponent("nested/state.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = StatePersistence(fileURL: fileURL)
        let store = makeStore(persistence: persistence, defaults: d)

        store.saveNow()

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(persistence.load(now: t0) != nil)
    }

    // MARK: - Live pump integration (bounded async)

    @Test("A live session event adds a fish, flips to live mode, and records the flag")
    func liveEventDrivesState() async {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let key = SessionKey(provider: .claude, sessionID: "s1")
        let source = ScriptedSource([
            .sessionStarted(descriptor("s1")),
            .taskCompleted(key, domain: .swift, summary: "done"),
        ])
        // demoSource nil so the demo path never competes with the live pump.
        let store = makeStore(liveSource: source, defaults: d)
        #expect(store.dataSourceMode == .idle)
        // Simulate the aquarium being open so the store ticks fast (500ms) instead of the 5s idle
        // cadence — otherwise the first event isn't drained until the idle tick wakes.
        store.isAquariumVisible = true

        store.start()
        let appeared = await poll(timeout: .seconds(3)) { store.state.fish.count == 1 }
        store.stop()

        #expect(appeared)
        #expect(store.dataSourceMode == .live)
        #expect(d.bool(forKey: "hasSeenRealEvent"))
    }
}
