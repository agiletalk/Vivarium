import Foundation

/// Diff events emitted by the engine for the SpriteKit scene (and banners).
/// The scene consumes these instead of diffing full snapshots at 60 fps.
public enum EcosystemEvent: Sendable, Equatable {
    case fishAdded(FishState)
    case fishRemoved(FishID)
    case fishStatusChanged(FishID, AgentStatus)
    case fishThought(FishID, String)
    case fishGrew(FishID, newSize: Double)
    case fishFatigueChanged(FishID, Double)
    case fishMemoryChanged(FishID, [MemoryTrait])
    case fishLegendaryChanged(FishID, Bool)
    case foodDropped(FoodPellet)
    case foodMissed(id: Int)
    case pearlSpawned(Pearl)
    case pearlPhaseChanged(id: Int, phase: Pearl.Phase)
    case sharkAppeared(label: String, severity: Double)
    case sharkLeft
    case reefStageChanged(ReefStage)
    case ambientChanged(AmbientState)
    case rareVisitorAppeared(RareVisitor)
    case rareVisitorLeft
    case achievementUnlocked(Achievement)
}

/// Spatial facts only the scene can know, reported back to the store.
public enum SceneIntent: Sendable, Equatable {
    /// The fish's mouth reached the pellet — the scene detects proximity, the engine applies growth.
    case foodEaten(id: Int, by: FishID)
    case fishSelected(FishID?)
}
