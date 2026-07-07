import AppKit
import VivariumCore
import VivariumDetect

/// Owns the store, settings, aquarium controller, and window presenter, and wires the store to the
/// scene. Built in `init()` so all of them exist before SwiftUI first evaluates the scene bodies.
@MainActor
final class VivariumAppDelegate: NSObject, NSApplicationDelegate {
    let store: VivariumStore
    let settings: SettingsStore
    let controller: any AquariumHosting
    let presenter = AquariumWindowPresenter()

    private let qaOpenAquarium: Bool

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

        super.init()
        wireStoreToScene()
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
        store.start()

        if qaOpenAquarium {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                self?.openAquarium()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    func openAquarium() {
        presenter.openAquarium(controller: controller, store: store)
    }
}
