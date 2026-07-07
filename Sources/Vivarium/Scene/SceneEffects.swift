import Foundation
import SpriteKit
import VivariumCore

/// Programmatic particle/effect builders. Every emitter draws from a cached soft-dot texture and
/// stays well under the scene's live-particle budget.
@MainActor
enum SceneEffects {
    /// A single rising column of ambient bubbles.
    static func bubbleColumn(texture: SKTexture) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = texture
        emitter.particleBirthRate = 1.4
        emitter.particleLifetime = 7
        emitter.particleLifetimeRange = 4
        emitter.emissionAngle = .pi / 2
        emitter.emissionAngleRange = 0.3
        emitter.particleSpeed = 24
        emitter.particleSpeedRange = 10
        emitter.particleAlpha = 0.32
        emitter.particleAlphaRange = 0.12
        emitter.particleAlphaSpeed = -0.03
        emitter.particleScale = 0.14
        emitter.particleScaleRange = 0.08
        emitter.particleScaleSpeed = 0.02
        emitter.particleColor = NSColor(white: 1, alpha: 1)
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .add
        emitter.particlePositionRange = CGVector(dx: 16, dy: 0)
        return emitter
    }

    /// A slow drifting, low-alpha plankton field for night ambience.
    static func plankton(texture: SKTexture, width: CGFloat, height: CGFloat) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = texture
        emitter.particleBirthRate = 3
        emitter.particleLifetime = 12
        emitter.particleLifetimeRange = 4
        emitter.emissionAngleRange = .pi * 2
        emitter.particleSpeed = 4
        emitter.particleSpeedRange = 3
        emitter.particleAlpha = 0.18
        emitter.particleAlphaRange = 0.08
        emitter.particleAlphaSpeed = -0.01
        emitter.particleScale = 0.06
        emitter.particleScaleRange = 0.03
        emitter.particleColor = NSColor(srgbRed: 0.7, green: 0.9, blue: 1, alpha: 1)
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .add
        emitter.particlePositionRange = CGVector(dx: width, dy: height)
        return emitter
    }

    /// A one-shot sparkle burst that emits a fixed number of particles then removes itself.
    static func sparkleBurst(texture: SKTexture) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = texture
        emitter.numParticlesToEmit = 16
        emitter.particleBirthRate = 400
        emitter.particleLifetime = 0.6
        emitter.particleLifetimeRange = 0.3
        emitter.emissionAngleRange = .pi * 2
        emitter.particleSpeed = 60
        emitter.particleSpeedRange = 30
        emitter.particleAlpha = 0.9
        emitter.particleAlphaSpeed = -1.4
        emitter.particleScale = 0.2
        emitter.particleScaleRange = 0.1
        emitter.particleScaleSpeed = -0.2
        emitter.particleColor = NSColor(srgbRed: 1, green: 0.95, blue: 0.7, alpha: 1)
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .add
        emitter.run(.sequence([.wait(forDuration: 1.4), .removeFromParent()]))
        return emitter
    }

    /// A single additive light shaft that hangs from the surface, sways, and pulses.
    static func godRay(texture: SKTexture, height: CGFloat) -> SKSpriteNode {
        let ray = SKSpriteNode(texture: texture)
        ray.size = CGSize(width: 60, height: height)
        ray.anchorPoint = CGPoint(x: 0.5, y: 1)
        ray.blendMode = .add
        ray.zRotation = -0.12
        ray.alpha = 0.4

        let sway = SKAction.sequence([
            .moveBy(x: 18, y: 0, duration: 6),
            .moveBy(x: -18, y: 0, duration: 6),
        ])
        sway.timingMode = .easeInEaseOut
        ray.run(.repeatForever(sway))

        let pulse = SKAction.sequence([
            .fadeAlpha(to: 0.5, duration: 4),
            .fadeAlpha(to: 0.25, duration: 4),
        ])
        pulse.timingMode = .easeInEaseOut
        ray.run(.repeatForever(pulse), withKey: "pulse")
        return ray
    }
}
