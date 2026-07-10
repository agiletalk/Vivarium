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

    /// Low-power mode: caps the render frame rate (30fps instead of 60) to save battery.
    func setLowPowerMode(_ on: Bool)

    /// Aquarium HUD test controls (scene-local, so they never mutate engine-owned state):
    /// preview a lighting phase (`nil` returns to automatic wall-clock lighting via `autoPhase`),
    /// and show/hide a test-failure shark.
    func setPhaseOverride(_ phase: AmbientPhase?, autoPhase: AmbientPhase)
    func setManualShark(_ on: Bool)

    /// Reports spatial intents (`.foodEaten`, `.fishSelected`) up to the store.
    var onIntent: (@MainActor (SceneIntent) -> Void)? { get set }

    /// Renders the current scene to PNG data without screen capture (QA snapshot).
    func snapshotPNG() -> Data?
}

/// Builds the concrete SpriteKit controller. Implemented in the Scene module.
@MainActor
func makeAquariumController(initialState: EcosystemState) -> AquariumHosting {
    AquariumController(initialState: initialState)
}
