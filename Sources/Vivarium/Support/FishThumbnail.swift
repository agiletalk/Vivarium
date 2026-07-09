import AppKit
import SpriteKit
import VivariumCore

/// Cached small NSImages of each species' body, for the menu bar popover rows.
@MainActor
enum FishThumbnail {
    private static let textures = TextureFactory()
    private static var cache: [String: NSImage] = [:]

    static func image(species: FishSpecies, provider: AgentProvider) -> NSImage? {
        let key = "\(species.rawValue)|\(provider.rawValue)"
        if let cached = cache[key] { return cached }
        guard let cg = textures.body(species: species, provider: provider, legendary: false, memory: []).cgImage() as CGImage? else {
            return nil
        }
        let image = NSImage(cgImage: cg, size: TextureFactory.bodySize(for: species))
        cache[key] = image
        return image
    }
}
