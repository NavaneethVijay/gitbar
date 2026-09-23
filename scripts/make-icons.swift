// Draws gitbar's app icon (all AppIcon sizes) and a 1024px preview.
//   swift scripts/make-icons.swift
// Output: Sources/Resources/Assets.xcassets/AppIcon.appiconset/
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("Sources/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Everything is laid out on a 1024 canvas (macOS icon grid: 824pt body,
/// 100pt margin) and scaled to the requested pixel size.
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)

    // Body: rounded square with soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    color(0x4B3BD9).setFill()
    bodyPath.fill()
    ctx.restoreGState()

    // Background gradient: indigo (top) → violet (bottom).
    ctx.saveGState()
    bodyPath.addClip()
    NSGradient(colors: [color(0x5C6CFF), color(0x6B3FE8), color(0x8A2FD6)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)

    ctx.restoreGState()

    // Glyph: a bar with a panel dropping from it — gitbar's own shape, a
    // popover under the menu bar. Card contents: a status dot and text lines.
    let white = NSColor.white
    let bar = NSRect(x: 232, y: 704, width: 560, height: 64)
    white.setFill()
    NSBezierPath(roundedRect: bar, xRadius: 32, yRadius: 32).fill()

    let card = NSRect(x: 262, y: 246, width: 500, height: 372)
    let pointer = NSBezierPath()
    pointer.move(to: NSPoint(x: 462, y: card.maxY - 2))
    pointer.line(to: NSPoint(x: 512, y: card.maxY + 52))
    pointer.line(to: NSPoint(x: 562, y: card.maxY - 2))
    pointer.close()
    pointer.fill()
    NSBezierPath(roundedRect: card, xRadius: 58, yRadius: 58).fill()

    // Status dot (the app's "all clear" green) and three muted lines.
    color(0x34C48C).setFill()
    NSBezierPath(ovalIn: NSRect(x: 318, y: 488, width: 76, height: 76)).fill()
    color(0x6B3FE8, 0.30).setFill()
    for line in [NSRect(x: 426, y: 508, width: 276, height: 36),
                 NSRect(x: 318, y: 404, width: 384, height: 36),
                 NSRect(x: 318, y: 316, width: 262, height: 36)] {
        NSBezierPath(roundedRect: line, xRadius: 18, yRadius: 18).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// macOS AppIcon slots: 16/32/128/256/512 pt at 1x and 2x.
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(drawIcon(pixels: points * scale), to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))

let previewPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
if let previewPath { writePNG(drawIcon(pixels: 1024), to: URL(fileURLWithPath: previewPath)) }
print("AppIcon written to \(iconSet.path)")
