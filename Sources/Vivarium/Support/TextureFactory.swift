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
    static func accent(for provider: AgentProvider) -> NSColor {
        switch provider {
        case .claude: NSColor(srgbRed: 0.16, green: 0.74, blue: 0.69, alpha: 1)   // teal
        case .codex: NSColor(srgbRed: 0.98, green: 0.55, blue: 0.20, alpha: 1)    // orange
        case .gemini: NSColor(srgbRed: 0.56, green: 0.40, blue: 0.92, alpha: 1)   // purple
        case .cursor: NSColor(srgbRed: 0.95, green: 0.44, blue: 0.71, alpha: 1)   // pink
        case .gpt: NSColor(srgbRed: 0.30, green: 0.60, blue: 0.95, alpha: 1)      // blue
        }
    }

    static func memoryColor(for domain: MemoryDomain) -> NSColor {
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

    static func statusColor(for status: AgentStatus) -> NSColor {
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
        }
    }

    /// Whether the species gets a separate swishing tail sprite (vs. baked appendages).
    static func hasTail(_ species: FishSpecies) -> Bool {
        switch species {
        case .whale, .dolphin, .pufferfish: true
        case .octopus, .jellyfish: false
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
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let path = Self.bodyPath(species, rect: rect)

            let base = legendary
                ? NSColor(srgbRed: 1.0, green: 0.82, blue: 0.32, alpha: 1)
                : Self.accent(for: provider)
            let top = base.blended(withFraction: 0.35, of: .white) ?? base
            let bottom = base.blended(withFraction: 0.30, of: .black) ?? base

            // Jellyfish read as soft, translucent creatures.
            let bodyAlpha: CGFloat = species == .jellyfish ? 0.72 : 1.0

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setAlpha(bodyAlpha)
            Self.fillVerticalGradient(ctx, rect: rect, top: top, bottom: bottom)

            // Soft belly lightening — a radial wash low and forward, no hard seam.
            let bellyCenter = CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.20)
            Self.fillRadial(ctx, center: bellyCenter, radius: rect.width * 0.55,
                            inner: NSColor(white: 1, alpha: 0.22), outer: NSColor(white: 1, alpha: 0))

            // Memory stripes (clipped to the body).
            let stripes = memory.sorted { $0.level > $1.level }.prefix(4)
            if !stripes.isEmpty {
                let bandH = rect.height * 0.15
                var y = rect.minY + rect.height * 0.28
                for trait in stripes {
                    let color = Self.memoryColor(for: trait.domain).withAlphaComponent(0.5)
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: bandH * 0.68))
                    y += bandH
                }
            }

            // Glossy specular highlight, high and forward.
            ctx.setAlpha(bodyAlpha)
            let glossCenter = CGPoint(x: rect.minX + rect.width * 0.60, y: rect.minY + rect.height * 0.78)
            Self.fillRadial(ctx, center: glossCenter, radius: rect.width * 0.30,
                            inner: NSColor(white: 1, alpha: 0.40), outer: NSColor(white: 1, alpha: 0))
            ctx.restoreGState()

            // Species-specific surface detailing (pleats, suckers, spots, bell ribs, …).
            Self.drawDetails(species, ctx: ctx, rect: rect, bodyPath: path, base: base, legendary: legendary)

            // Outline.
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(white: legendary ? 1 : 0, alpha: legendary ? 0.6 : 0.20).cgColor)
            ctx.setLineWidth(legendary ? 2 : 1.4)
            ctx.strokePath()
        }
    }

    func tail(species: FishSpecies, provider: AgentProvider, legendary: Bool) -> SKTexture {
        let key = "tail|\(species.rawValue)|\(provider.rawValue)|\(legendary ? "gold" : "std")"
        let size = CGSize(width: 28, height: 34)
        return texture(key: key, width: size.width, height: size.height) { ctx in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let base = legendary
                ? NSColor(srgbRed: 1.0, green: 0.78, blue: 0.28, alpha: 1)
                : (Self.accent(for: provider).blended(withFraction: 0.18, of: .black) ?? Self.accent(for: provider))
            let w = rect.width, h = rect.height
            func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + w * fx, y: rect.minY + h * fy)
            }
            // Crescent fluke: joint at the right edge, two lobes with a notch on the outer (left) edge.
            let path = CGMutablePath()
            path.move(to: P(1.0, 0.5))
            path.addQuadCurve(to: P(0.0, 1.0), control: P(0.55, 0.98))     // joint → upper lobe tip
            path.addQuadCurve(to: P(0.38, 0.5), control: P(0.14, 0.74))    // upper tip → center notch
            path.addQuadCurve(to: P(0.0, 0.0), control: P(0.14, 0.26))     // notch → lower lobe tip
            path.addQuadCurve(to: P(1.0, 0.5), control: P(0.55, 0.02))     // lower tip → joint
            path.closeSubpath()
            ctx.addPath(path)
            ctx.clip()
            Self.fillVerticalGradient(ctx, rect: rect,
                                      top: base.blended(withFraction: 0.22, of: .white) ?? base,
                                      bottom: base.blended(withFraction: 0.12, of: .black) ?? base)
        }
    }

    // MARK: - Small sprites

    func eye() -> SKTexture {
        texture(key: "eye", width: 8, height: 8) { ctx in
            ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 0.5, y: 0.5, width: 7, height: 7))
            ctx.setFillColor(NSColor(white: 1, alpha: 0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: 4.2, y: 4.2, width: 2.4, height: 2.4))
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

    // MARK: - Species silhouettes (union of ellipses + feature subpaths, filled non-zero)

    private static func bodyPath(_ species: FishSpecies, rect r: CGRect) -> CGPath {
        let path = CGMutablePath()
        let w = r.width, h = r.height
        // Fractional point helper: fx 0=tail(left)…1=head(right), fy 0=bottom…1=top.
        func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + w * fx, y: r.minY + h * fy)
        }

        switch species {
        case .whale:
            // Fat rounded head at the right tapering to a slim caudal peduncle at the left.
            path.move(to: P(0.03, 0.55))
            path.addCurve(to: P(0.60, 0.97), control1: P(0.16, 0.90), control2: P(0.40, 0.99))
            path.addCurve(to: P(0.99, 0.50), control1: P(0.82, 0.95), control2: P(1.03, 0.76))
            path.addCurve(to: P(0.58, 0.05), control1: P(1.02, 0.26), control2: P(0.85, 0.05))
            path.addCurve(to: P(0.03, 0.45), control1: P(0.34, 0.05), control2: P(0.14, 0.12))
            path.addQuadCurve(to: P(0.03, 0.55), control: P(-0.05, 0.50))
            path.closeSubpath()
            // Dorsal fin, swept back toward the tail.
            path.move(to: P(0.44, 0.93))
            path.addQuadCurve(to: P(0.60, 0.91), control: P(0.42, 1.20))
            path.closeSubpath()
            // Pectoral flipper on the lower front.
            path.move(to: P(0.66, 0.22))
            path.addQuadCurve(to: P(0.58, 0.03), control: P(0.52, 0.07))
            path.addQuadCurve(to: P(0.66, 0.22), control: P(0.72, 0.11))
            path.closeSubpath()

        case .dolphin:
            // Streamlined body with a melon forehead and a pointed rostrum at the right.
            path.move(to: P(0.04, 0.52))
            path.addCurve(to: P(0.52, 0.90), control1: P(0.16, 0.78), control2: P(0.34, 0.92))
            path.addCurve(to: P(0.86, 0.58), control1: P(0.66, 0.88), control2: P(0.80, 0.74))
            path.addQuadCurve(to: P(1.00, 0.47), control: P(0.99, 0.58))
            path.addQuadCurve(to: P(0.86, 0.39), control: P(0.99, 0.40))
            path.addCurve(to: P(0.30, 0.10), control1: P(0.70, 0.20), control2: P(0.52, 0.10))
            path.addQuadCurve(to: P(0.04, 0.44), control: P(0.12, 0.15))
            path.addQuadCurve(to: P(0.04, 0.52), control: P(-0.04, 0.48))
            path.closeSubpath()
            // Sickle dorsal fin, swept back.
            path.move(to: P(0.44, 0.85))
            path.addQuadCurve(to: P(0.28, 1.14), control: P(0.30, 1.00))
            path.addQuadCurve(to: P(0.56, 0.84), control: P(0.48, 1.00))
            path.closeSubpath()
            // Pectoral fin.
            path.move(to: P(0.58, 0.18))
            path.addQuadCurve(to: P(0.46, -0.02), control: P(0.44, 0.06))
            path.addQuadCurve(to: P(0.58, 0.18), control: P(0.62, 0.05))
            path.closeSubpath()

        case .pufferfish:
            // Round inflated body ringed with neat, short spikes.
            let bodyRect = r.insetBy(dx: w * 0.08, dy: h * 0.08)
            let cx = bodyRect.midX, cy = bodyRect.midY
            let rx = bodyRect.width * 0.5, ry = bodyRect.height * 0.5
            path.addEllipse(in: bodyRect)
            let n = 12
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                let half = (2 * .pi / Double(n)) * 0.42
                let base1 = CGPoint(x: cx + CGFloat(cos(a - half)) * rx, y: cy + CGFloat(sin(a - half)) * ry)
                let base2 = CGPoint(x: cx + CGFloat(cos(a + half)) * rx, y: cy + CGFloat(sin(a + half)) * ry)
                let tip = CGPoint(x: cx + CGFloat(cos(a)) * rx * 1.20, y: cy + CGFloat(sin(a)) * ry * 1.20)
                path.move(to: base1)
                path.addLine(to: tip)
                path.addLine(to: base2)
                path.closeSubpath()
            }
            // Small tail-side fin flick.
            path.move(to: P(0.60, 0.14))
            path.addQuadCurve(to: P(0.48, 0.00), control: P(0.46, 0.06))
            path.addQuadCurve(to: P(0.60, 0.14), control: P(0.62, 0.03))
            path.closeSubpath()

        case .octopus:
            // Bulbous mantle up top with five tapering, gently curling arms below.
            let mantle = CGRect(x: r.minX + w * 0.11, y: r.minY + h * 0.42,
                                width: w * 0.78, height: h * 0.56)
            path.addEllipse(in: mantle)
            let count = 5
            let baseY = r.minY + h * 0.50
            let armW = w * 0.11
            for i in 0..<count {
                let fx = 0.20 + 0.15 * CGFloat(i)
                let sx = r.minX + w * fx
                let dir: CGFloat = (i % 2 == 0) ? 1 : -1
                let tip = CGPoint(x: sx + dir * w * 0.07, y: r.minY + h * 0.02)
                path.move(to: CGPoint(x: sx - armW / 2, y: baseY))
                path.addCurve(to: tip,
                              control1: CGPoint(x: sx - armW * 0.9, y: r.minY + h * 0.22),
                              control2: CGPoint(x: sx + dir * w * 0.12, y: r.minY + h * 0.10))
                path.addCurve(to: CGPoint(x: sx + armW / 2, y: baseY),
                              control1: CGPoint(x: sx + dir * w * 0.02, y: r.minY + h * 0.10),
                              control2: CGPoint(x: sx + armW * 0.9, y: r.minY + h * 0.22))
                path.closeSubpath()
            }

        case .jellyfish:
            // Smooth dome bell with a scalloped hem and trailing wavy tentacles.
            let bellTopY = r.minY + h * 0.98
            let hemY = r.minY + h * 0.48
            let leftX = r.minX + w * 0.05, rightX = r.maxX - w * 0.05
            path.move(to: CGPoint(x: leftX, y: hemY))
            path.addCurve(to: CGPoint(x: rightX, y: hemY),
                          control1: CGPoint(x: r.minX + w * 0.00, y: bellTopY),
                          control2: CGPoint(x: r.maxX - w * 0.00, y: bellTopY))
            let scallops = 3
            let segW = (rightX - leftX) / CGFloat(scallops)
            for s in 0..<scallops {
                let x0 = rightX - CGFloat(s) * segW
                let x1 = x0 - segW
                path.addQuadCurve(to: CGPoint(x: x1, y: hemY),
                                  control: CGPoint(x: (x0 + x1) / 2, y: hemY - h * 0.11))
            }
            path.closeSubpath()
            // Tentacles of varying length.
            let tcount = 5
            for i in 0..<tcount {
                let fx = 0.22 + 0.14 * CGFloat(i)
                let sx = r.minX + w * fx
                let len = h * 0.28 + h * 0.16 * CGFloat((i * 3) % 4) / 3.0
                let botY = hemY - len
                let wob: CGFloat = (i % 2 == 0) ? 1 : -1
                let ww = w * 0.028
                path.move(to: CGPoint(x: sx - ww, y: hemY))
                path.addCurve(to: CGPoint(x: sx, y: botY),
                              control1: CGPoint(x: sx - ww - wob * w * 0.06, y: hemY - len * 0.5),
                              control2: CGPoint(x: sx + wob * w * 0.06, y: botY + len * 0.18))
                path.addCurve(to: CGPoint(x: sx + ww, y: hemY),
                              control1: CGPoint(x: sx + wob * w * 0.06, y: botY + len * 0.18),
                              control2: CGPoint(x: sx + ww - wob * w * 0.06, y: hemY - len * 0.5))
                path.closeSubpath()
            }
        }
        return path
    }

    // MARK: - Species detailing

    /// Draws per-species surface details on top of the base body fill (before the outline).
    private static func drawDetails(_ species: FishSpecies, ctx: CGContext, rect r: CGRect, bodyPath: CGPath, base: NSColor, legendary: Bool) {
        switch species {
        case .whale: detailWhale(ctx, rect: r, bodyPath: bodyPath, base: base, legendary: legendary)
        case .dolphin: detailDolphin(ctx, rect: r, bodyPath: bodyPath, base: base, legendary: legendary)
        case .octopus: detailOctopus(ctx, rect: r, bodyPath: bodyPath, base: base, legendary: legendary)
        case .jellyfish: detailJellyfish(ctx, rect: r, bodyPath: bodyPath, base: base, legendary: legendary)
        case .pufferfish: detailPuffer(ctx, rect: r, bodyPath: bodyPath, base: base, legendary: legendary)
        }
    }

    // MARK: whale details
    static func detailWhale(_ ctx: CGContext, rect r: CGRect, bodyPath: CGPath, base: NSColor, legendary: Bool) {
    func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy)
    }

    // Warm, soften the dark accents down for the gold legendary body.
    let belly = base.blended(withFraction: 0.5, of: .white) ?? base
    let grooveAlpha: CGFloat = legendary ? 0.07 : 0.12
    let mouthAlpha: CGFloat = legendary ? 0.14 : 0.22
    let blowAlpha: CGFloat = legendary ? 0.16 : 0.25

    // 1. Countershading belly: a crisper, clearly-lighter underside that fades
    //    softly up into the flank with no hard seam.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bellyRect = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.48)
    Self.fillVerticalGradient(ctx, rect: bellyRect,
                              top: belly.withAlphaComponent(0),
                              bottom: belly.withAlphaComponent(0.5))
    ctx.restoreGState()

    // 2. Ventral throat pleats: thin, gently curved grooves along the lower front.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.setStrokeColor(NSColor(white: 0, alpha: grooveAlpha).cgColor)
    ctx.setLineWidth(1.2)
    ctx.setLineCap(.round)
    for i in 0..<6 {
        let fx = 0.62 + 0.055 * CGFloat(i)   // 0.62 … 0.895
        let pleat = CGMutablePath()
        pleat.move(to: P(fx, 0.34))
        pleat.addQuadCurve(to: P(fx + 0.02, 0.06), control: P(fx - 0.03, 0.20))
        ctx.addPath(pleat)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // 3. Blowhole: a small dark oval on top of the head.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let blow = P(0.80, 0.90)
    ctx.setFillColor(NSColor(white: 0, alpha: blowAlpha).cgColor)
    ctx.fillEllipse(in: CGRect(x: blow.x - 3, y: blow.y - 1.8, width: 6, height: 3.6))
    ctx.restoreGState()

    // 4. Mouth line: a smooth, slightly downturned curve from the snout back.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let mouth = CGMutablePath()
    mouth.move(to: P(0.99, 0.40))
    mouth.addQuadCurve(to: P(0.76, 0.30), control: P(0.88, 0.28))
    ctx.addPath(mouth)
    ctx.setStrokeColor(NSColor(white: 0, alpha: mouthAlpha).cgColor)
    ctx.setLineWidth(1.4)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // 5. Soft highlight glint on the melon/forehead.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    Self.fillRadial(ctx, center: P(0.86, 0.72), radius: r.width * 0.09,
                    inner: NSColor(white: 1, alpha: 0.25), outer: NSColor(white: 1, alpha: 0))
    ctx.restoreGState()
}

    // MARK: dolphin details
    static func detailDolphin(_ ctx: CGContext, rect r: CGRect, bodyPath: CGPath, base: NSColor, legendary: Bool) {
    func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy) }

    let cs = CGColorSpaceCreateDeviceRGB()
    func linear(_ inner: NSColor, _ outer: NSColor, from a: CGPoint, to b: CGPoint, before: Bool) {
        let cols = [inner.cgColor, outer.cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: cs, colors: cols, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: before ? [.drawsBeforeStartLocation] : [])
    }

    let bellyLight = base.blended(withFraction: 0.55, of: .white) ?? base
    let darkTopA: CGFloat = legendary ? 0.05 : 0.10
    let stripeA: CGFloat = legendary ? 0.09 : 0.14
    let holeA: CGFloat = legendary ? 0.16 : 0.25
    let mouthA: CGFloat = legendary ? 0.20 : 0.28

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // 1a. Light underside — soft, slightly forward-rising diagonal edge over the lower body.
    linear(bellyLight.withAlphaComponent(0.5), bellyLight.withAlphaComponent(0),
           from: P(0.45, 0.06), to: P(0.72, 0.50), before: true)

    // 1b. Faint darker wash along the very top of the back.
    linear(NSColor(white: 0, alpha: darkTopA), NSColor(white: 0, alpha: 0),
           from: P(0.5, 1.0), to: P(0.5, 0.72), before: false)

    // 4. Soft countershade eye stripe sweeping back-down from behind the eye area.
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(NSColor(white: 0, alpha: stripeA).cgColor)
    ctx.setLineWidth(r.height * 0.14)
    let stripe = CGMutablePath()
    stripe.move(to: P(0.70, 0.60))
    stripe.addQuadCurve(to: P(0.55, 0.52), control: P(0.63, 0.55))
    ctx.addPath(stripe)
    ctx.strokePath()

    // 3. Blowhole — a tiny dark crescent on top.
    let bc = P(0.64, 0.84)
    let bw = r.width * 0.045
    let bh = r.height * 0.06
    let hole = CGMutablePath()
    hole.move(to: CGPoint(x: bc.x - bw, y: bc.y))
    hole.addQuadCurve(to: CGPoint(x: bc.x + bw, y: bc.y), control: CGPoint(x: bc.x, y: bc.y + bh))
    hole.addQuadCurve(to: CGPoint(x: bc.x - bw, y: bc.y), control: CGPoint(x: bc.x, y: bc.y + bh * 0.4))
    hole.closeSubpath()
    ctx.setFillColor(NSColor(white: 0, alpha: holeA).cgColor)
    ctx.addPath(hole)
    ctx.fillPath()

    // 5. Crisp gloss glint high on the melon.
    Self.fillRadial(ctx, center: P(0.80, 0.72), radius: r.width * 0.09,
                    inner: NSColor(white: 1, alpha: legendary ? 0.34 : 0.30),
                    outer: NSColor(white: 1, alpha: 0))

    // 2. Mouth line from the rostrum tip back, very slightly open (upper + lower jaw).
    ctx.setStrokeColor(NSColor(white: 0, alpha: mouthA).cgColor)
    ctx.setLineWidth(1.3)
    let mouth = CGMutablePath()
    mouth.move(to: P(1.0, 0.45))
    mouth.addQuadCurve(to: P(0.80, 0.44), control: P(0.90, 0.435))
    ctx.addPath(mouth)
    ctx.strokePath()
    ctx.setStrokeColor(NSColor(white: 0, alpha: mouthA * 0.7).cgColor)
    ctx.setLineWidth(1.1)
    let jaw = CGMutablePath()
    jaw.move(to: P(0.985, 0.415))
    jaw.addQuadCurve(to: P(0.85, 0.41), control: P(0.92, 0.40))
    ctx.addPath(jaw)
    ctx.strokePath()

    ctx.restoreGState()
}

    // MARK: octopus details
    static func detailOctopus(_ ctx: CGContext, rect r: CGRect, bodyPath: CGPath, base: NSColor, legendary: Bool) {
    func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy) }
    let w = r.width

    // Neutral shading tones (kept subtle; softened further when the body is gold).
    let shade = NSColor(white: 0, alpha: legendary ? 0.06 : 0.10)
    let clear = NSColor(white: 0, alpha: 0)

    // --- Surface details clipped to the silhouette ---
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // 3. Mantle mottling: soft, blurry darker blotches across the upper dome.
    let blotches: [(CGFloat, CGFloat, CGFloat)] = [
        (0.30, 0.86, 0.13),
        (0.58, 0.90, 0.11),
        (0.45, 0.75, 0.10),
        (0.70, 0.80, 0.12),
    ]
    for (bx, by, br) in blotches {
        Self.fillRadial(ctx, center: P(bx, by), radius: w * br, inner: shade, outer: clear)
    }

    // 4. Mantle gloss: a soft white radial highlight on top of the dome.
    Self.fillRadial(ctx, center: P(0.50, 0.90), radius: w * 0.26,
                    inner: NSColor(white: 1, alpha: legendary ? 0.34 : 0.30),
                    outer: NSColor(white: 1, alpha: 0))

    // 1. Suckers: a single centered column of light dots down the front arms,
    //    shrinking toward each arm tip; the frontmost arm gets the most.
    let sucker = NSColor(white: 1, alpha: 0.35).cgColor
    let arms: [(CGFloat, Int)] = [(0.50, 3), (0.65, 3), (0.80, 4)]
    ctx.setFillColor(sucker)
    for (ax, count) in arms {
        for i in 0..<count {
            let t: CGFloat = count <= 1 ? 0 : CGFloat(i) / CGFloat(count - 1) // 0 = top of arm, 1 = tip
            let fy = 0.42 - t * 0.30                                          // descend the arm
            let rad = w * (0.017 - t * 0.005)                                // taper toward the tip
            let c = P(ax, fy)
            ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
        }
    }
    ctx.restoreGState()

    // 5. Brow: a short soft dark curve above the eyes for a touch of expression.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.setStrokeColor(NSColor(white: 0, alpha: legendary ? 0.08 : 0.12).cgColor)
    ctx.setLineWidth(1.4)
    ctx.setLineCap(.round)
    let brow = CGMutablePath()
    brow.move(to: P(0.39, 0.795))
    brow.addQuadCurve(to: P(0.60, 0.795), control: P(0.495, 0.84))
    ctx.addPath(brow)
    ctx.strokePath()
    ctx.restoreGState()

    // 2. Second eye: a subtle mirror of the main eye so the face reads as two eyes.
    let eyeC = P(0.42, 0.70)
    let eyeR: CGFloat = 2.4
    ctx.setFillColor(NSColor(white: 0, alpha: legendary ? 0.5 : 0.7).cgColor)
    ctx.fillEllipse(in: CGRect(x: eyeC.x - eyeR, y: eyeC.y - eyeR, width: eyeR * 2, height: eyeR * 2))
    let hl = CGPoint(x: eyeC.x + 0.8, y: eyeC.y + 0.9)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.9).cgColor)
    ctx.fillEllipse(in: CGRect(x: hl.x - 0.9, y: hl.y - 0.9, width: 1.8, height: 1.8))
}

    // MARK: jellyfish details
    static func detailJellyfish(_ ctx: CGContext, rect r: CGRect, bodyPath: CGPath, base: NSColor, legendary: Bool) {
    func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy)
    }
    func lighter(_ f: CGFloat) -> NSColor { base.blended(withFraction: f, of: .white) ?? base }

    // Bell interior — inner glow, ribs, and hem rim, all kept inside the silhouette.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Inner glow near the top of the dome.
    Self.fillRadial(ctx, center: P(0.5, 0.72), radius: r.width * 0.35,
                    inner: NSColor(white: 1, alpha: 0.22), outer: NSColor(white: 1, alpha: 0))

    // Three faint vertical arc "ribs" fanning from the hem toward the dome top.
    let ribs = CGMutablePath()
    for fx in [CGFloat(0.34), 0.5, 0.66] {
        let d = fx - 0.5
        ribs.move(to: P(fx, 0.49))
        ribs.addQuadCurve(to: P(0.5 + d * 0.35, 0.90), control: P(fx + d * 0.6, 0.70))
    }
    ctx.addPath(ribs)
    ctx.setStrokeColor(lighter(0.5).withAlphaComponent(0.22).cgColor)
    ctx.setLineWidth(1.2)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Luminous scalloped hem rim, retracing the bell's bottom edge.
    let leftFx: CGFloat = 0.05, rightFx: CGFloat = 0.95, hemFy: CGFloat = 0.48
    let scallops = 3
    let segFx = (rightFx - leftFx) / CGFloat(scallops)
    let rim = CGMutablePath()
    rim.move(to: P(rightFx, hemFy))
    for s in 0..<scallops {
        let x0 = rightFx - CGFloat(s) * segFx
        let x1 = x0 - segFx
        rim.addQuadCurve(to: P(x1, hemFy), control: P((x0 + x1) / 2, hemFy - 0.11))
    }
    ctx.addPath(rim)
    ctx.setStrokeColor(lighter(0.65).withAlphaComponent(0.5).cgColor)
    ctx.setLineWidth(1.6)
    ctx.strokePath()

    ctx.restoreGState()

    // Oral arms — 4 gently wavy, tapering ribbons among the tentacles (unclipped, within r).
    let armColor = (base.blended(withFraction: 0.3, of: .white) ?? base).withAlphaComponent(0.5)
    ctx.setFillColor(armColor.cgColor)
    let arms: [(fx: CGFloat, dir: CGFloat, botFy: CGFloat)] = [
        (0.32, -1, 0.12), (0.44, 1, 0.10), (0.56, -1, 0.11), (0.68, 1, 0.13),
    ]
    let hw: CGFloat = 0.045, sway: CGFloat = 0.055, topFy: CGFloat = 0.47
    for a in arms {
        let bx = a.fx + a.dir * sway
        let arm = CGMutablePath()
        arm.move(to: P(a.fx - hw, topFy))
        arm.addCurve(to: P(bx, a.botFy),
                     control1: P(a.fx - hw - a.dir * sway, 0.34),
                     control2: P(bx + a.dir * sway * 0.5, 0.20))
        arm.addCurve(to: P(a.fx + hw, topFy),
                     control1: P(bx + a.dir * sway * 0.5, 0.20),
                     control2: P(a.fx + hw - a.dir * sway, 0.34))
        arm.closeSubpath()
        ctx.addPath(arm)
        ctx.fillPath()
    }

    // Bioluminescent dots tracing the glowing hem.
    ctx.setFillColor(NSColor(white: 1, alpha: 0.6).cgColor)
    let dots: [(CGFloat, CGFloat)] = [
        (0.20, 0.37), (0.35, 0.47), (0.50, 0.37), (0.65, 0.47), (0.80, 0.37), (0.92, 0.47),
    ]
    for dot in dots {
        let c = P(dot.0, dot.1)
        let rad: CGFloat = 1.3
        ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
    }
}

    // MARK: puffer details
    static func detailPuffer(_ ctx: CGContext, rect r: CGRect, bodyPath: CGPath, base: NSColor, legendary: Bool) {
    func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy) }

    // --- Surface details clipped to the body silhouette ---
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // 1. Belly countershade: lighter underside fading softly upward.
    let belly = (base.blended(withFraction: 0.5, of: .white) ?? base).withAlphaComponent(0.5)
    let bellyRect = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.45)
    Self.fillVerticalGradient(ctx, rect: bellyRect, top: belly.withAlphaComponent(0), bottom: belly)

    // 2. Classic puffer speckle over the upper body (eye at P(0.66,0.64) left clear).
    let spotColor = NSColor(white: 0, alpha: legendary ? 0.07 : 0.14)
    ctx.setFillColor(spotColor.cgColor)
    let spots: [(CGFloat, CGFloat, CGFloat)] = [
        (0.26, 0.60, 2.0), (0.34, 0.72, 2.2), (0.44, 0.62, 1.8),
        (0.40, 0.80, 1.8), (0.52, 0.70, 2.2), (0.55, 0.55, 1.6),
        (0.62, 0.80, 2.0), (0.78, 0.74, 1.8)
    ]
    for s in spots {
        let c = P(s.0, s.1)
        ctx.fillEllipse(in: CGRect(x: c.x - s.2, y: c.y - s.2, width: s.2 * 2, height: s.2 * 2))
    }

    // 3. Cheek blush: soft warm pink low on the face.
    let blush = NSColor(srgbRed: 1, green: 0.7, blue: 0.75, alpha: legendary ? 0.22 : 0.28)
    Self.fillRadial(ctx, center: P(0.72, 0.44), radius: r.width * 0.12, inner: blush, outer: blush.withAlphaComponent(0))

    // 6. Soft gloss glint high on the back.
    let glint = NSColor(white: 1, alpha: 0.28)
    Self.fillRadial(ctx, center: P(0.58, 0.80), radius: r.width * 0.16, inner: glint, outer: glint.withAlphaComponent(0))

    // 4. Pursed "o" mouth at the front for the puffer pout.
    let mouth = NSColor(white: 0, alpha: legendary ? 0.32 : 0.5)
    ctx.setFillColor(mouth.cgColor)
    let m = P(0.90, 0.42)
    ctx.fillEllipse(in: CGRect(x: m.x - 1.6, y: m.y - 2.0, width: 3.2, height: 4.0))

    ctx.restoreGState()

    // 5. Pectoral fin fanning from the side — drawn on the surface (no clip), within r.
    let finFill = (base.blended(withFraction: 0.2, of: .white) ?? base).withAlphaComponent(0.55)
    ctx.setFillColor(finFill.cgColor)
    let fin = CGMutablePath()
    fin.move(to: P(0.60, 0.40))
    fin.addQuadCurve(to: P(0.82, 0.28), control: P(0.74, 0.40))
    fin.addQuadCurve(to: P(0.62, 0.18), control: P(0.74, 0.20))
    fin.addQuadCurve(to: P(0.60, 0.40), control: P(0.58, 0.29))
    fin.closeSubpath()
    ctx.addPath(fin)
    ctx.fillPath()

    let ray = (base.blended(withFraction: 0.25, of: .black) ?? base).withAlphaComponent(legendary ? 0.15 : 0.25)
    ctx.setStrokeColor(ray.cgColor)
    ctx.setLineWidth(1)
    ctx.setLineCap(.round)
    ctx.move(to: P(0.62, 0.36)); ctx.addLine(to: P(0.79, 0.30)); ctx.strokePath()
    ctx.move(to: P(0.63, 0.29)); ctx.addLine(to: P(0.76, 0.23)); ctx.strokePath()
}

}
