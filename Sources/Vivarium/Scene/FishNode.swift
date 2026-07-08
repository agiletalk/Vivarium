import Foundation
import SpriteKit
import VivariumCore

/// One creature. The container node is never transformed for facing/bank so its badge, name, and
/// selection ring stay upright; only the inner `orientation` node flips and banks.
@MainActor
final class FishNode: SKNode {
    let fishID: FishID
    let species: FishSpecies
    let params: SpeciesMotionParams

    var steering: FishSteeringState

    private(set) var provider: AgentProvider
    private(set) var status: AgentStatus
    private(set) var isLegendary: Bool
    private(set) var memory: [MemoryTrait]
    private(set) var fatigue: Double
    private(set) var sizeScale: Double

    private let bobPhase: Double
    private var bank: Double = 0

    private let textures: TextureFactory
    private let orientation = SKNode()
    private let body: SKSpriteNode
    private let tail: SKSpriteNode?
    private let eye = SKSpriteNode()
    private let statusBadge = SKSpriteNode()
    private let nameLabel = SKLabelNode()
    private let selectionRing: SKSpriteNode
    private let bubbleAnchor = SKNode()
    private var shimmer: SKSpriteNode?

    /// Shared desaturate/dim shader; per-node saturation & brightness live in node attributes.
    private static let bodyShader: SKShader = {
        let shader = SKShader(source: """
        void main() {
            vec4 color = texture2D(u_texture, v_tex_coord);
            float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));
            color.rgb = mix(vec3(gray), color.rgb, a_saturation) * a_brightness;
            gl_FragColor = color;
        }
        """)
        shader.attributes = [
            SKAttribute(name: "a_saturation", type: .float),
            SKAttribute(name: "a_brightness", type: .float),
        ]
        return shader
    }()

