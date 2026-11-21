// Draws the app icon into an .iconset directory: a speaker sending sound both ways on a gradient square.
// Usage: swift scripts/make-icon.swift <output.iconset>
// assets/icon.png (README) is the 256 px file from this script.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with rounded corners.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.24, alpha: 1),
                        NSColor(red: 0.86, green: 0.20, blue: 0.42, alpha: 1)])!.draw(in: path, angle: -60)
    // A speaker in the middle with sound spreading out to both sides: filling the room.
    let center = NSPoint(x: body.midX, y: body.midY)
    let cabinet = NSRect(x: center.x - s * 0.12, y: center.y - s * 0.19, width: s * 0.24, height: s * 0.38)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: cabinet, xRadius: s * 0.045, yRadius: s * 0.045).fill()
    let accent = NSColor(red: 0.90, green: 0.32, blue: 0.36, alpha: 1)
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - s * 0.075, y: cabinet.minY + s * 0.05, width: s * 0.15, height: s * 0.15)).fill()
    NSBezierPath(ovalIn: NSRect(x: center.x - s * 0.035, y: cabinet.maxY - s * 0.12, width: s * 0.07, height: s * 0.07)).fill()
    for side in [0.0, 180.0] {
        for (i, alpha) in [0.95, 0.7, 0.45].enumerated() {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: s * (0.2 + 0.075 * CGFloat(i)),
                          startAngle: side - 32, endAngle: side + 32)
            arc.lineWidth = s * 0.035
            arc.lineCapStyle = .round
            NSColor.white.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
