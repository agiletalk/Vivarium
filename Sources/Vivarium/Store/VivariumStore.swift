import Foundation
import Observation
import VivariumCore

enum DataSourceMode: String {
    case live
    case idle
    case demo
}

struct BannerModel: Equatable {
    var title: String
    var detail: String
    var systemImage: String
}

/// Single source of truth. Consumes AgentEvents from detection (or demo), advances the
/// pure engine on a semantic tick, and publishes state to SwiftUI + diff events to the scene.
@MainActor
@Observable
final class VivariumStore {
    private(set) var state: EcosystemState
    /// Bumped whenever the semantic state changed; the scene compares it per frame.
    private(set) var stateVersion: UInt64 = 0
    private(set) var dataSourceMode: DataSourceMode = .idle
    var selectedFishID: FishID?
    var isAquariumVisible = false
    private(set) var banner: BannerModel?

    /// The scene (and only the scene) sets these; both run on the main actor.
    @ObservationIgnored var onEcosystemEvents: (@MainActor ([EcosystemEvent]) -> Void)?
    @ObservationIgnored var onReconcile: (@MainActor (EcosystemState) -> Void)?

    var hasActiveAgents: Bool {
        state.fish.contains { $0.status.isActive || $0.activityLevel.isActive }
    }

    var activeFishCount: Int {
        state.fish.count { $0.status.isActive || $0.activityLevel.isActive }
    }

    private let liveSource: (any AgentEventStreaming)?
    private let demoSource: (any AgentEventStreaming)?
    private let persistence: StatePersistence?
    private let forceDemo: Bool
    private let defaults: UserDefaults

    @ObservationIgnored private var pendingEvents: [AgentEvent] = []
    @ObservationIgnored private var rng: SplitMix64
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var livePumpTask: Task<Void, Never>?
    @ObservationIgnored private var demoPumpTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastPeriodicSave = Date.distantPast
    @ObservationIgnored private var demoActive = false

    private static let hasSeenRealEventKey = "hasSeenRealEvent"

    init(
        liveSource: (any AgentEventStreaming)?,
        demoSource: (any AgentEventStreaming)?,
        persistence: StatePersistence?,
        forceDemo: Bool = false,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        self.liveSource = liveSource
        self.demoSource = demoSource
        self.persistence = persistence
        self.forceDemo = forceDemo
        self.defaults = defaults
        self.rng = SplitMix64(seed: UInt64(bitPattern: Int64(now.timeIntervalSince1970 * 1000)))

        let persisted = persistence?.load(now: now)
        self.state = persisted ?? .initial(now: now)

        let hasSeenRealEvent = defaults.bool(forKey: Self.hasSeenRealEventKey)
        self.demoActive = forceDemo || (persisted == nil && !hasSeenRealEvent && demoSource != nil)
        self.dataSourceMode = demoActive ? .demo : .idle
    }

    func start() {
        guard tickTask == nil else { return }

        if let liveSource {
            livePumpTask = Task { [weak self] in
                for await event in liveSource.events() {
                    guard let self else { break }
                    self.ingestLive(event)
                }
            }
        }
        if demoActive {
            startDemoPump()
        }

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.advance(now: Date())
                let interval: Duration = self.shouldTickFast ? .milliseconds(500) : .seconds(5)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        livePumpTask?.cancel()
        demoPumpTask?.cancel()
        saveTask?.cancel()
        bannerTask?.cancel()
        tickTask = nil
        livePumpTask = nil
        demoPumpTask = nil
        saveNow()
    }

    func apply(_ intent: SceneIntent) {
        if case .fishSelected(let id) = intent {
            selectedFishID = id
            return
        }
        let output = EcosystemEngine.apply(intent: intent, to: state, now: Date())
        commit(output)
    }

    func saveNow() {
        guard let persistence else { return }
        try? persistence.save(state.sanitizedForPersistence())
        lastPeriodicSave = Date()
    }

