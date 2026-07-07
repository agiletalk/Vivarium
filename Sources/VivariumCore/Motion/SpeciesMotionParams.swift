import Foundation

/// Per-species movement tuning. Units: points, seconds, radians.
public struct SpeciesMotionParams: Sendable {
    /// Preferred swim speed (pt/s).
    public var cruiseSpeed: Double
    /// Hard speed cap before the world speed multiplier (pt/s).
    public var maxSpeed: Double
    /// Steering acceleration cap (pt/s²).
    public var maxForce: Double
    /// Wander-circle radius (pt).
    public var wanderRadius: Double
    /// Wander-angle drift rate (rad/s).
    public var wanderJitter: Double
    /// Seconds between roam-waypoint retargets (rng-driven).
    public var retargetInterval: ClosedRange<Double>
    /// Preferred vertical band as a fraction of bounds height; 0 = bottom, 1 = top.
    public var depthBand: ClosedRange<Double>
    /// Vertical bob amplitude (pt).
    public var bobAmplitude: Double
    /// Vertical bob frequency (Hz).
    public var bobFrequency: Double
    /// Radius around a food target inside which arrival deceleration begins (pt).
    public var arriveSlowRadius: Double
    /// Scales the flee desired velocity when a shark is active.
    public var fleeSpeedMultiplier: Double

    public init(
        cruiseSpeed: Double,
        maxSpeed: Double,
        maxForce: Double,
        wanderRadius: Double,
        wanderJitter: Double,
        retargetInterval: ClosedRange<Double>,
        depthBand: ClosedRange<Double>,
        bobAmplitude: Double,
        bobFrequency: Double,
        arriveSlowRadius: Double,
        fleeSpeedMultiplier: Double
    ) {
        self.cruiseSpeed = cruiseSpeed
        self.maxSpeed = maxSpeed
        self.maxForce = maxForce
        self.wanderRadius = wanderRadius
        self.wanderJitter = wanderJitter
        self.retargetInterval = retargetInterval
        self.depthBand = depthBand
        self.bobAmplitude = bobAmplitude
        self.bobFrequency = bobFrequency
        self.arriveSlowRadius = arriveSlowRadius
        self.fleeSpeedMultiplier = fleeSpeedMultiplier
    }

    public static func params(for species: FishSpecies) -> SpeciesMotionParams {
        switch species {
        case .whale:
            SpeciesMotionParams(
                cruiseSpeed: 34, maxSpeed: 55, maxForce: 40,
                wanderRadius: 90, wanderJitter: 0.10,
                retargetInterval: 12...20, depthBand: 0.45...0.75,
                bobAmplitude: 6, bobFrequency: 0.22,
                arriveSlowRadius: 90, fleeSpeedMultiplier: 1.4
            )
        case .dolphin:
            SpeciesMotionParams(
                cruiseSpeed: 120, maxSpeed: 210, maxForce: 260,
                wanderRadius: 140, wanderJitter: 0.38,
                retargetInterval: 3...6, depthBand: 0.25...0.85,
                bobAmplitude: 3, bobFrequency: 0.5,
                arriveSlowRadius: 60, fleeSpeedMultiplier: 1.75
            )
        case .octopus:
            SpeciesMotionParams(
                cruiseSpeed: 26, maxSpeed: 170, maxForce: 420,
                wanderRadius: 40, wanderJitter: 0.14,
                retargetInterval: 8...14, depthBand: 0.12...0.35,
                bobAmplitude: 2, bobFrequency: 0.3,
                arriveSlowRadius: 30, fleeSpeedMultiplier: 1.6
            )
        case .jellyfish:
            SpeciesMotionParams(
                cruiseSpeed: 18, maxSpeed: 40, maxForce: 30,
                wanderRadius: 60, wanderJitter: 0.06,
                retargetInterval: 4...8, depthBand: 0.35...0.85,
                bobAmplitude: 8, bobFrequency: 0.45,
                arriveSlowRadius: 80, fleeSpeedMultiplier: 1.2
            )
        case .pufferfish:
            SpeciesMotionParams(
                cruiseSpeed: 55, maxSpeed: 95, maxForce: 150,
                wanderRadius: 70, wanderJitter: 0.24,
                retargetInterval: 5...9, depthBand: 0.30...0.60,
                bobAmplitude: 4, bobFrequency: 0.45,
                arriveSlowRadius: 60, fleeSpeedMultiplier: 1.3
            )
        }
    }
}
