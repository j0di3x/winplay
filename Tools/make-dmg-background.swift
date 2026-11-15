// Draws the .dmg window background (arrow from the app to Applications + tagline).
// Run: swift Tools/make-dmg-background.swift Resources/dmg-background.tiff
// The window is 640×420 points; icons sit at (170, 190) and (470, 190).
import AppKit

let W: CGFloat = 640, H: CGFloat = 420

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // background: light warm grey (Finder draws icon labels in black, so keep it light)
    NSGradient(colors: [NSColor(red: 0.985, green: 0.975, blue: 0.965, alpha: 1),
                        NSColor(red: 0.925, green: 0.910, blue: 0.895, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    let glowCentre = NSPoint(x: W / 2, y: H - 190)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 1.0, alpha: 0.16), NSColor(red: 1, green: 0.55, blue: 0.2, alpha: 0)])!
        .draw(fromCenter: glowCentre, radius: 0, toCenter: glowCentre, radius: 230, options: [])
    // thin orange accent along the top edge
    NSColor(red: 0.36, green: 0.40, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: H - 5, width: W, height: 5).fill()

    // headline (Finder's y axis is top-down; AppKit's is bottom-up)
    let title = NSMutableParagraphStyle(); title.alignment = .center
    let headline = "Play your Windows games on your Mac."
    headline.draw(in: NSRect(x: 20, y: H - 74, width: W - 40, height: 34), withAttributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor(white: 0.11, alpha: 1), .paragraphStyle: title])
    "Drag WinPlay onto Applications".draw(in: NSRect(x: 20, y: H - 102, width: W - 40, height: 22), withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(white: 0.35, alpha: 1), .paragraphStyle: title])

    // arrow between the two icons (icon centres at y = 190 from the top → 230 from the bottom)
    let y = H - 190
    let orange = NSColor(red: 0.36, green: 0.40, blue: 0.98, alpha: 1)
    orange.setStroke(); orange.setFill()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 252, y: y)); shaft.line(to: NSPoint(x: 372, y: y))
    shaft.lineWidth = 9; shaft.lineCapStyle = .round
    let dash: [CGFloat] = [2, 16]; shaft.setLineDash(dash, count: 2, phase: 0)
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 394, y: y))
    head.line(to: NSPoint(x: 366, y: y + 20))
    head.line(to: NSPoint(x: 366, y: y - 20))
    head.close(); head.fill()

    // footer
    "First launch: right-click WinPlay and choose Open".draw(in: NSRect(x: 20, y: 40, width: W - 40, height: 18), withAttributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 0.30, alpha: 1), .paragraphStyle: title])
    "Free and open source · github.com/j0di3x/winplay".draw(in: NSRect(x: 20, y: 20, width: W - 40, height: 16), withAttributes: [
        .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor(white: 0.5, alpha: 1), .paragraphStyle: title])

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/dmg-background.tiff"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
let one = tmp.appendingPathComponent("bg.png"), two = tmp.appendingPathComponent("bg@2x.png")
try! render(scale: 1).representation(using: .png, properties: [:])!.write(to: one)
try! render(scale: 2).representation(using: .png, properties: [:])!.write(to: two)
// combine 1x + 2x into one HiDPI-aware TIFF that Finder picks the right size from
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
p.arguments = ["-cathidpicheck", one.path, two.path, "-out", out]
try! p.run(); p.waitUntilExit()
print("Wrote \(out)")
