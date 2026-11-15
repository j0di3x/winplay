// Draws the WinPlay icon (a play symbol in an app window on a blue-violet tile) -> Resources/AppIcon.icns
// Run: swift Tools/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.33, green: 0.56, blue: 1.0, alpha: 1),
                        NSColor(red: 0.42, green: 0.25, blue: 0.86, alpha: 1)])!.draw(in: tile, angle: -60)
    // app window outline with a title bar
    let white = NSColor(white: 1, alpha: 0.96)
    white.setStroke(); white.setFill()
    let win = NSRect(x: 230 * s, y: 270 * s, width: 564 * s, height: 470 * s)
    let frame = NSBezierPath(roundedRect: win, xRadius: 56 * s, yRadius: 56 * s)
    frame.lineWidth = 46 * s; frame.stroke()
    let bar = NSBezierPath(); bar.move(to: NSPoint(x: win.minX, y: win.maxY - 110 * s)); bar.line(to: NSPoint(x: win.maxX, y: win.maxY - 110 * s))
    bar.lineWidth = 40 * s; bar.stroke()
    for i in 0..<3 {
        let c = NSPoint(x: win.minX + (82 + CGFloat(i) * 62) * s, y: win.maxY - 55 * s)
        NSBezierPath(ovalIn: NSRect(x: c.x - 18 * s, y: c.y - 18 * s, width: 36 * s, height: 36 * s)).fill()
    }
    // play triangle
    let cx = win.midX + 10 * s, cy = win.minY + (win.height - 110 * s) / 2
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: cx - 80 * s, y: cy + 110 * s))
    tri.line(to: NSPoint(x: cx + 110 * s, y: cy))
    tri.line(to: NSPoint(x: cx - 80 * s, y: cy - 110 * s))
    tri.close(); tri.lineJoinStyle = .round; tri.lineWidth = 30 * s
    tri.fill(); tri.stroke()
    img.unlockFocus()
    return img
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WinPlay.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(data: render(px).tiffRepresentation!)!
        rep.size = NSSize(width: px, height: px)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