    init(state: FishState, textures: TextureFactory, position: CGPoint, rng: inout SplitMix64) {
        self.fishID = state.id
        self.species = state.species
        self.params = SpeciesMotionParams.params(for: state.species)
        self.provider = state.provider
        self.status = state.status
        self.isLegendary = state.isLegendary
        self.memory = state.memory
        self.fatigue = state.fatigue
        self.sizeScale = state.size
        self.textures = textures
        self.bobPhase = rng.double(in: 0..<(2 * .pi))
        self.steering = FishSteeringState(position: SIMD2(Double(position.x), Double(position.y)), rng: &rng)

        let bodySize = TextureFactory.bodySize(for: state.species)
        self.body = SKSpriteNode(texture: textures.body(
            species: state.species, provider: state.provider,
            legendary: state.isLegendary, memory: state.memory))
        self.body.size = bodySize
        self.body.anchorPoint = CGPoint(x: 0.42, y: 0.5)

        if TextureFactory.hasTail(state.species) {
            let t = SKSpriteNode(texture: textures.tail(
                species: state.species, provider: state.provider, legendary: state.isLegendary))
            t.size = CGSize(width: 28, height: 34)
            self.tail = t
        } else {
            self.tail = nil
        }

        self.selectionRing = SKSpriteNode(texture: textures.selectionRing())

        super.init()

        setScale(state.size)

        body.shader = Self.bodyShader
        body.zPosition = 1

        orientation.addChild(body)
        if let tail {
            tail.anchorPoint = CGPoint(x: 1, y: 0.5)
            tail.position = CGPoint(x: -bodySize.width * 0.42 + 2, y: 0)
            tail.zPosition = 0
            orientation.addChild(tail)
            startTailSwish()
        }

        eye.texture = textures.eye()
        eye.size = CGSize(width: 6, height: 6)
        eye.position = eyePosition(bodySize: bodySize)
        eye.zPosition = 2
        orientation.addChild(eye)
        startBlink()

        orientation.xScale = CGFloat(steering.flipSign)
        orientation.zPosition = 0
        addChild(orientation)

        selectionRing.size = CGSize(width: bodySize.width * 1.35, height: bodySize.width * 1.35)
        selectionRing.zPosition = -1
        selectionRing.isHidden = true
        addChild(selectionRing)

        statusBadge.texture = textures.statusBadge(state.status)
        statusBadge.size = CGSize(width: 13, height: 13)
        statusBadge.position = CGPoint(x: bodySize.width * 0.34, y: bodySize.height * 0.5 + 4)
        statusBadge.zPosition = 3
        addChild(statusBadge)

        nameLabel.text = state.displayName
        nameLabel.fontName = "SFNS-Regular"
        nameLabel.fontSize = 9
        nameLabel.fontColor = NSColor(white: 1, alpha: 1)
        nameLabel.alpha = 0.75
        nameLabel.verticalAlignmentMode = .top
        nameLabel.horizontalAlignmentMode = .center
        nameLabel.position = CGPoint(x: 0, y: -bodySize.height * 0.5 - 4)
        nameLabel.zPosition = 2
        addChild(nameLabel)

        bubbleAnchor.position = CGPoint(x: 0, y: bodySize.height * 0.5 + 8)
        addChild(bubbleAnchor)

        applyFatigueAttributes()
        updateLegendaryChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Scene-space position where this fish's thought bubble should hover.
    var bubbleAnchorScenePosition: CGPoint {
        convert(bubbleAnchor.position, to: scene ?? self)
    }

    // MARK: - Per-frame motion

    func apply(steering next: FishSteeringState, dt: Double, time: Double) {
        steering = next
        let bob = SteeringMath.bobOffset(time: time, params: params, fatigue: fatigue, phase: bobPhase)
        position = CGPoint(x: next.position.x, y: next.position.y + bob)

        let target = CGFloat(next.flipSign)
        orientation.xScale += (target - orientation.xScale) * CGFloat(min(1, dt * 10))

        let vx = next.velocity.x
        let vy = next.velocity.y
        let rawBank = max(-0.35, min(0.35, atan2(vy, max(abs(vx), 1)))) * 0.55
        bank += (rawBank - bank) * min(1, dt * 6)
        orientation.zRotation = CGFloat(bank * next.flipSign)

        if let tail {
            let speed = (vx * vx + vy * vy).squareRoot()
            let cruise = max(params.cruiseSpeed, 1)
            tail.speed = CGFloat(max(0.3, min(2.2, speed / cruise)))
        }
    }

    // MARK: - Semantic updates

    func configure(from state: FishState) {
        setStatus(state.status)
        setSize(state.size, animated: false)
        setFatigue(state.fatigue)
        if memory != state.memory {
            memory = state.memory
            rebakeBody()
        }
        if isLegendary != state.isLegendary {
            isLegendary = state.isLegendary
            rebakeBody()
            updateLegendaryChrome()
        }
        if nameLabel.text != state.displayName {
            nameLabel.text = state.displayName
        }
    }

    func setStatus(_ status: AgentStatus) {
        guard status != self.status else { return }
        self.status = status
        statusBadge.texture = textures.statusBadge(status)
        if status == .celebrating {
            run(.sequence([
                .moveBy(x: 0, y: 10, duration: 0.16),
                .moveBy(x: 0, y: -10, duration: 0.20),
            ]))
        }
    }

    func setSize(_ size: Double, animated: Bool) {
        sizeScale = size
        if animated {
            let overshoot = SKAction.sequence([
                .scale(to: size * 1.08, duration: 0.18),
                .scale(to: size, duration: 0.16),
            ])
            overshoot.timingMode = .easeOut
            run(overshoot)
        } else {
            setScale(size)
        }
    }

    func setFatigue(_ fatigue: Double) {
        self.fatigue = max(0, min(1, fatigue))
        applyFatigueAttributes()
    }

    func setMemory(_ memory: [MemoryTrait]) {
        guard memory != self.memory else { return }
        self.memory = memory
        rebakeBody()
    }

    func setLegendary(_ legendary: Bool) {
        guard legendary != isLegendary else { return }
        isLegendary = legendary
        rebakeBody()
        updateLegendaryChrome()
    }

    func setSelected(_ selected: Bool) {
        selectionRing.isHidden = !selected
        selectionRing.removeAllActions()
        if selected {
            let pulse = SKAction.sequence([
                .group([.scale(to: 1.1, duration: 0.6), .fadeAlpha(to: 1, duration: 0.6)]),
                .group([.scale(to: 0.94, duration: 0.6), .fadeAlpha(to: 0.6, duration: 0.6)]),
            ])
            pulse.timingMode = .easeInEaseOut
            selectionRing.run(.repeatForever(pulse))
        }
    }

    /// Swim off-screen and fade out; the scene drops us from its index first.
    func detach() {
        removeAllActions()
        let off = SKAction.group([
            .moveBy(x: CGFloat(120 * steering.flipSign), y: 30, duration: 0.7),
            .fadeOut(withDuration: 0.7),
        ])
        run(.sequence([off, .removeFromParent()]))
    }

    // MARK: - Internals

    private func applyFatigueAttributes() {
        body.setValue(SKAttributeValue(float: Float(1 - 0.7 * fatigue)), forAttribute: "a_saturation")
        body.setValue(SKAttributeValue(float: Float(1 - 0.35 * fatigue)), forAttribute: "a_brightness")
        nameLabel.alpha = 0.75 * (1 - 0.3 * fatigue)
    }

    private func rebakeBody() {
        body.texture = textures.body(species: species, provider: provider, legendary: isLegendary, memory: memory)
        if tail != nil {
            tail?.texture = textures.tail(species: species, provider: provider, legendary: isLegendary)
        }
    }

    private func updateLegendaryChrome() {
        if isLegendary, shimmer == nil {
            let glow = SKSpriteNode(texture: textures.softDot())
            let bodySize = TextureFactory.bodySize(for: species)
            glow.size = CGSize(width: bodySize.width * 1.2, height: bodySize.width * 1.2)
            glow.color = NSColor(srgbRed: 1, green: 0.9, blue: 0.5, alpha: 1)
            glow.colorBlendFactor = 1
            glow.blendMode = .add
            glow.zPosition = -0.5
            glow.alpha = 0.35
            let pulse = SKAction.sequence([
                .fadeAlpha(to: 0.5, duration: 1.1),
                .fadeAlpha(to: 0.2, duration: 1.1),
            ])
            pulse.timingMode = .easeInEaseOut
            glow.run(.repeatForever(pulse))
            orientation.addChild(glow)
            shimmer = glow
        } else if !isLegendary, let shimmer {
            shimmer.removeFromParent()
            self.shimmer = nil
        }
    }

    private func startTailSwish() {
        guard let tail else { return }
        let swish = SKAction.sequence([
            .rotate(toAngle: 0.28, duration: 0.32),
            .rotate(toAngle: -0.28, duration: 0.32),
        ])
        swish.timingMode = .easeInEaseOut
        tail.run(.repeatForever(swish))
    }

    private func startBlink() {
        let blink = SKAction.sequence([
            .wait(forDuration: 2.6, withRange: 3.2),
            .scaleY(to: 0.15, duration: 0.06),
            .scaleY(to: 1.0, duration: 0.06),
        ])
        eye.run(.repeatForever(blink))
    }

    private func eyePosition(bodySize: CGSize) -> CGPoint {
        switch species {
        case .whale, .dolphin, .pufferfish:
            CGPoint(x: bodySize.width * 0.24, y: bodySize.height * 0.14)
        case .octopus, .jellyfish:
            CGPoint(x: bodySize.width * 0.14, y: bodySize.height * 0.18)
        case .seaTurtle:
            // On the head, which pokes out toward the front-right.
            CGPoint(x: bodySize.width * 0.44, y: 0)
        }
    }
}
