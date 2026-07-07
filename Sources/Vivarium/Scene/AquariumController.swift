import AppKit
import Foundation
import SpriteKit
import VivariumCore

/// Concrete `AquariumHosting`: owns the `SKView` and the `AquariumScene`, forwards semantic diffs
/// into the scene, and bridges the scene's spatial intents back out through `onIntent`.
@MainActor
final class AquariumController: AquariumHosting {
    private let skView: SKView
    private let scene: AquariumScene

    var view: NSView { skView }

    var onIntent: (@MainActor (SceneIntent) -> Void)? {
        get { scene.onIntent }
        set { scene.onIntent = newValue }
    }

    init(initialState: EcosystemState) {
        let initialSize = CGSize(width: 480, height: 320)
        skView = SKView(frame: CGRect(origin: .zero, size: initialSize))
        skView.autoresizingMask = [.width, .height]
        skView.ignoresSiblingOrder = true

        scene = AquariumScene(size: initialSize)
        scene.scaleMode = .resizeFill

        #if DEBUG
        if ProcessInfo.processInfo.environment["VIVARIUM_SCENE_DEBUG"] != nil {
            skView.showsFPS = true
            skView.showsDrawCount = true
            skView.showsNodeCount = true
        }
        #endif

        // Buffered until the scene finishes `didMove` setup, then applied idempotently.
        scene.reconcile(with: initialState)
        skView.presentScene(scene)
    }

    func apply(events: [EcosystemEvent]) {
        scene.apply(events: events)
    }

    func reconcile(with state: EcosystemState) {
        scene.reconcile(with: state)
    }

    func setRenderActive(_ active: Bool) {
        scene.setRenderActive(active)
    }

    /// Renders the current scene contents straight to PNG data, bypassing screen capture
    /// (and its Screen Recording permission). Used by the `--vivarium-snapshot` QA flag.
    func snapshotPNG() -> Data? {
        guard let texture = skView.texture(from: scene),
              let cgImage = texture.cgImage() as CGImage? else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
