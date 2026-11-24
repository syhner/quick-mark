// Draws the app icon into AppIcon.icns. Run from the repo root: `swift scripts/make-icon.swift`.
import AppKit

let red = NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1)  // As Markup draws.
let gray = NSColor(white: 0.72, alpha: 1)

func fillWithShadow(_ path: NSBezierPath, _ color: NSColor, alpha: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(alpha)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 20
    shadow.set()
    color.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws on a 1024pt canvas: a tilted page on blue, with four lines of text.
/// The 2nd is boxed, the 3rd filled and the 4th underlined: one per tool. Gaps between them are equal.
func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    fillWithShadow(background, .white, alpha: 0.3)
    NSGradient(starting: NSColor(srgbRed: 0.3, green: 0.55, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.28, blue: 0.8, alpha: 1))!.draw(in: background, angle: -90)

    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: .pi / 30)
    ctx.translateBy(x: -512, y: -512)
    fillWithShadow(NSBezierPath(roundedRect: NSRect(x: 230, y: 190, width: 564, height: 644), xRadius: 36, yRadius: 36),
                   .white, alpha: 0.35)

    for y: CGFloat in [719, 581, 427, 323] {
        gray.setFill()
        NSBezierPath(roundedRect: NSRect(x: 300, y: y, width: 424, height: 44), xRadius: 22, yRadius: 22).fill()
    }

    let lineWidth: CGFloat = 24
    red.setStroke()
    let box = NSBezierPath(rect: NSRect(x: 262, y: 543, width: 500, height: 120))
    box.lineWidth = lineWidth
    box.lineJoinStyle = .round
    box.stroke()

    NSColor.black.setFill()
    NSRect(x: 262, y: 411, width: 500, height: 76).fill()

    let squiggle = NSBezierPath()
    squiggle.move(to: NSPoint(x: 296, y: 283))
    for i in 0..<4 {
        let x = 296 + CGFloat(i) * 108
        squiggle.curve(to: NSPoint(x: x + 108, y: 283),
                       controlPoint1: NSPoint(x: x + 36, y: 247), controlPoint2: NSPoint(x: x + 72, y: 319))
    }
    squiggle.lineWidth = lineWidth
    squiggle.lineCapStyle = .round
    squiggle.lineJoinStyle = .round
    squiggle.stroke()
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon()
        NSGraphicsContext.current = nil
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote AppIcon.icns")
