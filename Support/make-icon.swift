// Tegner app-ikonet (samme motiv som Android-ikonet: fjell og to høstblader på mørk grønn bakgrunn).
// Bruk: swift Support/make-icon.swift <utfil.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// macOS-ikonrutenett: avrundet kvadrat på 824 px midt i 1024
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(color(0x132B29))
ctx.fillPath()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 6, dy: 6), cornerWidth: 180, cornerHeight: 180, transform: nil))
ctx.setStrokeColor(color(0xAB9977))
ctx.setLineWidth(8)
ctx.strokePath()

// Android-motivet er tegnet i et 108×108-rutenett med y nedover
let scale = body.width / 84
let ox = body.midX - 57 * scale
let oy = body.midY + 50 * scale
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy - y * scale) }

func poly(_ pts: [(CGFloat, CGFloat)], _ hex: UInt32) {
    ctx.beginPath()
    ctx.move(to: p(pts[0].0, pts[0].1))
    for q in pts.dropFirst() { ctx.addLine(to: p(q.0, q.1)) }
    ctx.closePath()
    ctx.setFillColor(color(hex))
    ctx.fillPath()
}

func leaf(_ start: (CGFloat, CGFloat), _ c1: [(CGFloat, CGFloat)], _ c2: [(CGFloat, CGFloat)], _ hex: UInt32) {
    ctx.beginPath()
    ctx.move(to: p(start.0, start.1))
    ctx.addCurve(to: p(c1[2].0, c1[2].1), control1: p(c1[0].0, c1[0].1), control2: p(c1[1].0, c1[1].1))
    ctx.addCurve(to: p(c2[2].0, c2[2].1), control1: p(c2[0].0, c2[0].1), control2: p(c2[1].0, c2[1].1))
    ctx.closePath()
    ctx.setFillColor(color(hex))
    ctx.fillPath()
}

// Fjell
poly([(26, 72), (54, 32), (82, 72)], 0xC2D9D4)
poly([(54, 32), (82, 72), (62, 72), (58, 52)], 0xAB9977)
poly([(54, 32), (61, 42), (54, 40), (47, 42)], 0xFFFFFF)
// Høstblad
leaf((74, 30), [(82, 28), (88, 34), (86, 42)], [(78, 44), (72, 38), (74, 30)], 0xD6924C)
leaf((30, 44), [(36, 40), (42, 44), (41, 50)], [(35, 52), (29, 49), (30, 44)], 0x9E555B)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Skrev \(out)")
