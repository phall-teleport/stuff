// Generates an .iconset folder for the app icon. Run via the Makefile:
//   swift Scripts/make-icon.swift build/AppIcon.iconset
import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

func drawIcon(size s: CGFloat) {
    // macOS-style rounded tile, inset like Apple's template.
    let inset = s * 0.10
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.2237

    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    // Soft drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = s * 0.018
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    color(0xD93025).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Red gradient tile, lighter at the top.
    let tileGradient = NSGradient(colors: [color(0xF25C4E), color(0xE8453C), color(0xC5221F)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    tileGradient.draw(in: tilePath, angle: -90)

    // Subtle top highlight for a bit of depth.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // White envelope, centered.
    let envW = tile.width * 0.62
    let envH = envW * 0.70
    let env = NSRect(x: tile.midX - envW / 2, y: tile.midY - envH / 2, width: envW, height: envH)
    let envRadius = envW * 0.09

    NSGraphicsContext.saveGraphicsState()
    let envShadow = NSShadow()
    envShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    envShadow.shadowBlurRadius = s * 0.012
    envShadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
    envShadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: env, xRadius: envRadius, yRadius: envRadius).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Flap: a V from the top corners down to just below the middle, cut in the tile color.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: env, xRadius: envRadius, yRadius: envRadius).addClip()
    let flapStroke = envW * 0.075
    let flapBottom = NSPoint(x: env.midX, y: env.minY + env.height * 0.42)
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: env.minX - flapStroke, y: env.maxY + flapStroke * 0.4))
    flap.line(to: flapBottom)
    flap.line(to: NSPoint(x: env.maxX + flapStroke, y: env.maxY + flapStroke * 0.4))
    flap.lineWidth = flapStroke
    flap.lineJoinStyle = .round
    flap.lineCapStyle = .round
    color(0xD93025).setStroke()
    flap.stroke()

    // Faint crease lines from the bottom corners toward the flap point.
    let crease = NSBezierPath()
    crease.move(to: NSPoint(x: env.minX, y: env.minY))
    crease.line(to: NSPoint(x: env.midX, y: env.minY + env.height * 0.50))
    crease.line(to: NSPoint(x: env.maxX, y: env.minY))
    crease.lineWidth = flapStroke * 0.35
    crease.lineJoinStyle = .round
    color(0xD93025).withAlphaComponent(0.25).setStroke()
    crease.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote iconset to \(outDir.path)")
