import AppKit
import VivariumCore

/// The contract between the app shell and the SpriteKit aquarium.
///
/// The store owns semantic truth (who exists, status, size, fatigue, memory) and pushes diff
/// `EcosystemEvent`s; the scene owns continuous motion and rendering. The scene reports spatial
/// facts (eating, selection) back through `onIntent`.
@MainActor
protocol AquariumHosting: AnyObject {
    /// The AppKit view embedded by the window's `NSViewRepresentable`.
    var view: NSView { get }

    /// Apply a batch of semantic diffs (fish added/removed, status, food, pearls, shark, …).
    func apply(events: [EcosystemEvent])

    /// Idempotently reconcile the full world (on attach, after wake, or as a periodic self-heal).
    func reconcile(with state: EcosystemState)

    /// Drives the energy policy: `false` pauses the scene entirely (window closed/occluded).
    func setRenderActive(_ active: Bool)

    /// Reports spatial intents (`.foodEaten`, `.fishSelected`) up to the store.
    var onIntent: (@MainActor (SceneIntent) -> Void)? { get set }
}

/// Builds the concrete SpriteKit controller. Implemented in the Scene module.
@MainActor
func makeAquariumController(initialState: EcosystemState) -> AquariumHosting {
    AquariumController(initialState: initialState)
}
