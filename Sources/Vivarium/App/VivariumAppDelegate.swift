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

    private let qaOpenAquarium: Bool
    private let snapshotPath: String?
    private let verifyPopoverPath: String?

    override init() {
        let config = LaunchConfiguration.fromProcess()
        let persistence = StatePersistence(
            fileURL: config.stateFileOverride ?? StatePersistence.defaultFileURL()
        )
        let liveSource: (any AgentEventStreaming)? = config.forceDemo ? nil : DetectionCoordinator.standard()
        let demoSource = DemoEventScript()

        self.store = VivariumStore(
            liveSource: liveSource,
            demoSource: demoSource,
            persistence: persistence,
            forceDemo: config.forceDemo
        )
        self.settings = SettingsStore()
        self.controller = makeAquariumController(initialState: store.state)
        self.qaOpenAquarium = config.qaOpenAquarium
        self.snapshotPath = config.snapshotPath
        self.verifyPopoverPath = config.verifyPopoverPath

        super.init()
        wireStoreToScene()
        vivariumLog.log("AppDelegate.init done")
        DebugTrace.log("AppDelegate.init done forceDemo=\(config.forceDemo) fish=\(self.store.state.fish.count)")
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
            onOpenAquarium: { [weak self] in self?.openAquarium() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

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
                if let data = self?.controller.snapshotPNG() {
                    try? data.write(to: URL(fileURLWithPath: snapshotPath))
                }
                try? await Task.sleep(for: .milliseconds(300))
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

    func openAquarium() {
        presenter.openAquarium(controller: controller, store: store)
    }

    func openSettings() {
        settingsWindow.show(store: store, settings: settings)
    }
}
