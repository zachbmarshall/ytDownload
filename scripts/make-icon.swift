// Draws the app icon and writes an .iconset folder. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded-square background with a red gradient.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
    NSGradient(starting: NSColor(red: 1.0, green: 0.32, blue: 0.30, alpha: 1),
               ending: NSColor(red: 0.78, green: 0.05, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)

    // Down arrow.
    let cx = s / 2
    let arrow = NSBezierPath()
    let w = rect.width
    arrow.move(to: NSPoint(x: cx - w * 0.11, y: rect.maxY - w * 0.2))
    arrow.line(to: NSPoint(x: cx + w * 0.11, y: rect.maxY - w * 0.2))
    arrow.line(to: NSPoint(x: cx + w * 0.11, y: rect.midY + w * 0.02))
    arrow.line(to: NSPoint(x: cx + w * 0.26, y: rect.midY + w * 0.02))
    arrow.line(to: NSPoint(x: cx, y: rect.minY + w * 0.3))
    arrow.line(to: NSPoint(x: cx - w * 0.26, y: rect.midY + w * 0.02))
    arrow.line(to: NSPoint(x: cx - w * 0.11, y: rect.midY + w * 0.02))
    arrow.close()
    NSColor.white.setFill()
    arrow.fill()

    // Tray line under the arrow.
    let tray = NSBezierPath(roundedRect: NSRect(x: cx - w * 0.3, y: rect.minY + w * 0.15, width: w * 0.6, height: w * 0.08),
                            xRadius: w * 0.04, yRadius: w * 0.04)
    tray.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
