import AppKit
import VivariumCore

/// QA helper: renders every species' baked body texture large on a labeled sheet so fish detail
/// can be inspected without hunting for them in the live tank. Enabled via `--vivarium-fish-sheet`.
@MainActor
enum FishSheet {
    private static let order: [(FishSpecies, AgentProvider, String)] = [
        (.whale, .claude, "Claude · whale"),
        (.dolphin, .gpt, "GPT · dolphin"),
        (.octopus, .codex, "Codex · octopus"),
        (.jellyfish, .gemini, "Gemini · jellyfish"),
        (.pufferfish, .cursor, "Cursor · pufferfish"),
    ]

    static func renderPNG(scale: CGFloat = 3.0) -> Data? {
        let textures = TextureFactory()
        let cell = CGSize(width: 380, height: 360)
        let sheet = CGSize(width: cell.width * CGFloat(order.count), height: cell.height)

        // Draw into an explicit bitmap-backed context (reliable offscreen, unlike lockFocus).
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(sheet.width), pixelsHigh: Int(sheet.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = nsctx.cgContext

        let bg = NSGradient(colors: [
            NSColor(srgbRed: 0.05, green: 0.13, blue: 0.28, alpha: 1),
            NSColor(srgbRed: 0.02, green: 0.06, blue: 0.16, alpha: 1),
        ])
        bg?.draw(in: NSRect(origin: .zero, size: sheet), angle: -90)

        for (index, entry) in order.enumerated() {
            let (species, provider, label) = entry
            let bodySize = TextureFactory.bodySize(for: species)
            let tex = textures.body(species: species, provider: provider, legendary: false, memory: [])
            guard let cg = tex.cgImage() as CGImage? else { continue }

            let drawSize = CGSize(width: bodySize.width * scale, height: bodySize.height * scale)
            let originX = cell.width * CGFloat(index) + (cell.width - drawSize.width) / 2
            let originY = (cell.height - drawSize.height) / 2 + 20
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: originX, y: originY, width: drawSize.width, height: drawSize.height))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let textSize = str.size()
            str.draw(at: NSPoint(x: cell.width * CGFloat(index) + (cell.width - textSize.width) / 2, y: 26))
        }

        return rep.representation(using: .png, properties: [:])
    }
}
