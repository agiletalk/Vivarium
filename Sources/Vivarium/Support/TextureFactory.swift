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

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            Self.fillVerticalGradient(ctx, rect: rect, top: top, bottom: bottom)

            // Belly highlight.
            let belly = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.42)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.fill(belly)

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
            ctx.restoreGState()

            // Outline.
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(white: legendary ? 1 : 0, alpha: legendary ? 0.6 : 0.22).cgColor)
            ctx.setLineWidth(legendary ? 2 : 1.5)
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
            let path = CGMutablePath()
            // Fluke: joint at right edge (x = maxX), two lobes fanning to the left.
            let jointX = rect.maxX
            path.move(to: CGPoint(x: jointX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                              control: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.midY))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(base.cgColor)
            ctx.fillPath()
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
        switch species {
        case .whale:
            path.addEllipse(in: r)
            // Small dorsal bump.
            path.move(to: CGPoint(x: r.midX - 8, y: r.maxY - 4))
            path.addQuadCurve(to: CGPoint(x: r.midX + 8, y: r.maxY - 4),
                              control: CGPoint(x: r.midX, y: r.maxY + 10))
            path.closeSubpath()
        case .dolphin:
            path.addEllipse(in: r.insetBy(dx: 0, dy: r.height * 0.12))
            // Pointed snout at right.
            path.move(to: CGPoint(x: r.maxX - r.width * 0.18, y: r.midY + 6))
            path.addLine(to: CGPoint(x: r.maxX + 4, y: r.midY))
            path.addLine(to: CGPoint(x: r.maxX - r.width * 0.18, y: r.midY - 6))
            path.closeSubpath()
            // Curved dorsal fin.
            path.move(to: CGPoint(x: r.midX - 4, y: r.maxY - 8))
            path.addQuadCurve(to: CGPoint(x: r.midX + 12, y: r.maxY - 6),
                              control: CGPoint(x: r.midX + 2, y: r.maxY + 12))
            path.closeSubpath()
        case .pufferfish:
            path.addEllipse(in: r)
            // Radial spikes.
            let cx = r.midX, cy = r.midY, rad = min(r.width, r.height) * 0.5
            for i in 0..<10 {
                let a = Double(i) / 10 * 2 * .pi
                let bx = cx + CGFloat(cos(a)) * rad * 0.85
                let by = cy + CGFloat(sin(a)) * rad * 0.85
                let tx = cx + CGFloat(cos(a)) * rad * 1.18
                let ty = cy + CGFloat(sin(a)) * rad * 1.18
                let px = cx + CGFloat(cos(a + 0.18)) * rad * 0.8
                let py = cy + CGFloat(sin(a + 0.18)) * rad * 0.8
                path.move(to: CGPoint(x: bx, y: by))
                path.addLine(to: CGPoint(x: tx, y: ty))
                path.addLine(to: CGPoint(x: px, y: py))
                path.closeSubpath()
            }
        case .octopus:
            // Mantle in the top portion.
            let mantle = CGRect(x: r.minX, y: r.minY + r.height * 0.42,
                                width: r.width, height: r.height * 0.58)
            path.addEllipse(in: mantle)
            // Four baked tentacles hanging below.
            let legW = r.width * 0.18
            for i in 0..<4 {
                let lx = r.minX + r.width * (0.14 + 0.24 * Double(i))
                path.addRoundedRect(in: CGRect(x: lx - legW / 2, y: r.minY,
                                               width: legW, height: r.height * 0.52),
                                    cornerWidth: legW / 2, cornerHeight: legW / 2)
            }
        case .jellyfish:
            // Dome bell (upper half-ellipse).
            let bell = CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height * 0.5)
            path.addEllipse(in: bell)
            path.addRect(CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height * 0.14))
            // Wavy tentacles.
            let tentW = r.width * 0.12
            for i in 0..<4 {
                let tx = r.minX + r.width * (0.2 + 0.2 * Double(i))
                path.addRoundedRect(in: CGRect(x: tx - tentW / 2, y: r.minY,
                                               width: tentW, height: r.height * 0.5),
                                    cornerWidth: tentW / 2, cornerHeight: tentW / 2)
            }
        }
        return path
    }
}
