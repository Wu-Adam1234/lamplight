import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Renders the animated GIF used in the README and on the website, with the same
/// `Lantern` drawing code and animation curves the menu bar icon uses.
/// Run: Lamplight --render-demo docs/assets/demo.gif
enum DemoRenderer {
    private static let size = NSSize(width: 480, height: 180)
    private static let scale: CGFloat = 2
    private static let night = NSColor(srgbRed: 0x10 / 255, green: 0x14 / 255, blue: 0x2A / 255, alpha: 1)
    private static let bar = NSColor(srgbRed: 0x22 / 255, green: 0x27 / 255, blue: 0x48 / 255, alpha: 1)
    private static let cream = NSColor(srgbRed: 0xF4 / 255, green: 0xEE / 255, blue: 0xDF / 255, alpha: 1)
    private static let muted = NSColor(srgbRed: 0xAE / 255, green: 0xB3 / 255, blue: 0xC9 / 255, alpha: 1)
    private static let gold = NSColor(srgbRed: 0xF2 / 255, green: 0xC1 / 255, blue: 0x4E / 255, alpha: 1)

    private struct Frame {
        var level: CGFloat
        var caption: String
        var click: CGFloat? = nil     // 0...1 progress of the click ripple
        var rightClick = false
        var delay: Double
    }

    static func render(to url: URL) throws {
        var frames: [Frame] = []
        let fps = 30.0
        let offCaption = "Click the lantern to keep your Mac awake"
        let onCaption = "On until you click again"
        let sleepCaption = "Off. Your Mac sleeps as usual"

        frames.append(Frame(level: 0, caption: offCaption, delay: 1.2))
        for i in 0..<5 { frames.append(Frame(level: 0, caption: offCaption, click: CGFloat(i) / 5, delay: 1 / fps)) }
        let lightFrames = Int(Lantern.lightDuration * fps)
        for i in 0...lightFrames {
            let t = Double(i) / Double(lightFrames)
            frames.append(Frame(level: i == lightFrames ? 1 : Lantern.lightCurve(t), caption: onCaption, delay: 1 / fps))
        }
        frames.append(Frame(level: 1, caption: onCaption, delay: 1.8))
        for i in 0..<5 { frames.append(Frame(level: 1, caption: onCaption, click: CGFloat(i) / 5, delay: 1 / fps)) }
        let dimFrames = Int(Lantern.dimDuration * fps)
        for i in 0...dimFrames {
            let t = Double(i) / Double(dimFrames)
            frames.append(Frame(level: Lantern.dimCurve(t), caption: sleepCaption, delay: 1 / fps))
        }
        frames.append(Frame(level: 0, caption: sleepCaption, delay: 1.4))
        frames.append(Frame(level: 0, caption: "Right-click for\ntimers and settings", rightClick: true, delay: 2.4))

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(destination, draw(frame), [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frame.delay,
                    kCGImagePropertyGIFUnclampedDelayTime: frame.delay
                ]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func draw(_ frame: Frame) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)

        night.setFill()
        NSRect(origin: .zero, size: size).fill()

        // A menu bar strip with a few neutral neighbours and a clock
        let barRect = NSRect(x: 0, y: size.height - 66, width: size.width, height: 66)
        bar.setFill()
        barRect.fill()
        muted.withAlphaComponent(0.35).setFill()
        for x in [282.0, 314.0, 346.0] {
            NSBezierPath(roundedRect: NSRect(x: x, y: barRect.midY - 7, width: 14, height: 14), xRadius: 3.5, yRadius: 3.5).fill()
        }
        NSAttributedString(string: "6:30 PM", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: muted
        ]).draw(at: NSPoint(x: 400, y: barRect.midY - 9))

        // The lantern at 3x menu bar size, drawn by the app's own code
        let lanternOrigin = NSPoint(x: 196, y: barRect.midY - 27)
        if frame.level > 0 {
            let glowCenter = NSPoint(x: lanternOrigin.x + 27, y: lanternOrigin.y + 25)
            NSGradient(colors: [gold.withAlphaComponent(0.35 * min(frame.level, 1)), gold.withAlphaComponent(0)])!
                .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 46, options: [])
        }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: lanternOrigin.x, yBy: lanternOrigin.y)
        transform.scale(by: 3)
        transform.concat()
        Lantern.draw(level: frame.level, color: frame.level > 0 ? gold : cream)
        NSGraphicsContext.restoreGraphicsState()

        // Click ripple and pointer
        let tip = NSPoint(x: lanternOrigin.x + 44, y: lanternOrigin.y + 6)
        if let progress = frame.click {
            let radius = 6 + 16 * progress
            let ring = NSBezierPath(ovalIn: NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
            cream.withAlphaComponent(0.7 * (1 - progress)).setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
        if frame.rightClick {
            drawMiniMenu(topLeft: NSPoint(x: lanternOrigin.x + 4, y: barRect.minY - 4))
        }
        drawPointer(at: tip)

        // Caption
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = frame.rightClick ? .left : .center
        let caption = NSAttributedString(string: frame.caption, attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: cream, .paragraphStyle: paragraph
        ])
        let box = frame.rightClick
            ? NSRect(x: 22, y: 20, width: 175, height: 60)
            : NSRect(x: 0, y: 26, width: size.width, height: 30)
        caption.draw(in: box)

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private static func drawPointer(at tip: NSPoint) {
        let p = NSBezierPath()
        p.move(to: tip)
        p.line(to: NSPoint(x: tip.x, y: tip.y - 19))
        p.line(to: NSPoint(x: tip.x + 4.5, y: tip.y - 14.5))
        p.line(to: NSPoint(x: tip.x + 8, y: tip.y - 21))
        p.line(to: NSPoint(x: tip.x + 11, y: tip.y - 19.5))
        p.line(to: NSPoint(x: tip.x + 7.5, y: tip.y - 13))
        p.line(to: NSPoint(x: tip.x + 13.5, y: tip.y - 13))
        p.close()
        NSColor.white.setFill()
        p.fill()
        NSColor.black.setStroke()
        p.lineWidth = 1.2
        p.stroke()
    }

    /// A simple sketch of the top of the menu, using the app's real item names.
    private static func drawMiniMenu(topLeft: NSPoint) {
        let rows = ["Turn On", "Turn On For  ›", "Keep Awake with Lid Closed", "Turn On Lasts  ›"]
        let rect = NSRect(x: topLeft.x, y: topLeft.y - 106, width: 236, height: 106)
        cream.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        for (i, row) in rows.enumerated() {
            NSAttributedString(string: row, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: night
            ]).draw(at: NSPoint(x: rect.minX + 14, y: rect.maxY - 26 - CGFloat(i) * 23.5))
        }
    }
}
