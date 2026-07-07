import Foundation

/// Swim area in scene points; y grows upward.
public struct MotionBounds: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
}

/// Per-fish steering integrator state. Pure value; the SpriteKit scene owns one per fish node.
public struct FishSteeringState: Sendable, Equatable {
    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var wanderAngle: Double
    /// +1 faces right, -1 faces left.
    public var flipSign: Double
    /// Seconds the pending opposite sign has been held (hysteresis accumulator).
    public var flipHold: Double
    public var timeUntilRetarget: Double
    public var wanderTarget: SIMD2<Double>?

    /// Starts at `position` with a random initial heading; the first `step` picks a roam waypoint.
    public init(position: SIMD2<Double>, rng: inout SplitMix64) {
        self.position = position
        let heading = rng.double(in: 0..<(2 * .pi))
        velocity = SIMD2(cos(heading), sin(heading)) * 12
        wanderAngle = rng.double(in: 0..<(2 * .pi))
        flipSign = velocity.x >= 0 ? 1 : -1
        flipHold = 0
        timeUntilRetarget = 0
        wanderTarget = nil
    }
}

/// Everything about the world a fish needs for one steering step.
public struct WorldInputs: Sendable {
    public var bounds: MotionBounds
    /// Non-nil ⇒ flee dominates and wander/seek is suppressed.
    public var sharkPosition: SIMD2<Double>?
    /// Non-nil ⇒ seek/arrive replaces wander.
    public var foodTarget: SIMD2<Double>?
    /// Other fish positions, for separation.
    public var neighbors: [SIMD2<Double>]
    /// Frame delta in seconds; the caller clamps it to ≤ 1/20.
    public var dt: Double
    /// Fatigue/night factor scaling the speed cap, 0.3...1.0.
    public var speedMultiplier: Double

    public init(
        bounds: MotionBounds,
        sharkPosition: SIMD2<Double>? = nil,
        foodTarget: SIMD2<Double>? = nil,
        neighbors: [SIMD2<Double>] = [],
        dt: Double,
        speedMultiplier: Double = 1.0
    ) {
        self.bounds = bounds
        self.sharkPosition = sharkPosition
        self.foodTarget = foodTarget
        self.neighbors = neighbors
        self.dt = dt
        self.speedMultiplier = speedMultiplier
    }
}

/// Pure Reynolds-style steering math. No SpriteKit; the scene calls `step` once per fish per frame.
public enum SteeringMath {
    static let fleeRadius: Double = 260
    static let fleeWeight: Double = 3.0
    static let separationRadius: Double = 60
    static let separationWeight: Double = 0.4
    static let wallMargin: Double = 60
    static let wallWeight: Double = 2.5
    /// Soft-spring gain pulling y back into the depth band (1/s).
    static let depthSpring: Double = 1.2
    /// Wander (or food seek) is scaled by this while a shark is active.
    static let sharkSuppression: Double = 0.2
    static let flipMinSpeed: Double = 12
    static let flipHoldDuration: Double = 0.25

    // MARK: Step

