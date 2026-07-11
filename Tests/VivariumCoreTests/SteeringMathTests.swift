import Foundation
import Testing
@testable import VivariumCore

@Suite("SteeringMath")
struct SteeringMathTests {
    static let bounds = MotionBounds(minX: 0, minY: 0, maxX: 1200, maxY: 740)
    static let dt = 1.0 / 60.0

    private func speed(_ v: SIMD2<Double>) -> Double {
        (v * v).sum().squareRoot()
    }

    private func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        speed(a - b)
    }

    @Test("10k steps stay in bounds and under the speed cap", arguments: FishSpecies.allCases, [1.0, 0.5])
    func boundsAndSpeedCap(species: FishSpecies, multiplier: Double) {
        let params = SpeciesMotionParams.params(for: species)
        var rng = SplitMix64(seed: 7)
        var state = FishSteeringState(position: SIMD2(600, 370), rng: &rng)
        let world = WorldInputs(bounds: Self.bounds, dt: Self.dt, speedMultiplier: multiplier)
        let cap = params.maxSpeed * multiplier + 1e-6

        var boundsViolations = 0
        var speedViolations = 0
        for _ in 0..<10_000 {
            state = SteeringMath.step(state, species: species, params: params, world: world, rng: &rng)
            let p = state.position
            if p.x < Self.bounds.minX || p.x > Self.bounds.maxX || p.y < Self.bounds.minY || p.y > Self.bounds.maxY {
                boundsViolations += 1
            }
            if speed(state.velocity) > cap {
                speedViolations += 1
            }
        }
        #expect(boundsViolations == 0)
        #expect(speedViolations == 0)
    }

    @Test("Arrive decelerates monotonically inside the slow radius")
    func arriveDecelerates() {
        let params = SpeciesMotionParams.params(for: .whale)
        var rng = SplitMix64(seed: 3)
        var state = FishSteeringState(position: SIMD2(400, 370), rng: &rng)
        state.velocity = SIMD2(params.maxSpeed, 0)
        let food = SIMD2<Double>(500, 370)
        let world = WorldInputs(bounds: Self.bounds, foodTarget: food, dt: Self.dt)

        var samples: [Double] = []
        for stepIndex in 1...600 {
            state = SteeringMath.step(state, species: .whale, params: params, world: world, rng: &rng)
            let d = distance(food, state.position)
            if d <= 4 { break }
            if d < params.arriveSlowRadius, stepIndex.isMultiple(of: 10) {
                samples.append(speed(state.velocity))
            }
        }
        #expect(samples.count >= 3)
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            #expect(later <= earlier + 0.01)
        }
    }

    @Test("Flee gains an away-from-shark velocity component within 1s")
    func fleeAway() {
        let params = SpeciesMotionParams.params(for: .dolphin)
        var rng = SplitMix64(seed: 11)
        var state = FishSteeringState(position: SIMD2(600, 370), rng: &rng)
        state.velocity = SIMD2(-40, 0) // start swimming toward the shark
        let shark = SIMD2<Double>(500, 370)
        let world = WorldInputs(bounds: Self.bounds, sharkPosition: shark, dt: Self.dt)

        for _ in 0..<60 {
            state = SteeringMath.step(state, species: .dolphin, params: params, world: world, rng: &rng)
        }
        let away = state.position - shark
        let awayLength = speed(away)
        #expect(awayLength > 0)
        let component = ((state.velocity * (away / awayLength))).sum()
        #expect(component > 0)
    }

    @Test("Oscillating ±8 pt/s vx never flips")
    func flipIgnoresSmallOscillation() {
        var sign = 1.0
        var hold = 0.0
        for i in 0..<600 {
            let vx = i.isMultiple(of: 2) ? 8.0 : -8.0
            (sign, hold) = SteeringMath.updatedFlip(sign: sign, hold: hold, vx: vx, dt: Self.dt)
            #expect(sign == 1.0)
        }
    }

    @Test("Sustained +50 pt/s vx flips exactly once within 0.5s")
    func flipOnSustainedReversal() {
        var sign = -1.0
        var hold = 0.0
        var flips = 0
        var flipTime = Double.infinity
        for i in 1...120 {
            let previous = sign
            (sign, hold) = SteeringMath.updatedFlip(sign: sign, hold: hold, vx: 50, dt: Self.dt)
            if sign != previous {
                flips += 1
                flipTime = Double(i) * Self.dt
            }
        }
        #expect(flips == 1)
        #expect(sign == 1.0)
        #expect(flipTime <= 0.5)
    }

    @Test("An ambient current advects the fish by current*dt on top of steering")
    func currentAdvects() {
        let params = SpeciesMotionParams.params(for: .whale)
        func run(current: SIMD2<Double>) -> SIMD2<Double> {
            var rng = SplitMix64(seed: 42)
            var state = FishSteeringState(position: SIMD2(600, 370), rng: &rng)
            let world = WorldInputs(bounds: Self.bounds, dt: Self.dt, current: current)
            state = SteeringMath.step(state, species: .whale, params: params, world: world, rng: &rng)
            return state.position
        }
        // Same seed → identical steering; the only difference is the advection term.
        let delta = run(current: SIMD2(60, 0)) - run(current: .zero)
        #expect(abs(delta.x - 60 * Self.dt) < 1e-9)
        #expect(abs(delta.y) < 1e-9)
    }

    @Test("Same seed produces an identical 1000-step trajectory")
    func determinism() {
        func run() -> [FishSteeringState] {
            let params = SpeciesMotionParams.params(for: .pufferfish)
            var rng = SplitMix64(seed: 99)
            var state = FishSteeringState(position: SIMD2(300, 200), rng: &rng)
            let world = WorldInputs(
                bounds: Self.bounds,
                sharkPosition: SIMD2(900, 300),
                neighbors: [SIMD2(320, 210), SIMD2(280, 195)],
                dt: Self.dt
            )
            var trajectory: [FishSteeringState] = []
            trajectory.reserveCapacity(1000)
            for _ in 0..<1000 {
                state = SteeringMath.step(state, species: .pufferfish, params: params, world: world, rng: &rng)
                trajectory.append(state)
            }
            return trajectory
        }
        #expect(run() == run())
    }
}
