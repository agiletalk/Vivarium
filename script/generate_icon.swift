#!/usr/bin/env swift
// Generates the Vivarium app icon: an ocean-gradient rounded rect with a white fish symbol.
// Usage: swift script/generate_icon.swift <output.iconset dir>
// Then:  iconutil -c icns <output.iconset> -o AppIcon.icns

import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: generate_icon.swift <output.iconset>\n".utf8))
    exit(2)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // macOS icon grid: content inset ~10%, corner radius ~22.5% of the content size.
    let inset = size * 0.09
    let content = rect.insetBy(dx: inset, dy: inset)
    let radius = content.width * 0.225
    let path = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)
    path.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.02, green: 0.24, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.52, blue: 0.62, alpha: 1),
    ])
    gradient?.draw(in: content, angle: -70)

    // Faint light rays.
    NSColor.white.withAlphaComponent(0.08).setFill()
    for i in 0..<3 {
        let ray = NSBezierPath()
        let x = content.minX + content.width * (0.25 + 0.22 * CGFloat(i))
        ray.move(to: NSPoint(x: x, y: content.maxY))
        ray.line(to: NSPoint(x: x + content.width * 0.10, y: content.maxY))
        ray.line(to: NSPoint(x: x - content.width * 0.10, y: content.minY))
        ray.line(to: NSPoint(x: x - content.width * 0.20, y: content.minY))
        ray.close()
        ray.fill()
    }

    // Bubbles.
    NSColor.white.withAlphaComponent(0.28).setStroke()
    let bubbleSpecs: [(CGFloat, CGFloat, CGFloat)] = [(0.24, 0.70, 0.045), (0.30, 0.80, 0.028), (0.76, 0.26, 0.035)]
    for (bx, by, br) in bubbleSpecs {
        let r = content.width * br
        let bubble = NSBezierPath(ovalIn: NSRect(
            x: content.minX + content.width * bx - r,
            y: content.minY + content.height * by - r,
            width: r * 2, height: r * 2
        ))
        bubble.lineWidth = max(1, size * 0.006)
        bubble.stroke()
    }

    // Fish symbol.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    if let fish = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: fish.size)
        tinted.lockFocus()
        NSColor.white.set()
        let fishRect = NSRect(origin: .zero, size: fish.size)
        fish.draw(in: fishRect)
        fishRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let target = NSRect(
            x: content.midX - fish.size.width / 2,
            y: content.midY - fish.size.height / 2,
            width: fish.size.width,
            height: fish.size.height
        )
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.96)
    }

    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        throw NSError(domain: "icon", code: 1)
    }
    rep.size = image.size
    guard let resized = resample(rep, to: pixels),
          let png = resized.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try png.write(to: url)
}

func resample(_ rep: NSBitmapImageRep, to pixels: Int) -> NSBitmapImageRep? {
    guard let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    out.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return out
}

let master = drawIcon(size: 1024)
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    try writePNG(master, pixels: px, to: outDir.appendingPathComponent(name))
}
print("iconset written to \(outDir.path)")