    public static func step(
        _ state: FishSteeringState,
        species: FishSpecies,
        params: SpeciesMotionParams,
        world: WorldInputs,
        rng: inout SplitMix64
    ) -> FishSteeringState {
        let dt = world.dt
        guard dt > 0 else { return state }
        var next = state

        // Roam waypoint retargeting (rng consumption order is fixed for determinism).
        next.timeUntilRetarget -= dt
        if next.timeUntilRetarget <= 0 || next.wanderTarget == nil {
            next.wanderTarget = roamTarget(in: world.bounds, params: params, rng: &rng)
            let interval = params.retargetInterval
            next.timeUntilRetarget = interval.lowerBound < interval.upperBound
                ? rng.double(in: interval.lowerBound..<interval.upperBound)
                : interval.lowerBound
        }

        // Wander-angle drift.
        let jitterSpan = params.wanderJitter * dt
        next.wanderAngle += rng.double(in: -jitterSpan..<jitterSpan)

        // Desired velocity: wander (or seek/arrive), suppressed under threat, plus flee,
        // depth-band spring, separation, and wall avoidance.
        var desired: SIMD2<Double>
        if let food = world.foodTarget {
            desired = seekArriveForce(position: next.position, target: food, params: params)
        } else {
            desired = wanderForce(
                position: next.position,
                velocity: next.velocity,
                wanderAngle: next.wanderAngle,
                wanderTarget: next.wanderTarget,
                params: params
            )
        }
        if let shark = world.sharkPosition {
            desired *= sharkSuppression
            desired += fleeForce(position: next.position, shark: shark, params: params)
        }
        desired += depthBandForce(position: next.position, bounds: world.bounds, params: params)
        desired += separationForce(position: next.position, neighbors: world.neighbors, params: params)
        desired += wallAvoidForce(position: next.position, bounds: world.bounds, params: params)

        // Integrate.
        let steering = limited(desired - next.velocity, to: params.maxForce)
        next.velocity = limited(next.velocity + steering * dt, to: params.maxSpeed * world.speedMultiplier)
        next.position += next.velocity * dt

        // Safety: never leave the swim area.
        next.position.x = min(max(next.position.x, world.bounds.minX), world.bounds.maxX)
        next.position.y = min(max(next.position.y, world.bounds.minY), world.bounds.maxY)

        (next.flipSign, next.flipHold) = updatedFlip(
            sign: next.flipSign,
            hold: next.flipHold,
            vx: next.velocity.x,
            dt: dt
        )
        return next
    }

    // MARK: Component forces (desired-velocity space, pt/s)

    /// Classic wander circle projected ahead of the heading, blended with a slow seek toward the
    /// current roam waypoint so fish cross the tank instead of dithering in place.
    public static func wanderForce(
        position: SIMD2<Double>,
        velocity: SIMD2<Double>,
        wanderAngle: Double,
        wanderTarget: SIMD2<Double>?,
        params: SpeciesMotionParams
    ) -> SIMD2<Double> {
        let heading = normalized(velocity) ?? SIMD2(1, 0)
        let circleCenter = heading * (params.wanderRadius * 1.2)
        let onCircle = SIMD2(cos(wanderAngle), sin(wanderAngle)) * params.wanderRadius
        var direction = normalized(circleCenter + onCircle) ?? heading
        if let target = wanderTarget, let seekDirection = normalized(target - position) {
            direction = normalized(direction * 0.45 + seekDirection * 0.55) ?? direction
        }
        return direction * params.cruiseSpeed
    }

    /// Seek at max speed, decelerating linearly inside `arriveSlowRadius`.
    public static func seekArriveForce(
        position: SIMD2<Double>,
        target: SIMD2<Double>,
        params: SpeciesMotionParams
    ) -> SIMD2<Double> {
        let toTarget = target - position
        guard let direction = normalized(toTarget) else { return .zero }
        let distance = length(toTarget)
        let speed = params.maxSpeed * min(1, distance / max(params.arriveSlowRadius, 1e-9))
        return direction * speed
    }

    /// Radial push away from the shark with quadratic falloff over `fleeRadius`.
    public static func fleeForce(
        position: SIMD2<Double>,
        shark: SIMD2<Double>,
        params: SpeciesMotionParams
    ) -> SIMD2<Double> {
        let away = position - shark
        let distance = length(away)
        guard distance < fleeRadius else { return .zero }
        let falloff = 1 - distance / fleeRadius
        let direction = normalized(away) ?? SIMD2(1, 0)
        return direction * (params.maxSpeed * params.fleeSpeedMultiplier * fleeWeight * falloff * falloff)
    }

    /// Soft spring pulling y back toward the species depth band; zero inside the band.
    public static func depthBandForce(
        position: SIMD2<Double>,
        bounds: MotionBounds,
        params: SpeciesMotionParams
    ) -> SIMD2<Double> {
        let low = bounds.minY + params.depthBand.lowerBound * bounds.height
        let high = bounds.minY + params.depthBand.upperBound * bounds.height
        let delta: Double
        if position.y < low {
            delta = low - position.y
        } else if position.y > high {
            delta = high - position.y
        } else {
            return .zero
        }
        let pull = min(max(delta * depthSpring, -params.cruiseSpeed), params.cruiseSpeed)
        return SIMD2(0, pull)
    }

