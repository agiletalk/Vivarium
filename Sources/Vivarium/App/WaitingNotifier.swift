import AppKit
import Observation
import UserNotifications
import VivariumCore

/// Posts a local notification when an agent finishes its turn and is now blocked on your input
/// (a fish transitions into `.waiting`). Edge-triggered per fish, gated on the `notifyWhenWaiting`
/// preference, and suppressed while you are already watching the tank or in demo mode.
///
/// All `UNUserNotificationCenter` access is guarded on running as a real `.app` bundle — calling it
/// from a bare SwiftPM binary traps, so tests and `swift run` never touch it.
@MainActor
final class WaitingNotifier {
    private let store: VivariumStore
    private let settings: SettingsStore
    /// Fish currently in the waiting state; diffed each change to find new entrants.
    private var waiting: Set<FishID>
    /// Per-fish debounce timers: a fish must stay waiting for `notifyDelay` before we alert.
    private var pending: [FishID: Task<Void, Never>] = [:]
    private var requestedAuthorization = false

    /// The engine flips a fish to `.waiting` a few seconds after *every* completed turn, so a busy
    /// agent blips through `.waiting` between tool turns. Only alert once it has stayed waiting this
    /// long without you re-engaging — i.e. it's genuinely your turn and you've stepped away.
    private let notifyDelay: Duration = .seconds(15)

    init(store: VivariumStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        // Seed with whoever is already waiting so a relaunch doesn't fire for pre-existing waits.
        self.waiting = Self.waitingIDs(in: store.state)
        if settings.notifyWhenWaiting { ensureAuthorization() }
        observe()
    }

    // MARK: - Pure helpers (unit-tested)

    static func waitingIDs(in state: EcosystemState) -> Set<FishID> {
        Set(state.fish.lazy.filter { $0.status == .waiting }.map(\.id))
    }

    /// Fish that entered the waiting set since the last snapshot.
    static func newlyWaiting(previous: Set<FishID>, current: Set<FishID>) -> Set<FishID> {
        current.subtracting(previous)
    }

    // MARK: - Observation

    private func observe() {
        withObservationTracking {
            _ = store.stateVersion
            _ = settings.notifyWhenWaiting
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.evaluate()
                self?.observe()
            }
        }
    }

    private func evaluate() {
        let current = Self.waitingIDs(in: store.state)

        guard settings.notifyWhenWaiting else {
            pending.values.forEach { $0.cancel() }
            pending.removeAll()
            // Forget prior waiters so enabling the feature can alert for whoever is waiting then.
            waiting = []
            return
        }
        defer { waiting = current }
        ensureAuthorization()

        // A fish that resumed work cancels its pending alert and re-arms for a future wait episode.
        for id in waiting.subtracting(current) {
            pending[id]?.cancel()
            pending[id] = nil
        }
        // Arm a debounce timer for each newly-waiting fish; `fire` re-checks the gates when it elapses.
        for id in Self.newlyWaiting(previous: waiting, current: current) where pending[id] == nil {
            arm(id)
        }
    }

    private func arm(_ id: FishID) {
        let delay = notifyDelay
        pending[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fire(id)
        }
    }

    /// Fires after the debounce. Alerts only if the fish is genuinely still waiting for you; a
    /// permission-prompt wait is indistinguishable from a slow autonomous tool, so it's excluded.
    /// If a transient gate (tank open / demo) blocks the alert, re-arm rather than drop the wait.
    private func fire(_ id: FishID) {
        pending[id] = nil
        guard settings.notifyWhenWaiting else { return }
        guard let fish = store.state.fish.first(where: { $0.id == id }),
              fish.status == .waiting,
              fish.waitKind != .permissionPrompt else { return }
        guard !store.isAquariumVisible, store.dataSourceMode != .demo else { arm(id); return }
        notify(for: fish)
    }

    // MARK: - Notifications

    private func ensureAuthorization() {
        guard settings.isAppBundle, !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(for fish: FishState) {
        guard settings.isAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(fish.provider.displayName) is waiting for you"
        let project = fish.projectTitle
        content.body = project == fish.provider.displayName
            ? "The agent finished its turn — your input is needed."
            : "\(project) — the agent finished its turn."
        content.sound = .default
        // Key by fish id so a re-entered wait replaces the prior alert instead of stacking.
        let request = UNNotificationRequest(
            identifier: "vivarium.waiting.\(fish.id.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
