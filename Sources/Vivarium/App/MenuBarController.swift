import AppKit
import Observation
import SwiftUI
import VivariumCore

/// Classic `NSStatusItem` + `NSPopover` menu bar presence.
///
/// We manage the status item in AppKit rather than via SwiftUI's `MenuBarExtra` because the
/// `.window` popover style has proven unreliable on recent macOS betas (the icon renders but the
/// click sometimes fails to present the popover). Owning the item directly gives deterministic
/// click→toggle behavior and lets QA drive it programmatically.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: VivariumStore
    private let onOpenAquarium: () -> Void
    private let onOpenSettings: () -> Void

    init(store: VivariumStore, onOpenAquarium: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.onOpenAquarium = onOpenAquarium
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        configurePopover()
        observeActivity()
        DebugTrace.log("MenuBarController installed status item")
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = icon(active: store.hasActiveAgents)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "Vivarium"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 326, height: 420)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                store: store,
                onOpenAquarium: { [weak self] in
                    self?.closePopover()
                    self?.onOpenAquarium()
                },
                onOpenSettings: { [weak self] in
                    self?.closePopover()
                    self?.onOpenSettings()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    private func icon(active: Bool) -> NSImage? {
        let name = active ? "fish.fill" : "fish"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Vivarium")
        image?.isTemplate = true
        return image
    }

    /// Reactively refreshes the icon (and count) when the store's activity changes.
    private func observeActivity() {
        let active = store.hasActiveAgents
        let count = store.activeFishCount
        withObservationTracking {
            _ = store.hasActiveAgents
            _ = store.activeFishCount
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshButton()
                self?.observeActivity()
            }
        }
        if let button = statusItem.button {
            button.image = icon(active: active)
            button.title = count > 1 ? " \(count)" : ""
        }
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        button.image = icon(active: store.hasActiveAgents)
        let count = store.activeFishCount
        button.title = count > 1 ? " \(count)" : ""
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        DebugTrace.log("MenuBarController showPopover isShown=\(popover.isShown)")
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    /// Whether the popover is currently visible (used by QA verification).
    var isPopoverShown: Bool { popover.isShown }

    /// Renders the live popover content to PNG (QA verification of click→popover).
    func renderPopoverPNG() -> Data? {
        guard let view = popover.contentViewController?.view else { return nil }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