    /// Push away from neighbors closer than `separationRadius`, linear falloff.
    public static func separationForce(
        position: SIMD2<Double>,
        neighbors: [SIMD2<Double>],
        params: SpeciesMotionParams
    ) -> SIMD2<Double> {
        var push = SIMD2<Double>.zero
        for neighbor in neighbors {
            let away = position - neighbor
            let distance = length(away)
            guard distance < separationRadius else { continue }
            if let direction = normalized(away) {
                push += direction * (1 - distance / separationRadius)
            } else {
                push += SIMD2(1, 0)
            }
        }
        return push * (params.cruiseSpeed * separationWeight)
    }

    /// Strong quadratic push off each wall inside a soft margin.
    public static func wallAvoidForce(
        position: SIMD2<Double>,
        bounds: MotionBounds,
        params: SpeciesMotionParams
    ) -> SIMD2<Double> {
        func penetration(_ distance: Double) -> Double {
            let t = max(0, 1 - max(distance, 0) / wallMargin)
            return t * t
        }
        var force = SIMD2<Double>.zero
        force.x += penetration(position.x - bounds.minX)
        force.x -= penetration(bounds.maxX - position.x)
        force.y += penetration(position.y - bounds.minY)
        force.y -= penetration(bounds.maxY - position.y)
        return force * (params.maxSpeed * wallWeight)
    }

    /// Vertical bob offset the scene adds on top of the steered position. Fatigue halves it at 1.0.
    public static func bobOffset(time: Double, params: SpeciesMotionParams, fatigue: Double, phase: Double) -> Double {
        let clampedFatigue = min(max(fatigue, 0), 1)
        let amplitude = params.bobAmplitude * (1 - 0.5 * clampedFatigue)
        return amplitude * sin(2 * .pi * params.bobFrequency * time + phase)
    }

    /// Flip hysteresis: the opposite sign must exceed `flipMinSpeed` continuously for
    /// `flipHoldDuration` before the facing flips. Returns the new (sign, hold accumulator).
    public static func updatedFlip(sign: Double, hold: Double, vx: Double, dt: Double) -> (sign: Double, hold: Double) {
        let candidate: Double? = abs(vx) > flipMinSpeed ? (vx > 0 ? 1.0 : -1.0) : nil
        guard let candidate, candidate != sign else { return (sign, 0) }
        let newHold = hold + dt
        return newHold >= flipHoldDuration ? (candidate, 0) : (sign, newHold)
    }

    // MARK: Helpers

    private static func roamTarget(
        in bounds: MotionBounds,
        params: SpeciesMotionParams,
        rng: inout SplitMix64
    ) -> SIMD2<Double> {
        let inset = min(wallMargin, bounds.width * 0.25)
        let xLow = bounds.minX + inset
        let xHigh = bounds.maxX - inset
        let x = xLow < xHigh ? rng.double(in: xLow..<xHigh) : bounds.minX + bounds.width * 0.5
        let yLow = bounds.minY + params.depthBand.lowerBound * bounds.height
        let yHigh = bounds.minY + params.depthBand.upperBound * bounds.height
        let y = yLow < yHigh ? rng.double(in: yLow..<yHigh) : yLow
        return SIMD2(x, y)
    }

    private static func length(_ v: SIMD2<Double>) -> Double {
        (v * v).sum().squareRoot()
    }

    private static func normalized(_ v: SIMD2<Double>) -> SIMD2<Double>? {
        let len = length(v)
        guard len > 1e-9 else { return nil }
        return v / len
    }

    private static func limited(_ v: SIMD2<Double>, to maxLength: Double) -> SIMD2<Double> {
        guard maxLength > 0 else { return .zero }
        let len = length(v)
        guard len > maxLength else { return v }
        return v * (maxLength / len)
    }
}
