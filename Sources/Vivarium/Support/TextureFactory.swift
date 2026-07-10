import AppKit
import CoreGraphics
import SpriteKit
import VivariumCore

/// Runtime Core Graphics texture generation. No asset catalogs, no `.sks` — every sprite,
/// gradient, and particle image is baked once and cached for the lifetime of the scene.
@MainActor
final class TextureFactory {
    private var cache: [String: SKTexture] = [:]

    // MARK: - Palette

    /// Distinct accent per provider, used to tint that provider's fish body.
    nonisolated static func accent(for provider: AgentProvider) -> NSColor {
        switch provider {
        case .claude: NSColor(srgbRed: 0.16, green: 0.74, blue: 0.69, alpha: 1)   // teal
        case .codex: NSColor(srgbRed: 0.98, green: 0.55, blue: 0.20, alpha: 1)    // orange
        case .gemini: NSColor(srgbRed: 0.56, green: 0.40, blue: 0.92, alpha: 1)   // purple
        case .cursor: NSColor(srgbRed: 0.95, green: 0.44, blue: 0.71, alpha: 1)   // pink
        case .opencode: NSColor(srgbRed: 0.30, green: 0.66, blue: 0.98, alpha: 1) // sky blue
        case .copilot: NSColor(srgbRed: 0.28, green: 0.74, blue: 0.55, alpha: 1)  // sea green
        case .gpt: NSColor(srgbRed: 0.30, green: 0.60, blue: 0.95, alpha: 1)      // blue
        }
    }

