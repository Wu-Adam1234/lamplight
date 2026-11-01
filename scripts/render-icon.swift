// Renders the Lamplight app icon (a lit lantern on a night-blue tile) as PNG files.
// Usage: swift scripts/render-icon.swift <output-dir>
// Writes icon_<size>.png for the sizes macOS needs, and social.png (1200x630).
import AppKit

let night = NSColor(srgbRed: 0x10 / 255, green: 0x14 / 255, blue: 0x2A / 255, alpha: 1)
let dusk = NSColor(srgbRed: 0x2A / 255, green: 0x30 / 255, blue: 0x5C / 255, alpha: 1)
let gold = NSColor(srgbRed: 0xF2 / 255, green: 0xC1 / 255, blue: 0x4E / 255, alpha: 1)
let ember = NSColor(srgbRed: 0xF0 / 255, green: 0x8A / 255, blue: 0x2E / 255, alpha: 1)
let cream = NSColor(srgbRed: 0xFF / 255, green: 0xF1 / 255, blue: 0xC7 / 255, alpha: 1)
let brass = NSColor(srgbRed: 0xE9 / 255, green: 0xD8 / 255, blue: 0xB0 / 255, alpha: 1)

func flame(_ x: CGFloat, _ bottom: CGFloat, _ top: CGFloat, _ w: CGFloat) -> NSBezierPath {
    let h = top - bottom
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: top))
    p.curve(to: NSPoint(x: x + w, y: bottom + h * 0.3), controlPoint1: NSPoint(x: x + w * 0.25, y: bottom + h * 0.78), controlPoint2: NSPoint(x: x + w, y: bottom + h * 0.58))
    p.curve(to: NSPoint(x: x, y: bottom), controlPoint1: NSPoint(x: x + w, y: bottom + h * 0.1), controlPoint2: NSPoint(x: x + w * 0.55, y: bottom))
    p.curve(to: NSPoint(x: x - w, y: bottom + h * 0.3), controlPoint1: NSPoint(x: x - w * 0.55, y: bottom), controlPoint2: NSPoint(x: x - w, y: bottom + h * 0.1))
    p.curve(to: NSPoint(x: x, y: top), controlPoint1: NSPoint(x: x - w, y: bottom + h * 0.58), controlPoint2: NSPoint(x: x - w * 0.25, y: bottom + h * 0.78))
    p.close()
    return p
}

/// Draws the lantern on the same 18-unit grid as the menu bar icon, scaled by `s`, origin at `o`.
func drawLantern(origin o: NSPoint, scale s: CGFloat) {
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: o.x + x * s, y: o.y + y * s, width: w * s, height: h * s)
    }
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: o.x + x * s, y: o.y + y * s) }

    let glowCenter = pt(9, 8.2)
    let glow = NSGradient(colors: [gold.withAlphaComponent(0.55), gold.withAlphaComponent(0.0)])!
    glow.draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 9.5 * s, options: [])

    brass.setStroke()
    brass.setFill()
    let handle = NSBezierPath(ovalIn: r(6.6, 13.4, 4.8, 4.0))
    handle.lineWidth = 1.0 * s
    handle.stroke()

    let cap = NSBezierPath()
    cap.move(to: pt(4.8, 12.4)); cap.line(to: pt(13.2, 12.4)); cap.line(to: pt(11.4, 14.6)); cap.line(to: pt(6.6, 14.6)); cap.close()
    cap.fill()

    let glassRect = r(5.6, 4.3, 6.8, 8.2)
    let warm = NSGradient(colors: [gold.withAlphaComponent(0.55), ember.withAlphaComponent(0.35)])!
    warm.draw(in: NSBezierPath(roundedRect: glassRect, xRadius: 1.6 * s, yRadius: 1.6 * s), angle: -90)
    let glass = NSBezierPath(roundedRect: glassRect.insetBy(dx: 0.5 * s, dy: 0.5 * s), xRadius: 1.2 * s, yRadius: 1.2 * s)
    glass.lineWidth = 1.0 * s
    glass.stroke()

    NSBezierPath(roundedRect: r(4.4, 2.2, 9.2, 2.1), xRadius: 0.9 * s, yRadius: 0.9 * s).fill()

    let outer = flame(o.x + 9 * s, o.y + 5.4 * s, o.y + 11.2 * s, 2.0 * s)
    NSGradient(colors: [ember, gold])!.draw(in: outer, angle: 90)
    let inner = flame(o.x + 9 * s, o.y + 5.6 * s, o.y + 9.4 * s, 1.05 * s)
    cream.setFill()
    inner.fill()
}

func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func appIcon(_ side: CGFloat) {
    let k = side / 1024
    // macOS icon grid: an 824pt tile centred in 1024, with a soft shadow.
    let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    night.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [dusk, night])!.draw(in: shape, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let stars: [(CGFloat, CGFloat, CGFloat)] = [(230, 760, 5), (300, 820, 3), (780, 790, 4), (720, 700, 3), (840, 600, 3), (190, 560, 3)]
    for (x, y, rad) in stars {
        cream.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: (x - rad) * k, y: (y - rad) * k, width: rad * 2 * k, height: rad * 2 * k)).fill()
    }
    let s: CGFloat = 36 * k
    drawLantern(origin: NSPoint(x: 512 * k - 9 * s, y: 512 * k - 9.6 * s), scale: s)
    NSGraphicsContext.restoreGraphicsState()
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = bitmap(size, size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    appIcon(CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    try write(rep, to: out.appendingPathComponent("icon_\(size).png"))
}

// Social card, 1200x630: the icon on the left, the wordmark on the right.
let social = bitmap(1200, 630)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: social)
NSGradient(colors: [dusk, night])!.draw(in: NSRect(x: 0, y: 0, width: 1200, height: 630), angle: -90)
let ctx = NSGraphicsContext.current!.cgContext
ctx.saveGState()
ctx.translateBy(x: 60, y: 85)
ctx.scaleBy(x: 460 / 1024, y: 460 / 1024)
appIcon(1024)
ctx.restoreGState()
NSAttributedString(string: "Lamplight", attributes: [
    .font: NSFont.systemFont(ofSize: 96, weight: .bold), .foregroundColor: cream
]).draw(at: NSPoint(x: 560, y: 330))
NSAttributedString(string: "Keep your Mac awake, lid open or closed.\nFree and open source.", attributes: [
    .font: NSFont.systemFont(ofSize: 32, weight: .regular),
    .foregroundColor: NSColor(srgbRed: 0.68, green: 0.70, blue: 0.79, alpha: 1)
]).draw(in: NSRect(x: 564, y: 200, width: 600, height: 110))
NSGraphicsContext.restoreGraphicsState()
try write(social, to: out.appendingPathComponent("social.png"))
print("icons written to \(out.path)")