    func resetAquarium() {
        let now = Date()
        pendingEvents.removeAll()
        state = .initial(now: now)
        stateVersion &+= 1
        selectedFishID = nil
        onReconcile?(state)
        saveNow()
    }

    // MARK: - Event intake

    private func ingestLive(_ event: AgentEvent) {
        if demoActive && !forceDemo {
            // First real agent activity ends the first-run demo.
            endDemo()
        }
        if !defaults.bool(forKey: Self.hasSeenRealEventKey) {
            defaults.set(true, forKey: Self.hasSeenRealEventKey)
        }
        pendingEvents.append(event)
    }

    private func startDemoPump() {
        guard let demoSource, demoPumpTask == nil else { return }
        demoActive = true
        dataSourceMode = .demo
        demoPumpTask = Task { [weak self] in
            for await event in demoSource.events() {
                guard let self else { break }
                guard self.demoActive else { break }
                self.pendingEvents.append(event)
            }
        }
    }

    private func endDemo() {
        demoActive = false
        demoPumpTask?.cancel()
        demoPumpTask = nil
        pendingEvents.removeAll { $0.isDemoEvent }
        purgeDemoEntities()
    }

    private func purgeDemoEntities() {
        var events: [EcosystemEvent] = []
        for fish in state.fish where fish.id.isDemo || (fish.projectKey?.hasPrefix("demo/") ?? false) {
            events.append(.fishRemoved(fish.id))
        }
        guard !events.isEmpty || !state.sessions.isEmpty else {
            refreshMode()
            return
        }
        let removedIDs = Set(events.compactMap { event -> FishID? in
            if case .fishRemoved(let id) = event { return id }
            return nil
        })
        state.fish.removeAll { removedIDs.contains($0.id) }
        state.sessions.removeAll { removedIDs.contains($0.fishID) }
        state.food.removeAll { removedIDs.contains($0.fish) }
        state.pearls.removeAll { removedIDs.contains($0.fish) }
        stateVersion &+= 1
        onEcosystemEvents?(events)
        refreshMode()
    }

    // MARK: - Tick

    private var shouldTickFast: Bool {
        isAquariumVisible || demoActive || hasActiveAgents || !pendingEvents.isEmpty
    }

    private func advance(now: Date) {
        let drained = Array(pendingEvents.prefix(64))
        pendingEvents.removeFirst(min(64, pendingEvents.count))
        let output = EcosystemEngine.advance(state, events: drained, now: now, rng: &rng)
        commit(output)

        if now.timeIntervalSince(lastPeriodicSave) > 60 {
            saveNow()
        }
        refreshMode()
    }

    private func commit(_ output: EngineOutput) {
        let changed = output.state != state || !output.events.isEmpty
        state = output.state
        guard changed else { return }
        stateVersion &+= 1
        if !output.events.isEmpty {
            onEcosystemEvents?(output.events)
            presentBannerIfNeeded(from: output.events)
        }
        scheduleSave()
    }

    private func refreshMode() {
        let mode: DataSourceMode
        if demoActive {
            mode = .demo
        } else if hasActiveAgents || !state.sessions.isEmpty {
            mode = .live
        } else {
            mode = .idle
        }
        if mode != dataSourceMode {
            dataSourceMode = mode
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: - Banners

    private func presentBannerIfNeeded(from events: [EcosystemEvent]) {
        for event in events {
            switch event {
            case .achievementUnlocked(let achievement):
                showBanner(BannerModel(
                    title: achievement.title,
                    detail: achievement.detail,
                    systemImage: "trophy.fill"
                ))
            case .rareVisitorAppeared(let visitor):
                showBanner(BannerModel(
                    title: visitor.kind == .goldenFish ? "Golden Fish!" : "Legendary Whale!",
                    detail: "A rare visitor graces the vivarium.",
                    systemImage: "sparkles"
                ))
            default:
                continue
            }
        }
    }

    private func showBanner(_ model: BannerModel) {
        banner = model
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}

private extension AgentEvent {
    var isDemoEvent: Bool {
        sessionKey?.sessionID.hasPrefix("demo-") ?? false
    }
}
