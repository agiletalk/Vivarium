import Foundation
import SpriteKit
import VivariumCore

/// A falling food pellet. The scene reads its live position so the assigned fish can intercept it.
@MainActor
final class FoodNode: SKSpriteNode {
    let pelletID: Int
    let fishID: FishID

    init(pellet: FoodPellet, texture: SKTexture) {
        self.pelletID = pellet.id
        self.fishID = pellet.fish
        super.init(texture: texture, color: .clear, size: CGSize(width: 12, height: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func startFalling(to targetY: CGFloat) {
        let fall = SKAction.moveTo(y: targetY, duration: 2.2)
        fall.timingMode = .easeIn
        let wobble = SKAction.sequence([
            .moveBy(x: 6, y: 0, duration: 0.5),
            .moveBy(x: -12, y: 0, duration: 1.0),
            .moveBy(x: 6, y: 0, duration: 0.5),
        ])
        wobble.timingMode = .easeInEaseOut
        run(.group([fall, wobble]))
    }

    func markMissed() {
        removeAllActions()
        color = NSColor(srgbRed: 0.55, green: 0.42, blue: 0.42, alpha: 1)
        colorBlendFactor = 0.75
        run(.sequence([
            .group([.moveBy(x: 0, y: -40, duration: 1.2), .fadeOut(withDuration: 1.2)]),
            .removeFromParent(),
        ]))
    }

    func consume() {
        removeAllActions()
        run(.sequence([
            .group([.scale(to: 0.1, duration: 0.2), .fadeOut(withDuration: 0.2)]),
            .removeFromParent(),
        ]))
    }
}

/// A handoff pearl: rides a raised arc toward another fish, hovers while the subagent works,
/// then pops (returned) or fades gray (failed).
@MainActor
final class PearlNode: SKNode {
    let pearlID: Int
    let fishID: FishID
    private let sprite: SKSpriteNode

    init(pearl: Pearl, texture: SKTexture) {
        self.pearlID = pearl.id
        self.fishID = pearl.fish
        self.sprite = SKSpriteNode(texture: texture)
        super.init()

        sprite.size = CGSize(width: 22, height: 22)
        sprite.blendMode = .add
        addChild(sprite)

        let label = SKLabelNode(text: String(pearl.label.prefix(18)))
        label.fontName = "SFNS-Regular"
        label.fontSize = 8
        label.fontColor = NSColor(white: 1, alpha: 0.9)
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: 17)
        label.zPosition = 1

        let capsule = SKShapeNode(rectOf: CGSize(width: max(26, label.frame.width + 12), height: 14),
                                  cornerRadius: 7)
        capsule.fillColor = NSColor(white: 0, alpha: 0.42)
        capsule.strokeColor = .clear
        capsule.position = CGPoint(x: 0, y: 17)
        capsule.zPosition = 0
        addChild(capsule)
        addChild(label)

        let glow = SKAction.sequence([.fadeAlpha(to: 0.7, duration: 0.6), .fadeAlpha(to: 1, duration: 0.6)])
        sprite.run(.repeatForever(glow))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func travel(from: CGPoint, to: CGPoint) {
        position = from
        let path = CGMutablePath()
        path.move(to: .zero)
        let control = CGPoint(x: (to.x - from.x) / 2, y: (to.y - from.y) / 2 + 70)
        path.addQuadCurve(to: CGPoint(x: to.x - from.x, y: to.y - from.y), control: control)
        let follow = SKAction.follow(path, asOffset: true, orientToPath: false, duration: 1.4)
        follow.timingMode = .easeInEaseOut
        run(follow, withKey: "travel")
    }

    func enterWorking() {
        guard action(forKey: "bob") == nil else { return }
        run(.repeatForever(bob), withKey: "bob")
    }

    func succeed() {
        removeAction(forKey: "bob")
        run(.sequence([
            .group([.scale(to: 1.4, duration: 0.16), .fadeAlpha(to: 1, duration: 0.16)]),
            .scale(to: 1, duration: 0.14),
            .moveBy(x: 0, y: 12, duration: 0.18),
            .moveBy(x: 0, y: -12, duration: 0.18),
            .fadeOut(withDuration: 0.4),
            .removeFromParent(),
        ]))
    }

    func fail() {
        removeAction(forKey: "bob")
        sprite.color = NSColor(white: 0.5, alpha: 1)
        sprite.colorBlendFactor = 0.85
        run(.sequence([.fadeOut(withDuration: 0.8), .removeFromParent()]))
    }

    private var bob: SKAction {
        let seq = SKAction.sequence([.moveBy(x: 0, y: 6, duration: 1), .moveBy(x: 0, y: -6, duration: 1)])
        seq.timingMode = .easeInEaseOut
        return seq
    }
}

/// The predator. The scene reads its position every frame to drive fish flee behavior.
@MainActor
final class SharkNode: SKSpriteNode {
    init(texture: SKTexture) {
        super.init(texture: texture, color: .clear, size: CGSize(width: 150, height: 68))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func enter(in bounds: MotionBounds) {
        let midY = CGFloat(bounds.minY + bounds.height * 0.6)
        position = CGPoint(x: CGFloat(bounds.maxX) + 120, y: midY)
        xScale = -1  // face left while entering from the right
        let inX = CGFloat(bounds.minX + bounds.width * 0.62)
        let enter = SKAction.moveTo(x: inX, duration: 1.4)
        enter.timingMode = .easeOut
        let patrol = SKAction.sequence([
            .moveBy(x: CGFloat(-bounds.width * 0.3), y: 20, duration: 3),
            .moveBy(x: CGFloat(bounds.width * 0.3), y: -20, duration: 3),
        ])
        patrol.timingMode = .easeInEaseOut
        run(.sequence([enter, .repeatForever(patrol)]))
    }

    func leave(in bounds: MotionBounds) {
        removeAllActions()
        let out = SKAction.moveTo(x: CGFloat(bounds.maxX) + 160, duration: 0.9)
        out.timingMode = .easeIn
        run(.sequence([out, .removeFromParent()]))
    }
}

/// A rare visitor gliding across the tank on a gentle arc with a sparkle trail.
@MainActor
final class VisitorNode: SKNode {
    let kind: RareVisitor.Kind

    init(kind: RareVisitor.Kind, textures: TextureFactory) {
        self.kind = kind
        super.init()

        let sprite: SKSpriteNode
        switch kind {
        case .goldenFish:
            sprite = SKSpriteNode(texture: textures.body(
                species: .dolphin, provider: .gpt, legendary: true, memory: []))
            sprite.size = TextureFactory.bodySize(for: .dolphin)
        case .legendaryWhale:
            sprite = SKSpriteNode(texture: textures.body(
                species: .whale, provider: .claude, legendary: true, memory: []))
            sprite.size = TextureFactory.bodySize(for: .whale)
            sprite.setScale(1.35)
        }
        addChild(sprite)

        let trail = SKEmitterNode()
        trail.particleTexture = textures.softDot()
        trail.particleBirthRate = 14
        trail.particleLifetime = 1.4
        trail.particleSpeed = 6
        trail.particleAlpha = 0.7
        trail.particleAlphaSpeed = -0.5
        trail.particleScale = 0.25
        trail.particleScaleSpeed = -0.15
        trail.particleColor = NSColor(srgbRed: 1, green: 0.9, blue: 0.5, alpha: 1)
        trail.particleColorBlendFactor = 1
        trail.particleBlendMode = .add
        trail.zPosition = -1
        addChild(trail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func cross(in bounds: MotionBounds) {
        let y = CGFloat(bounds.minY + bounds.height * (kind == .legendaryWhale ? 0.6 : 0.72))
        position = CGPoint(x: CGFloat(bounds.minX) - 100, y: y)
        let duration: TimeInterval = kind == .legendaryWhale ? 14 : 9
        let path = CGMutablePath()
        path.move(to: .zero)
        let span = CGFloat(bounds.width) + 220
        path.addQuadCurve(to: CGPoint(x: span, y: 0), control: CGPoint(x: span / 2, y: 40))
        let follow = SKAction.follow(path, asOffset: true, orientToPath: false, duration: duration)
        run(.sequence([follow, .removeFromParent()]))
    }
}

/// A short-lived speech bubble anchored above a fish. Lives in the overlay layer so it is never
/// flipped or banked with the fish's body.
@MainActor
final class ThoughtBubbleNode: SKNode {
    init(message: String) {
        super.init()

        let text = String(message.prefix(28))
        let label = SKLabelNode(text: text)
        label.fontName = "SFNS-Regular"
        label.fontSize = 9
        label.fontColor = NSColor(white: 1, alpha: 0.95)
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.zPosition = 1

        let width = max(28, label.frame.width + 16)
        let bubble = SKShapeNode(rectOf: CGSize(width: width, height: 18), cornerRadius: 9)
        bubble.fillColor = NSColor(white: 0.05, alpha: 0.72)
        bubble.strokeColor = NSColor(white: 1, alpha: 0.12)
        bubble.lineWidth = 1
        bubble.zPosition = 0
        addChild(bubble)
        addChild(label)

        alpha = 0
        let life = SKAction.sequence([
            .fadeIn(withDuration: 0.2),
            .wait(forDuration: 2.5),
            .fadeOut(withDuration: 0.3),
            .removeFromParent(),
        ])
        run(life)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