    nonisolated static func memoryColor(for domain: MemoryDomain) -> NSColor {
        switch domain {
        case .swift: NSColor(srgbRed: 0.96, green: 0.45, blue: 0.20, alpha: 1)
        case .ui: NSColor(srgbRed: 0.95, green: 0.35, blue: 0.62, alpha: 1)
        case .backend: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.48, alpha: 1)
        case .testing: NSColor(srgbRed: 0.95, green: 0.80, blue: 0.28, alpha: 1)
        case .planning: NSColor(srgbRed: 0.36, green: 0.62, blue: 0.96, alpha: 1)
        case .review: NSColor(srgbRed: 0.66, green: 0.46, blue: 0.94, alpha: 1)
        case .search: NSColor(srgbRed: 0.30, green: 0.82, blue: 0.86, alpha: 1)
        }
    }

    nonisolated static func statusColor(for status: AgentStatus) -> NSColor {
        switch status {
        case .searching: NSColor(srgbRed: 0.30, green: 0.82, blue: 0.86, alpha: 1)
        case .planning: NSColor(srgbRed: 0.45, green: 0.55, blue: 0.95, alpha: 1)
        case .coding: NSColor(srgbRed: 0.36, green: 0.70, blue: 0.98, alpha: 1)
        case .reviewing: NSColor(srgbRed: 0.66, green: 0.46, blue: 0.94, alpha: 1)
        case .testing: NSColor(srgbRed: 0.30, green: 0.80, blue: 0.60, alpha: 1)
        case .fixingBug: NSColor(srgbRed: 0.94, green: 0.38, blue: 0.34, alpha: 1)
        case .handingOff: NSColor(srgbRed: 0.95, green: 0.70, blue: 0.30, alpha: 1)
        case .waiting: NSColor(srgbRed: 0.90, green: 0.78, blue: 0.35, alpha: 1)
        case .resting: NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)
        case .celebrating: NSColor(srgbRed: 1.00, green: 0.84, blue: 0.35, alpha: 1)
        }
    }

    static func statusSymbol(for status: AgentStatus) -> String {
        switch status {
        case .searching: "magnifyingglass"
        case .planning: "list.bullet"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .reviewing: "eye.fill"
        case .testing: "checkmark.seal.fill"
        case .fixingBug: "ant.fill"
        case .handingOff: "arrow.triangle.branch"
        case .waiting: "hourglass"
        case .resting: "moon.zzz.fill"
        case .celebrating: "sparkles"
        }
    }

    // MARK: - Species geometry

    /// Point size of the baked body texture per species (its bounding box).
    static func bodySize(for species: FishSpecies) -> CGSize {
        switch species {
        case .whale: CGSize(width: 120, height: 62)
        case .dolphin: CGSize(width: 88, height: 42)
        case .octopus: CGSize(width: 72, height: 66)
        case .jellyfish: CGSize(width: 56, height: 66)
        case .pufferfish: CGSize(width: 60, height: 58)
        case .seaTurtle: CGSize(width: 92, height: 64)
        }
    }

    /// Whether the species gets a separate swishing tail sprite (vs. baked appendages).
    static func hasTail(_ species: FishSpecies) -> Bool {
        switch species {
        case .whale, .dolphin, .pufferfish: true
        case .octopus, .jellyfish, .seaTurtle: false
        }
    }

    // MARK: - Body

    /// A tinted body silhouette. `memory` bakes up to four colored stripes; `legendary` swaps
    /// the palette to gold. Faces +x (right).
    func body(species: FishSpecies, provider: AgentProvider, legendary: Bool, memory: [MemoryTrait]) -> SKTexture {
        let sig = memory.sorted { $0.domain.rawValue < $1.domain.rawValue }
            .map { "\($0.domain.rawValue)\($0.level)" }.joined(separator: ",")
        let key = "body|\(species.rawValue)|\(provider.rawValue)|\(legendary ? "gold" : "std")|\(sig)"
        let size = Self.bodySize(for: species)
        return texture(key: key, width: size.width, height: size.height) { ctx in
            let W = size.width, H = size.height
            let r = CGRect(x: 3, y: 3, width: W - 6, height: H - 6)
            let accent = legendary
                ? NSColor(srgbRed: 1.0, green: 0.820, blue: 0.322, alpha: 1) // #FFD152
                : Self.accent(for: provider)
            let alpha: CGFloat = species == .jellyfish ? 0.82 : 1.0
            func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
                CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy)
            }
            func blend(_ c: NSColor, _ other: NSColor, _ f: CGFloat) -> NSColor {
                c.blended(withFraction: f, of: other) ?? c
            }

            let all = Self.buddyPath(species, rect: r, mode: .all)

            // Sticker outline: fill the union silhouette 8× offset behind the body (uniform ~1.8px halo).
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.setFillColor(blend(accent, .black, 0.45).cgColor)
            let ow: CGFloat = 1.8
            for k in 0..<8 {
                let a = CGFloat(k) / 8 * .pi * 2
                ctx.saveGState()
                ctx.translateBy(x: cos(a) * ow, y: sin(a) * ow)
                ctx.addPath(all)
                ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.restoreGState()

            // Flat two-tone body, clipped to the silhouette.
            ctx.saveGState()
            ctx.addPath(all)
            ctx.clip()
            ctx.setAlpha(alpha)

            // 1) flat base tint
            ctx.setFillColor(blend(accent, .white, 0.16).cgColor)
            ctx.fill(CGRect(x: r.minX - 3, y: r.minY - 3, width: r.width + 6, height: r.height + 6))
            // 2) appendages (fins/tentacles/shell) one tone darker — the intended two-tone split
            ctx.addPath(Self.buddyPath(species, rect: r, mode: .fins))
            ctx.setFillColor(blend(accent, .black, species == .seaTurtle ? 0.20 : 0.13).cgColor)
            ctx.fillPath()
            // 3) light belly patch (single clean ellipse)
            if let bl = Self.belly2(species) {
                ctx.setFillColor(blend(accent, .white, 0.55).cgColor)
                let bp = CGMutablePath()
                Self.addRotatedEllipse(bp, center: P(bl.0, bl.1), rx: r.width * bl.2, ry: r.height * bl.3, rot: bl.4)
                ctx.addPath(bp)
                ctx.fillPath()
            }
            // 4) species point details
            Self.buddyDetails(species, ctx: ctx, rect: r, accent: accent)
            // 5) cheek blush
            for (bx, by) in Self.blushSpots(species) {
                Self.fillRadial(ctx, center: P(bx, by), radius: r.width * 0.07,
                                inner: NSColor(srgbRed: 1.0, green: 0.518, blue: 0.580, alpha: 0.45),
                                outer: NSColor(srgbRed: 1.0, green: 0.518, blue: 0.580, alpha: 0))
            }
            // 6) memory stripes
            let bands = memory.sorted { $0.level > $1.level }.prefix(4)
            if !bands.isEmpty {
                let bandH = r.height * 0.13
                var y = r.minY + r.height * 0.30
                for trait in bands {
                    ctx.setFillColor(Self.memoryColor(for: trait.domain).withAlphaComponent(0.35).cgColor)
                    ctx.fill(CGRect(x: r.minX, y: y, width: r.width, height: bandH * 0.6))
                    y += bandH
                }
            }
            // 7) gloss: tilted ellipse + micro-dot (consistent light source)
            let g = Self.gloss2(species)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor)
            let gp = CGMutablePath()
            Self.addRotatedEllipse(gp, center: P(g.0, g.1), rx: r.width * 0.075, ry: r.height * 0.045, rot: -0.35)
            ctx.addPath(gp)
            ctx.fillPath()
            let mdot = P(g.0 + 0.115, g.1 - 0.02)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.7).cgColor)
            ctx.fillEllipse(in: CGRect(x: mdot.x - 1.1, y: mdot.y - 1.1, width: 2.2, height: 2.2))
            ctx.restoreGState()

            // Mouth (unclipped): upper-arc smile, or a round "o" for the pufferfish.
            if let m = Self.mouth2(species) {
                let mp = P(m.fx, m.fy)
                let ink = NSColor(srgbRed: 25 / 255, green: 30 / 255, blue: 42 / 255, alpha: m.isO ? 0.55 : 0.6)
                if m.isO {
                    ctx.setFillColor(ink.cgColor)
                    ctx.fillEllipse(in: CGRect(x: mp.x - r.width * 0.026, y: mp.y - r.width * 0.033,
                                               width: r.width * 0.052, height: r.width * 0.066))
                } else {
                    ctx.setStrokeColor(ink.cgColor)
                    ctx.setLineWidth(1.4)
                    ctx.setLineCap(.round)
                    ctx.addArc(center: mp, radius: r.width * m.size, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
                    ctx.strokePath()
                }
            }

            // Octopus: the second (fixed) eye.
            if species == .octopus {
                let oe = P(0.40, 0.70)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: oe.x - 3.6, y: oe.y - 3.6, width: 7.2, height: 7.2))
                ctx.setStrokeColor(NSColor(srgbRed: 30 / 255, green: 36 / 255, blue: 48 / 255, alpha: 0.45).cgColor)
                ctx.setLineWidth(0.9)
                ctx.strokeEllipse(in: CGRect(x: oe.x - 3.6, y: oe.y - 3.6, width: 7.2, height: 7.2))
                ctx.setFillColor(NSColor(srgbRed: 0x23 / 255, green: 0x28 / 255, blue: 0x34 / 255, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: oe.x + 0.7 - 2.1, y: oe.y + 0.1 - 2.1, width: 4.2, height: 4.2))
                ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor)
                ctx.fillEllipse(in: CGRect(x: oe.x + 1.3 - 0.75, y: oe.y + 0.9 - 0.75, width: 1.5, height: 1.5))
            }
        }
    }

    // MARK: - Buddy geometry (1:1 port of the design fish-art.js)

    enum BuddyMode { case all, body, fins }

    /// Buddy silhouette. `.body` = the main mass, `.fins` = appendages, `.all` = union.
    static func buddyPath(_ species: FishSpecies, rect r: CGRect, mode: BuddyMode) -> CGPath {
        let path = CGMutablePath()
        let w = r.width, h = r.height
        func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + w * fx, y: r.minY + h * fy) }
        func M(_ fx: CGFloat, _ fy: CGFloat) { path.move(to: P(fx, fy)) }
        func L(_ fx: CGFloat, _ fy: CGFloat) { path.addLine(to: P(fx, fy)) }
        func Q(_ tx: CGFloat, _ ty: CGFloat, _ cx: CGFloat, _ cy: CGFloat) { path.addQuadCurve(to: P(tx, ty), control: P(cx, cy)) }
        func C(_ tx: CGFloat, _ ty: CGFloat, _ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat) {
            path.addCurve(to: P(tx, ty), control1: P(c1x, c1y), control2: P(c2x, c2y))
        }
        func E(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ rot: CGFloat = 0) {
            addRotatedEllipse(path, center: P(cx, cy), rx: rx * w, ry: ry * h, rot: rot)
        }
        let fins = mode == .all || mode == .fins
        let mass = mode == .all || mode == .body
        switch species {
        case .whale:
            if fins {
                M(0.30, 0.70); Q(0.02, 0.52, 0.10, 0.68); L(0.02, 0.44); Q(0.30, 0.30, 0.10, 0.32); path.closeSubpath()
                E(0.60, 0.20, 0.115, 0.06, -0.45)
            }
            if mass { E(0.58, 0.50, 0.40, 0.45) }
        case .dolphin:
            if fins {
                M(0.38, 0.84); Q(0.30, 1.02, 0.28, 0.98); Q(0.54, 0.85, 0.46, 1.02); path.closeSubpath()
                M(0.22, 0.62); Q(0.02, 0.52, 0.08, 0.62); L(0.02, 0.46); Q(0.22, 0.36, 0.08, 0.38); path.closeSubpath()
                E(0.50, 0.20, 0.095, 0.055, -0.5)
            }
            if mass {
                E(0.46, 0.52, 0.385, 0.40)
                M(0.74, 0.66); Q(0.98, 0.50, 0.96, 0.64); Q(0.74, 0.34, 0.96, 0.36); path.closeSubpath()
            }
        case .octopus:
            if fins { for i in 0..<4 {
                let fx = 0.235 + 0.175 * CGFloat(i); let dir: CGFloat = i % 2 == 0 ? 1 : -1
                let tipX = fx + dir * 0.05; let tipY = 0.10 + CGFloat(i % 2) * 0.04
                M(fx - 0.075, 0.50)
                C(tipX, tipY, fx - 0.10, 0.26, tipX - dir * 0.12, 0.14)
                C(fx + 0.075, 0.50, tipX + dir * 0.03, 0.15, fx + 0.10, 0.26)
                path.closeSubpath()
            } }
            if mass { E(0.50, 0.68, 0.385, 0.295) }
        case .jellyfish:
            if fins { for i in 0..<4 {
                let fx = 0.25 + 0.167 * CGFloat(i); let dir: CGFloat = i % 2 == 0 ? 1 : -1
                let botY = 0.10 + CGFloat(i % 3) * 0.05
                M(fx - 0.05, 0.46)
                C(fx + dir * 0.045, botY, fx - 0.065, 0.30, fx + dir * 0.10, 0.18)
                C(fx + 0.05, 0.46, fx + dir * 0.02, 0.19, fx + 0.065, 0.30)
                path.closeSubpath()
            } }
            if mass {
                M(0.05, 0.50); C(0.95, 0.50, -0.01, 0.98, 1.01, 0.98)
                Q(0.50, 0.505, 0.725, 0.435); Q(0.05, 0.50, 0.275, 0.435); path.closeSubpath()
            }
        case .pufferfish:
            let cx: CGFloat = 0.50, cy: CGFloat = 0.52, rr: CGFloat = 0.38
            if fins {
                for i in 0..<8 {
                    let a = CGFloat(i) / 8 * .pi * 2 + 0.18
                    let tx = cx + cos(a) * rr * 1.22, ty = cy + sin(a) * rr * 1.22
                    let half: CGFloat = 0.19
                    M(cx + cos(a - half) * rr * 0.97, cy + sin(a - half) * rr * 0.97)
                    Q(tx, ty, cx + cos(a - half * 0.3) * rr * 1.14, cy + sin(a - half * 0.3) * rr * 1.14)
                    Q(cx + cos(a + half) * rr * 0.97, cy + sin(a + half) * rr * 0.97,
                      cx + cos(a + half * 0.3) * rr * 1.14, cy + sin(a + half * 0.3) * rr * 1.14)
                    path.closeSubpath()
                }
                M(0.62, 0.16); Q(0.50, 0.02, 0.48, 0.08); Q(0.62, 0.16, 0.64, 0.05); path.closeSubpath()
            }
            if mass { E(cx, cy, rr, rr) }
        case .seaTurtle:
            if mass {
                E(0.60, 0.23, 0.135, 0.06, -0.55)
                E(0.21, 0.21, 0.105, 0.05, 0.5)
                E(0.055, 0.42, 0.05, 0.04)
                E(0.82, 0.52, 0.15, 0.175)
                E(0.44, 0.35, 0.305, 0.09)
            }
            if fins { E(0.44, 0.56, 0.34, 0.305) }
        }
        return path
    }

    private static func addRotatedEllipse(_ path: CGMutablePath, center c: CGPoint, rx: CGFloat, ry: CGFloat, rot: CGFloat) {
        let box = CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry)
        if rot == 0 {
            path.addEllipse(in: box)
        } else {
            let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rot).translatedBy(x: -c.x, y: -c.y)
            path.addEllipse(in: box, transform: t)
        }
    }

    /// Species point details drawn inside the body clip (design `drawBody2` step 4).
    private static func buddyDetails(_ species: FishSpecies, ctx: CGContext, rect r: CGRect, accent: NSColor) {
        func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy) }
        func dot(_ fx: CGFloat, _ fy: CGFloat, _ rad: CGFloat, _ color: NSColor) {
            let c = P(fx, fy)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad))
        }
        func soft(_ fx: CGFloat, _ fy: CGFloat, _ rad: CGFloat, _ color: NSColor) {
            fillRadial(ctx, center: P(fx, fy), radius: rad, inner: color, outer: color.withAlphaComponent(0))
        }
        let ink12 = NSColor(white: 0, alpha: 0.12)
        switch species {
        case .whale:
            dot(0.79, 0.47, 1.0, ink12); dot(0.835, 0.425, 0.85, ink12)
        case .octopus:
            for ax in [CGFloat(0.41), CGFloat(0.585)] {
                dot(ax, 0.36, 1.3, NSColor(white: 1, alpha: 0.5))
                dot(ax + 0.012, 0.24, 1.05, NSColor(white: 1, alpha: 0.44))
                dot(ax, 0.13, 0.8, NSColor(white: 1, alpha: 0.38))
            }
        case .jellyfish:
            soft(0.50, 0.72, r.width * 0.28, NSColor(white: 1, alpha: 0.25))
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
            ctx.setLineWidth(1.2); ctx.setLineCap(.round)
            ctx.move(to: P(0.12, 0.50))
            ctx.addQuadCurve(to: P(0.88, 0.50), control: P(0.50, 0.565))
            ctx.strokePath()
        case .pufferfish:
            dot(0.36, 0.68, 1.5, ink12); dot(0.50, 0.76, 1.7, ink12); dot(0.62, 0.66, 1.4, ink12)
        case .seaTurtle:
            ctx.setFillColor((accent.blended(withFraction: 0.45, of: .white) ?? accent).cgColor)
            let plastron = CGMutablePath()
            addRotatedEllipse(plastron, center: P(0.44, 0.35), rx: r.width * 0.295, ry: r.height * 0.078, rot: 0)
            ctx.addPath(plastron); ctx.fillPath()
            dot(0.35, 0.62, r.width * 0.05, NSColor(white: 1, alpha: 0.20))
            dot(0.505, 0.65, r.width * 0.048, NSColor(white: 1, alpha: 0.20))
            dot(0.44, 0.47, r.width * 0.046, NSColor(white: 1, alpha: 0.18))
        case .dolphin:
            break
        }
    }

    // Design buddy tables (fractions of the body box).
    private static func belly2(_ s: FishSpecies) -> (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)? {
        switch s {
        case .whale: (0.60, 0.27, 0.30, 0.19, 0.06)
        case .dolphin: (0.52, 0.30, 0.27, 0.17, 0.08)
        case .pufferfish: (0.50, 0.30, 0.26, 0.18, 0)
        case .octopus: (0.50, 0.62, 0.25, 0.15, 0)
        case .jellyfish, .seaTurtle: nil
        }
    }
    private static func gloss2(_ s: FishSpecies) -> (CGFloat, CGFloat) {
        switch s {
        case .whale: (0.64, 0.80)
        case .dolphin: (0.56, 0.78)
        case .octopus: (0.40, 0.85)
        case .jellyfish: (0.38, 0.82)
        case .pufferfish: (0.42, 0.78)
        case .seaTurtle: (0.36, 0.74)
        }
    }
    private static func mouth2(_ s: FishSpecies) -> (fx: CGFloat, fy: CGFloat, size: CGFloat, isO: Bool)? {
        switch s {
        case .whale: (0.83, 0.33, 0.045, false)
        case .octopus: (0.50, 0.58, 0.04, false)
        case .seaTurtle: (0.875, 0.44, 0.03, false)
        case .pufferfish: (0.84, 0.42, 0, true)
        case .dolphin: (0.86, 0.43, 0.035, false)
        case .jellyfish: nil
        }
    }
    private static func blushSpots(_ s: FishSpecies) -> [(CGFloat, CGFloat)] {
        switch s {
        case .whale: [(0.76, 0.40)]
        case .dolphin: [(0.70, 0.42)]
        case .octopus: [(0.64, 0.60), (0.36, 0.60)]
        case .pufferfish: [(0.70, 0.44)]
        case .seaTurtle: [(0.86, 0.45)]
        case .jellyfish: []
        }
    }

    /// Eye offset (fraction of the body box, from the (0.42,0.5) anchor) and size scale — design EYE2.
    static func eyeFraction(for s: FishSpecies) -> (CGFloat, CGFloat) {
        switch s {
        case .whale: (0.30, 0.06)
        case .dolphin: (0.24, 0.06)
        case .octopus: (0.18, 0.20)
        case .jellyfish: (0.07, 0.14)
        case .pufferfish: (0.18, 0.10)
        case .seaTurtle: (0.425, 0.05)
        }
    }
    static func eyeScale(for s: FishSpecies) -> CGFloat {
        switch s {
        case .whale: 1.25
        case .dolphin: 1.0
        case .octopus: 1.2
        case .jellyfish: 1.0
        case .pufferfish: 1.35
        case .seaTurtle: 0.95
        }
    }

    func tail(species: FishSpecies, provider: AgentProvider, legendary: Bool) -> SKTexture {
        let key = "tail|\(species.rawValue)|\(provider.rawValue)|\(legendary ? "gold" : "std")"
        let size = CGSize(width: 28, height: 34)
        return texture(key: key, width: size.width, height: size.height) { ctx in
            let r = CGRect(x: 3, y: 5, width: 22, height: 24)
            let accent = legendary
                ? NSColor(srgbRed: 1.0, green: 0.780, blue: 0.278, alpha: 1) // #FFC747
                : Self.accent(for: provider)
            func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
                CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy)
            }
            func blend(_ c: NSColor, _ other: NSColor, _ f: CGFloat) -> NSColor { c.blended(withFraction: f, of: other) ?? c }
            // Buddy crescent tail (design drawTail2): joint at the right edge, two lobes at the left.
            let path = CGMutablePath()
            path.move(to: P(1.0, 0.5))
            path.addQuadCurve(to: P(0.06, 0.92), control: P(0.30, 1.06))
            path.addQuadCurve(to: P(0.34, 0.5), control: P(0.26, 0.68))
            path.addQuadCurve(to: P(0.06, 0.08), control: P(0.26, 0.32))
            path.addQuadCurve(to: P(1.0, 0.5), control: P(0.30, -0.06))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(blend(blend(accent, .white, 0.16), .black, 0.13).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(blend(accent, .black, 0.45).cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    // MARK: - Small sprites

    /// Buddy cartoon eye (design drawEye2): big white base + dark ring + pupil + double highlight.
    /// Baked at a fixed geometry; `FishNode` scales the sprite per species (`eyeScale`).
    func eye() -> SKTexture {
        texture(key: "eye2", width: 14, height: 14) { ctx in
            let c = CGPoint(x: 7, y: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 4.3, y: c.y - 4.3, width: 8.6, height: 8.6))
            ctx.setStrokeColor(NSColor(srgbRed: 30 / 255, green: 36 / 255, blue: 48 / 255, alpha: 0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: c.x - 4.3, y: c.y - 4.3, width: 8.6, height: 8.6))
            ctx.setFillColor(NSColor(srgbRed: 0x23 / 255, green: 0x28 / 255, blue: 0x34 / 255, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x + 0.85 - 2.6, y: c.y + 0.15 - 2.6, width: 5.2, height: 5.2))
            ctx.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x + 1.6 - 1.05, y: c.y + 1.15 - 1.05, width: 2.1, height: 2.1))
            ctx.setFillColor(NSColor(white: 1, alpha: 0.7).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x + 0.2 - 0.5, y: c.y - 1.3 - 0.5, width: 1.0, height: 1.0))
        }
    }

    func selectionRing() -> SKTexture {
        texture(key: "ring", width: 72, height: 72) { ctx in
            let rect = CGRect(x: 4, y: 4, width: 64, height: 64)
            ctx.setStrokeColor(NSColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 0.95).cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: rect)
        }
    }

    func softDot() -> SKTexture {
        texture(key: "softDot", width: 20, height: 20) { ctx in
            Self.fillRadial(ctx, center: CGPoint(x: 10, y: 10), radius: 10,
                            inner: NSColor(white: 1, alpha: 1), outer: NSColor(white: 1, alpha: 0))
        }
    }

    func pellet() -> SKTexture {
        texture(key: "pellet", width: 14, height: 14) { ctx in
            Self.fillRadial(ctx, center: CGPoint(x: 7, y: 7), radius: 6,
                            inner: NSColor(srgbRed: 1.0, green: 0.82, blue: 0.42, alpha: 1),
                            outer: NSColor(srgbRed: 0.85, green: 0.55, blue: 0.18, alpha: 1))
            ctx.setFillColor(NSColor(white: 1, alpha: 0.7).cgColor)
            ctx.fillEllipse(in: CGRect(x: 4.5, y: 8, width: 3, height: 3))
        }
    }

    func pearl() -> SKTexture {
        texture(key: "pearl", width: 30, height: 30) { ctx in
            Self.fillRadial(ctx, center: CGPoint(x: 15, y: 15), radius: 14,
                            inner: NSColor(srgbRed: 0.85, green: 0.95, blue: 1.0, alpha: 1),
                            outer: NSColor(srgbRed: 0.45, green: 0.70, blue: 0.95, alpha: 0))
            ctx.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
            ctx.fillEllipse(in: CGRect(x: 10, y: 17, width: 4, height: 4))
        }
    }

    func shark() -> SKTexture {
        let size = CGSize(width: 160, height: 72)
        return texture(key: "shark", width: size.width, height: size.height) { ctx in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let body = CGMutablePath()
            // Sleek body facing right, forked tail at left.
            body.move(to: CGPoint(x: r.minX, y: r.maxY))                                  // upper tail lobe
            body.addLine(to: CGPoint(x: r.minX + r.width * 0.16, y: r.midY + 4))
            body.addLine(to: CGPoint(x: r.minX, y: r.minY))                               // lower tail lobe
            body.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY - 2),
                              control: CGPoint(x: r.midX, y: r.minY - 2))                 // belly to snout
            body.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.16, y: r.midY + 4),
                              control: CGPoint(x: r.midX, y: r.maxY + 8))                 // back
            body.closeSubpath()
            // Dorsal fin.
            body.move(to: CGPoint(x: r.midX - 6, y: r.midY + 10))
            body.addLine(to: CGPoint(x: r.midX + 10, y: r.maxY))
            body.addLine(to: CGPoint(x: r.midX + 14, y: r.midY + 10))
            body.closeSubpath()
            ctx.addPath(body)
            ctx.clip()
            Self.fillVerticalGradient(ctx, rect: r,
                                      top: NSColor(srgbRed: 0.42, green: 0.47, blue: 0.55, alpha: 1),
                                      bottom: NSColor(srgbRed: 0.20, green: 0.24, blue: 0.30, alpha: 1))
        }
    }

    // MARK: - Backgrounds

    func gradient(for phase: AmbientPhase) -> SKTexture {
        let key = "grad|\(phase.rawValue)"
        return texture(key: key, width: 8, height: 256) { ctx in
            let (top, mid, bottom) = Self.skyColors(phase)
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [bottom.cgColor, mid.cgColor, top.cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 4, y: 0), end: CGPoint(x: 4, y: 256), options: [])
            }
        }
    }

    func vignette() -> SKTexture {
        texture(key: "vignette", width: 256, height: 256) { ctx in
            Self.fillRadial(ctx, center: CGPoint(x: 128, y: 128), radius: 180,
                            inner: NSColor(white: 0, alpha: 0), outer: NSColor(white: 0, alpha: 1))
        }
    }

    func godRay() -> SKTexture {
        texture(key: "godRay", width: 48, height: 512) { ctx in
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [
                NSColor(white: 1, alpha: 0).cgColor,
                NSColor(white: 1, alpha: 0.5).cgColor,
            ] as CFArray
            if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 24, y: 0), end: CGPoint(x: 24, y: 512), options: [])
            }
        }
    }

    /// Simple reef decoration silhouettes anchored to the sand.
    func reefDecor(_ stage: ReefStage) -> SKTexture {
        let key = "reef|\(stage.rawValue)"
        let size = CGSize(width: 60, height: 70)
        return texture(key: key, width: size.width, height: size.height) { ctx in
            let r = CGRect(origin: .zero, size: size)
            switch stage {
            case .sand:
                break
            case .coral:
                Self.drawCoral(ctx, rect: r, color: NSColor(srgbRed: 0.95, green: 0.45, blue: 0.45, alpha: 1))
            case .shells:
                ctx.setFillColor(NSColor(srgbRed: 0.92, green: 0.86, blue: 0.72, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: 14, y: 4, width: 30, height: 22))
            case .seaweed:
                Self.drawSeaweed(ctx, rect: r, color: NSColor(srgbRed: 0.24, green: 0.62, blue: 0.36, alpha: 1))
            case .tropicalFish:
                Self.drawCoral(ctx, rect: r, color: NSColor(srgbRed: 0.55, green: 0.40, blue: 0.85, alpha: 1))
            case .grandAquarium:
                Self.drawCoral(ctx, rect: r, color: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1))
            }
        }
    }

    // MARK: - Status badge (SF Symbol)

    func statusBadge(_ status: AgentStatus) -> SKTexture {
        let key = "badge|\(status.rawValue)"
        if let cached = cache[key] { return cached }
        let color = Self.statusColor(for: status)
        let base = NSImage(systemSymbolName: Self.statusSymbol(for: status), accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 13, height: 13))
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let tinted = base.withSymbolConfiguration(config) ?? base
        let texture = SKTexture(image: tinted)
        texture.filteringMode = .linear
        cache[key] = texture
        return texture
    }

    // MARK: - Core Graphics helpers

    private func texture(key: String, width: CGFloat, height: CGFloat, draw: (CGContext) -> Void) -> SKTexture {
        if let cached = cache[key] { return cached }
        let scale: CGFloat = 2
        let pw = max(1, Int((width * scale).rounded()))
        let ph = max(1, Int((height * scale).rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            let empty = SKTexture()
            cache[key] = empty
            return empty
        }
        ctx.scaleBy(x: scale, y: scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        let texture: SKTexture
        if let image = ctx.makeImage() {
            texture = SKTexture(cgImage: image)
        } else {
            texture = SKTexture()
        }
        texture.filteringMode = .linear
        cache[key] = texture
        return texture
    }

    private static func fillVerticalGradient(_ ctx: CGContext, rect: CGRect, top: NSColor, bottom: NSColor) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [bottom.cgColor, top.cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func fillRadial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, inner: NSColor, outer: NSColor) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [inner.cgColor, outer.cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [.drawsAfterEndLocation])
    }

    private static func skyColors(_ phase: AmbientPhase) -> (top: NSColor, mid: NSColor, bottom: NSColor) {
        switch phase {
        case .dawn:
            (NSColor(srgbRed: 0.98, green: 0.72, blue: 0.58, alpha: 1),
             NSColor(srgbRed: 0.38, green: 0.58, blue: 0.68, alpha: 1),
             NSColor(srgbRed: 0.08, green: 0.20, blue: 0.34, alpha: 1))
        case .day:
            (NSColor(srgbRed: 0.36, green: 0.72, blue: 0.86, alpha: 1),
             NSColor(srgbRed: 0.16, green: 0.46, blue: 0.68, alpha: 1),
             NSColor(srgbRed: 0.04, green: 0.16, blue: 0.34, alpha: 1))
        case .evening:
            (NSColor(srgbRed: 0.88, green: 0.52, blue: 0.44, alpha: 1),
             NSColor(srgbRed: 0.32, green: 0.30, blue: 0.52, alpha: 1),
             NSColor(srgbRed: 0.06, green: 0.10, blue: 0.26, alpha: 1))
        case .night:
            (NSColor(srgbRed: 0.10, green: 0.16, blue: 0.34, alpha: 1),
             NSColor(srgbRed: 0.05, green: 0.09, blue: 0.22, alpha: 1),
             NSColor(srgbRed: 0.02, green: 0.03, blue: 0.10, alpha: 1))
        }
    }

    private static func drawCoral(_ ctx: CGContext, rect: CGRect, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        for dx in [CGFloat(14), 30, 44] {
            let branch = CGMutablePath()
            branch.addRoundedRect(in: CGRect(x: dx - 4, y: 2, width: 8, height: rect.height * 0.7),
                                  cornerWidth: 4, cornerHeight: 4)
            ctx.addPath(branch)
            ctx.fillPath()
        }
    }

    private static func drawSeaweed(_ ctx: CGContext, rect: CGRect, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        for dx in [CGFloat(18), 30, 42] {
            let blade = CGMutablePath()
            blade.move(to: CGPoint(x: dx - 3, y: 2))
            blade.addQuadCurve(to: CGPoint(x: dx + 3, y: rect.height * 0.9),
                               control: CGPoint(x: dx + 10, y: rect.height * 0.5))
            blade.addQuadCurve(to: CGPoint(x: dx + 3, y: 2),
                               control: CGPoint(x: dx + 12, y: rect.height * 0.4))
            blade.closeSubpath()
            ctx.addPath(blade)
            ctx.fillPath()
        }
    }


}
