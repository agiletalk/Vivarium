import AppKit
import OSLog
import VivariumCore
import VivariumDetect

let vivariumLog = Logger(subsystem: "com.agiletalk.Vivarium", category: "lifecycle")

/// Owns the store, settings, aquarium controller, and window presenter, and wires the store to the
/// scene. Built in `init()` so all of them exist before SwiftUI first evaluates the scene bodies.
@MainActor
final class VivariumAppDelegate: NSObject, NSApplicationDelegate {
    let store: VivariumStore
    let settings: SettingsStore
    let controller: any AquariumHosting
    let presenter = AquariumWindowPresenter()
    private let settingsWindow = SettingsWindowController()
    private var menuBar: MenuBarController?
    private var waitingNotifier: WaitingNotifier?

    private let qaOpenAquarium: Bool
    private let snapshotPath: String?
    private let verifyPopoverPath: String?
    private let verifyAquariumPath: String?

    override init() {
        let config = LaunchConfiguration.fromProcess()
        let persistence = StatePersistence(
            fileURL: config.stateFileOverride ?? StatePersistence.defaultFileURL()
        )
        // Settings are built first so the store/detection wiring can honor persisted preferences.
        let settings = SettingsStore()
        // Demo mode (setting or launch flag) shows the scripted demo instead of live detection.
        let forceDemo = config.forceDemo || settings.demoMode
        // Only build session sources for enabled providers; each follows its own settings toggle.
        var enabledProviders: Set<AgentProvider> = []
        if settings.providersClaudeEnabled { enabledProviders.insert(.claude) }
        if settings.providersCodexEnabled { enabledProviders.insert(.codex) }
        if settings.providersCopilotEnabled { enabledProviders.insert(.copilot) }
        if settings.providersOpencodeEnabled { enabledProviders.insert(.opencode) }
        if settings.providersGeminiEnabled { enabledProviders.insert(.gemini) }

        let liveSource: (any AgentEventStreaming)? = forceDemo
            ? nil
            : DetectionCoordinator.standard(enabledProviders: enabledProviders)
        let demoSource = DemoEventScript()

        self.store = VivariumStore(
            liveSource: liveSource,
            demoSource: demoSource,
            persistence: persistence,
            forceDemo: forceDemo
        )
        self.settings = settings
        self.controller = makeAquariumController(initialState: store.state)
        self.qaOpenAquarium = config.qaOpenAquarium
        self.snapshotPath = config.snapshotPath
        self.verifyPopoverPath = config.verifyPopoverPath
        self.verifyAquariumPath = config.verifyAquariumPath

        super.init()
        wireStoreToScene()
        vivariumLog.log("AppDelegate.init done")
        DebugTrace.log("AppDelegate.init done forceDemo=\(forceDemo) providers=\(enabledProviders.count) fish=\(self.store.state.fish.count)")
    }

    private func wireStoreToScene() {
        store.onEcosystemEvents = { [weak self] events in
            self?.controller.apply(events: events)
        }
        store.onReconcile = { [weak self] state in
            self?.controller.reconcile(with: state)
        }
        controller.onIntent = { [weak store] intent in
            store?.apply(intent)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar-only presence: no Dock icon, no app menu.
        NSApp.setActivationPolicy(.accessory)
        vivariumLog.log("applicationWillFinishLaunching")
        DebugTrace.log("applicationWillFinishLaunching policy=accessory")
        store.start()

        menuBar = MenuBarController(
            store: store,
            settings: settings,
            onOpenAquarium: { [weak self] in self?.openAquarium() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

        // Notify when an agent finishes its turn and is waiting for input (opt-in).
        waitingNotifier = WaitingNotifier(store: store, settings: settings)

        // Push the low-power preference into the scene and keep it in sync as the user toggles it.
        observeLowPowerMode()

        if qaOpenAquarium || snapshotPath != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                self?.openAquarium()
            }
        }

        if let snapshotPath {
            // Let the scene populate and animate, then dump a PNG and exit — no Screen
            // Recording permission needed (renders the SKScene directly).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(7))
                if let ctrl = self?.controller as? AquariumController {
                    DebugTrace.log("snapshot positions: \(ctrl.debugFishPositions())")
                }
                if let data = self?.controller.snapshotPNG() {
                    try? data.write(to: URL(fileURLWithPath: snapshotPath))
                }
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            }
        }

        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--vivarium-fish-sheet"),
           ProcessInfo.processInfo.arguments.indices.contains(i + 1) {
            let path = ProcessInfo.processInfo.arguments[i + 1]
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if let data = FishSheet.renderPNG() {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.terminate(nil)
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--vivarium-verify-settings") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let before = NSApp.windows.map { "\($0.title)|vis=\($0.isVisible)" }
                DebugTrace.log("settings: windows BEFORE = \(before)")
                self.openSettings()
                try? await Task.sleep(for: .milliseconds(900))
                let after = NSApp.windows.map { "\($0.title)|vis=\($0.isVisible)" }
                DebugTrace.log("settings: windows AFTER = \(after)")
                if let win = NSApp.windows.first(where: { $0.title == "Vivarium Settings" }),
                   let view = win.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/viv-settings.png"))
                        DebugTrace.log("settings: PNG written")
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            }
        }

        if let verifyAquariumPath {
            // Open the aquarium, select a fish so the detail panel slides in, then render the
            // window content (HUD overlays + panel) to PNG. SwiftUI chrome captures via cacheDisplay;
            // the Metal-backed SKView region may render dark, which is fine — the scene has its own
            // snapshot path (--vivarium-snapshot).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.openAquarium()
                try? await Task.sleep(for: .milliseconds(600))
                if let store = self?.store, let first = store.state.fish.first {
                    store.selectedFishID = first.id
                }
                try? await Task.sleep(for: .milliseconds(900))
                if let win = NSApp.windows.first(where: { $0.title == "Vivarium Aquarium" }),
                   let view = win.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: verifyAquariumPath))
                        DebugTrace.log("verifyAquarium: PNG written to \(verifyAquariumPath)")
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            }
        }

        if let verifyPopoverPath {
            // Programmatically open the menu bar popover and render it, proving click→popover works.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.menuBar?.showPopover()
                try? await Task.sleep(for: .milliseconds(700))
                let shown = self?.menuBar?.isPopoverShown ?? false
                DebugTrace.log("verifyPopover: isShown=\(shown)")
                if let data = self?.menuBar?.renderPopoverPNG() {
                    try? data.write(to: URL(fileURLWithPath: verifyPopoverPath))
                }
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    /// Applies `energyLowPower` to the scene and re-applies whenever the setting changes.
    private func observeLowPowerMode() {
        controller.setLowPowerMode(settings.energyLowPower)
        withObservationTracking {
            _ = settings.energyLowPower
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLowPowerMode() }
        }
    }

    func openAquarium() {
        presenter.openAquarium(controller: controller, store: store)
    }

    func openSettings() {
        settingsWindow.show(store: store, settings: settings)
    }
}
