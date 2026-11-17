// The installer window's picture (board 21, "Night, all space"): deep space, stars, a faint
// violet and teal glow, and the Milky Way's band across the window where Finder writes the
// icons' names, a middle tone on which its black (light mode) and white (dark mode) names
// both read at about 4.5 : 1. The arrow and the line saying what to do are in the picture; the
// icons and their names are Finder's own, placed by tools/make-dmg.sh at (180, 180) and
// (460, 180) in a 640 × 400 window.
//
//     swiftc tools/dmg-background.swift -o build/dmg-background && build/dmg-background OUT.png SCALE
//
// SCALE 1 or 2; tools/make-dmg.sh joins both into one TIFF (tiffutil -cathidpicheck).

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]) else {
    FileHandle.standardError.write("usage: dmg-background OUT.png SCALE\n".data(using: .utf8)!)
    exit(2)
}
let W = 640.0, H = 400.0
let px = Int(W * scale), py = Int(H * scale)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Points, origin at the top left, y down (as the board is drawn).
ctx.translateBy(x: 0, y: CGFloat(py))
ctx.scaleBy(x: scale, y: -scale)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

// Deep space.
ctx.drawLinearGradient(gradient([(0, rgb(0x04050C)), (0.5, rgb(0x070A18)), (1, rgb(0x05060E))]),
                       start: .zero, end: CGPoint(x: 0, y: H), options: [])

// Two faint glows: violet at the top right, teal at the bottom left.
func glow(_ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ color: UInt32, _ alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: 1, y: ry / rx)
    ctx.drawRadialGradient(gradient([(0, rgb(color, alpha)), (0.7, rgb(color, 0))]), startCenter: .zero, startRadius: 0,
                           endCenter: .zero, endRadius: rx, options: [])
    ctx.restoreGState()
}
glow(CGPoint(x: W * 0.85, y: H * 0.10), 448, 240, 0x5C46A0, 0.30)
glow(CGPoint(x: W * 0.08, y: H * 0.92), 320, 180, 0x28788C, 0.22)

// Stars, the same every time.
var seed: UInt64 = 0x48616C6C69646179
func random() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(1 << 31)
}
func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: CGFloat) {
    ctx.setFillColor(rgb(0xFFFFFF, a))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
for _ in 0..<150 {
    let x = random() * W, y = random() * H
    let bright = random()
    star(x, y, bright > 0.92 ? 0.9 : 0.5, 0.25 + 0.65 * bright)
}

// The Milky Way's band, turned 3° up to the right about the window's middle, under the names.
ctx.saveGState()
ctx.translateBy(x: W / 2, y: 256)
ctx.rotate(by: -3 * .pi / 180)
let band = CGRect(x: -W / 2 - 60, y: -70, width: W + 120, height: 140)
let tone = (0x666C88 as UInt32)
// Flat across the names, fading softly at its edges (a super-Gaussian across the band).
let profile: [(CGFloat, CGColor)] = (0...32).map { i in
    let t = CGFloat(i) / 32
    let a = 0.93 * exp(-pow(abs(t - 0.52) / 0.27, 4))
    return (t, rgb(tone, a))
}
ctx.drawLinearGradient(gradient(profile), start: CGPoint(x: 0, y: band.minY), end: CGPoint(x: 0, y: band.maxY), options: [])
// Darker dust lanes along its edges, kept off the middle where the names are.
for _ in 0..<22 {
    let x = band.minX + random() * band.width
    let side: CGFloat = random() > 0.5 ? 1 : -1
    let y = side * (30 + random() * 14)
    let r = 40 + random() * 60
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.scaleBy(x: 1, y: 0.3)
    ctx.drawRadialGradient(gradient([(0, rgb(0x0A0C18, 0.16)), (1, rgb(0x0A0C18, 0))]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
    ctx.restoreGState()
}
// Its dust: many faint stars, thicker toward the middle.
for _ in 0..<420 {
    let x = band.minX + random() * band.width
    let t = (random() + random() + random()) / 3
    let y = band.minY + t * band.height
    star(x, y, random() > 0.95 ? 0.7 : 0.4, 0.15 + 0.45 * random())
}
ctx.restoreGState()

// The arrow from Halliday to Applications.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.85))
ctx.setLineWidth(2.5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 266, y: 180)); ctx.addLine(to: CGPoint(x: 370, y: 180))
ctx.move(to: CGPoint(x: 358, y: 171)); ctx.addLine(to: CGPoint(x: 370, y: 180)); ctx.addLine(to: CGPoint(x: 358, y: 189))
ctx.strokePath()

// What to do.
let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
NSGraphicsContext.current = ns
let text = NSAttributedString(string: "Drag Halliday into Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(white: 1, alpha: 0.86),
    .kern: 0.15,
])
let size = text.size()
text.draw(at: CGPoint(x: (W - size.width) / 2, y: 40))
NSGraphicsContext.current = nil

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: W, height: H)  // 144 dpi at 2×, so Finder takes it as the Retina picture
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
