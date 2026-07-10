import AppKit
import SwiftUI
import Testing
@testable import Vivarium
import VivariumCore

/// Structural snapshot tests: render each SwiftUI surface headlessly with `ImageRenderer` (no
/// external snapshot library, per the zero-dependency rule) and assert it produced a sane bitmap.
/// This guards against render crashes, nil/empty output, and lost backgrounds — without the
/// brittleness of committed golden images.
@MainActor
@Suite("View rendering")
struct ViewRenderTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func render(_ view: some View, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// True when the sampled color matches within a small tolerance. `colorAt` returns the bitmap's
    /// native RGB components (already the rendered sRGB values); we compare them directly rather than
    /// reconverting color space, which would re-apply a gamma shift.
    private func approx(_ color: NSColor?, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, tol: CGFloat = 0.04) -> Bool {
        guard let c = color, c.numberOfComponents >= 3 else { return false }
        return abs(c.redComponent - r) < tol && abs(c.greenComponent - g) < tol && abs(c.blueComponent - b) < tol
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> NSColor? {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)
    }

    private func idleStore() -> VivariumStore {
        VivariumStore(
            liveSource: nil, demoSource: nil, persistence: nil,
            forceDemo: false, defaults: UserDefaults(suiteName: "viv.render.\(UUID().uuidString)")!, now: t0
        )
    }

    private func demoStore() -> VivariumStore {
        // demoSource present + no persisted state + not seen a real event → starts in demo mode.
        VivariumStore(
            liveSource: nil, demoSource: EmptySource(), persistence: nil,
            forceDemo: false, defaults: UserDefaults(suiteName: "viv.render.\(UUID().uuidString)")!, now: t0
        )
    }

    private func sampleFish() -> FishState {
        FishState(
            id: .resident(provider: .claude, projectKey: "/Users/dev/Vivarium"),
            provider: .claude,
            displayName: "Claude · Vivarium",
            projectKey: "/Users/dev/Vivarium",
            isResident: true,
            status: .coding,
            size: 1.2,
            fatigue: 0.6,
            tasksCompleted: 42,
            tasksFailed: 3,
            memory: [MemoryTrait(domain: .swift, level: 4), MemoryTrait(domain: .ui, level: 2)],
            lastActiveAt: t0,
            createdAt: t0,
            sessionCount: 5,
            gitBranch: "main",
            model: "claude-opus-4-8"
        )
    }

    // MARK: - Leaf components

    @Test("StatusPill renders to a non-empty bitmap")
    func statusPillRenders() {
        let image = try? #require(render(StatusPill(status: .coding)))
        #expect(image != nil)
        if let image {
            #expect(image.width > 0 && image.height > 0)
        }
    }

    @Test("ProgressCapsule renders at a fixed frame")
    func progressCapsuleRenders() {
        let view = ProgressCapsule(fraction: 0.5, fill: Shoal.reefGradient).frame(width: 120, height: 6)
        let image = render(view)
        #expect(image != nil)
        #expect((image?.width ?? 0) == 240) // 120pt × scale 2
    }

    // MARK: - Popover

    @Test("Menu bar popover renders 340pt wide over its opaque dark card")
    func popoverRendersOverDarkCard() throws {
        let image = try #require(render(MenuBarPopoverView(store: idleStore(), onOpenAquarium: {})))
        #expect(image.width == 680) // 340pt × scale 2
        #expect(image.height > 0)
        // A top-left pixel sits in the card padding → the opaque #2C2D32 background must have drawn.
        #expect(approx(pixel(image, x: 3, y: 3), 0.173, 0.176, 0.196))
    }

    @Test("Popover renders in demo mode without crashing")
    func popoverDemoModeRenders() {
        let image = render(MenuBarPopoverView(store: demoStore(), onOpenAquarium: {}))
        #expect(image != nil)
        #expect((image?.width ?? 0) == 680)
    }

    // MARK: - Fish detail panel

    @Test("Fish detail panel renders 300pt wide for a populated fish")
    func detailPanelRenders() throws {
        let image = try #require(render(FishDetailPanel(fish: sampleFish())))
        #expect(image.width == 600) // 300pt × scale 2
        #expect(image.height > 0)
    }
}

/// A no-op event source used only to put the store into demo mode for rendering.
private final class EmptySource: AgentEventStreaming, @unchecked Sendable {
    func events() -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
}
