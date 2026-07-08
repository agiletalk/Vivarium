import AppKit
import SwiftUI

/// Presents `SettingsView` in an AppKit-managed window.
///
/// A `.accessory` (menu-bar-only) app has no main menu, so SwiftUI's `showSettingsWindow:` action
/// has no responder to reach and silently does nothing. Owning the window here — mirroring
/// `AquariumWindowPresenter` — makes the popover's "Settings…" button reliable.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(store: VivariumStore, settings: SettingsStore) {
        let window = window ?? makeWindow(store: store, settings: settings)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugTrace.log("SettingsWindow shown visible=\(window.isVisible)")
    }

    private func makeWindow(store: VivariumStore, settings: SettingsStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vivarium Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SettingsView(store: store, settings: settings)
                .frame(width: 480, height: 420)
        )
        window.center()
        return window
    }
}
