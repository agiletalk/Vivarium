import AppKit
import SwiftUI
import VivariumCore

/// Owns the aquarium `NSWindow`. A `MenuBarExtra`-only app has no window scene we can suppress on
/// macOS 14, so we present AppKit-side and drive the scene's render/energy policy from window state.
@MainActor
final class AquariumWindowPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var store: VivariumStore?
    private weak var controller: (any AquariumHosting)?
    private var occlusionObserver: (any NSObjectProtocol)?

    func openAquarium(controller: any AquariumHosting, store: VivariumStore) {
        self.controller = controller
        self.store = store

        let window = window ?? makeWindow(controller: controller, store: store)
        self.window = window

        store.isAquariumVisible = true
        controller.setRenderActive(true)
        // Become a regular app while the window is open so it appears in Cmd+Tab (and the Dock) and
        // can be switched to; we drop back to `.accessory` (menu-bar-only) when it closes.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugTrace.log("openAquarium: activationPolicy=\(NSApp.activationPolicy().rawValue)")
    }

    private func makeWindow(controller: any AquariumHosting, store: VivariumStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vivarium Aquarium"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 640)
        window.delegate = self
        window.setFrameAutosaveName("VivariumAquariumWindow")
        window.contentView = NSHostingView(
            rootView: AquariumWindowContent(store: store, aquariumView: controller.view)
        )
        window.center()

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncRenderActive()
            }
        }
        return window
    }

    private func syncRenderActive() {
        guard let window, let controller else { return }
        let active = window.occlusionState.contains(.visible) && window.isVisible
        controller.setRenderActive(active)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        store?.isAquariumVisible = false
        controller?.setRenderActive(false)
        // Return to menu-bar-only presence (out of Cmd+Tab and the Dock).
        NSApp.setActivationPolicy(.accessory)
        DebugTrace.log("windowWillClose: activationPolicy=\(NSApp.activationPolicy().rawValue)")
    }
}

/// The window's SwiftUI content: the scene's AppKit view with the banner floating above it.
private struct AquariumWindowContent: View {
    let store: VivariumStore
    let aquariumView: NSView

    var body: some View {
        ZStack {
            AquariumViewRepresentable(nsView: aquariumView)
                .ignoresSafeArea()
            BannerOverlay(store: store)
        }
    }
}

/// Wraps the scene-owned `NSView` for embedding inside SwiftUI. The scene manages its own contents.
struct AquariumViewRepresentable: NSViewRepresentable {
    let nsView: NSView

    func makeNSView(context: Context) -> NSView { nsView }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
