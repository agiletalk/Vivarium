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
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vivarium Aquarium"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.delegate = self
        window.setFrameAutosaveName("VivariumAquariumWindow")
        window.contentView = NSHostingView(
            rootView: AquariumWindowContent(store: store, controller: controller)
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

/// The window's SwiftUI content: the scene view, the floating HUD, the fish detail panel, banner.
private struct AquariumWindowContent: View {
    let store: VivariumStore
    let controller: any AquariumHosting

    private var selectedFish: FishState? {
        store.selectedFishID.flatMap { store.state.fish(withID: $0) }
    }

    var body: some View {
        ZStack {
            AquariumViewRepresentable(nsView: controller.view)
                .ignoresSafeArea()

            AquariumHUD(store: store, controller: controller)

            if let fish = selectedFish {
                HStack {
                    Spacer(minLength: 0)
                    FishDetailPanel(fish: fish) { store.selectedFishID = nil }
                        .padding(14)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            BannerOverlay(store: store)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.selectedFishID)
    }
}

// MARK: - HUD

/// The floating aquarium HUD: agent count + reef ring (top-left), activity log (top-right),
/// click hint (bottom-left), and the phase/feed/shark test controls (bottom-right).
private struct AquariumHUD: View {
    let store: VivariumStore
    let controller: any AquariumHosting
    /// nil = automatic (wall-clock) lighting; non-nil = a manual phase preview.
    @State private var phaseOverride: AmbientPhase?
    @State private var sharkOn = false

    private var displayPhase: AmbientPhase { phaseOverride ?? store.state.ambient.phase }

    var body: some View {
        ZStack {
            // Top-left: agent count + reef progress ring.
            VStack { HStack(spacing: 8) { agentCount; reefRing; Spacer(minLength: 0) }; Spacer(minLength: 0) }
                .allowsHitTesting(false)

            // Top-right: fading activity log.
            VStack { HStack { Spacer(minLength: 0); activityLog }; Spacer(minLength: 0) }
                .allowsHitTesting(false)

            // Bottom-left: click hint.
            VStack { Spacer(minLength: 0); HStack { hint; Spacer(minLength: 0) } }
                .allowsHitTesting(false)

            // Bottom-right: test controls.
            VStack { Spacer(minLength: 0); HStack { Spacer(minLength: 0); controls } }
        }
        .padding(14)
        .environment(\.colorScheme, .dark)
    }

    private var agentCount: some View {
        HStack(spacing: 6) {
            Circle().fill(Shoal.active).frame(width: 6, height: 6)
            Text("\(store.activeFishCount) agents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .glassChip()
    }

    private var reefRing: some View {
        let stage = store.state.reefStage
        let completed = store.state.totalTasksCompleted
        let next = stage.next
        let fraction: Double = next.map { min(1, Double(completed) / Double(max(1, $0.threshold))) } ?? 1
        return HStack(spacing: 7) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Shoal.reefAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(stage.displayName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(next.map { "\(completed)/\($0.threshold) tasks" } ?? "\(completed) tasks")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .glassChip()
    }

    private var activityLog: some View {
        let lines = store.state.eventLog.sorted { $0.id > $1.id }.prefix(4)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Shoal.reefAccent)
                        .frame(width: 4, height: 4)
                    Text(line.message)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .glassChip(cornerRadius: 7, hPad: 9, vPad: 4)
                .opacity(1 - Double(index) * 0.24)
            }
        }
        .frame(width: 240, alignment: .trailing)
    }

    private var hint: some View {
        Text("Click a fish to open its details →")
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.6))
            .glassChip(cornerRadius: 7, hPad: 10, vPad: 5)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            hudButton(displayPhase.emoji, help: "Toggle time of day") {
                let next = nextPhaseOverride(phaseOverride)
                phaseOverride = next
                controller.setPhaseOverride(next, autoPhase: store.state.ambient.phase)
            }
            hudButton("🍔", help: "Feed") { store.feedAll() }
            hudButton("⚔️", help: "Test failure (shark)", active: sharkOn) {
                sharkOn.toggle()
                controller.setManualShark(sharkOn)
            }
        }
    }

    /// Cycle: auto (nil) → dawn → day → evening → night → auto. Auto resumes wall-clock lighting.
    private func nextPhaseOverride(_ current: AmbientPhase?) -> AmbientPhase? {
        switch current {
        case .none: .dawn
        case .dawn: .day
        case .day: .evening
        case .evening: .night
        case .night: .none
        }
    }

    private func hudButton(_ glyph: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .background(
                    active
                        ? Color(.sRGB, red: 0.47, green: 0.12, blue: 0.12, opacity: 0.7)
                        : Color(.sRGB, red: 0.039, green: 0.078, blue: 0.149, opacity: 0.55),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private extension View {
    /// The Shoal glass chip: dark translucent fill with a hairline light border.
    func glassChip(cornerRadius: CGFloat = 9, hPad: CGFloat = 11, vPad: CGFloat = 6) -> some View {
        self
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(
                Color(.sRGB, red: 0.039, green: 0.078, blue: 0.149, opacity: 0.55),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }
}

/// Wraps the scene-owned `NSView` for embedding inside SwiftUI. The scene manages its own contents.
struct AquariumViewRepresentable: NSViewRepresentable {
    let nsView: NSView

    func makeNSView(context: Context) -> NSView { nsView }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
