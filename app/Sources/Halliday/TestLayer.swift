// A generated test image for the quad-layer path: fine text, a checkerboard and resolution
// wedges show sharpness, aliasing and the layer's aspect ratio.

import AppKit

enum TestLayer {
    static func rgba(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // CoreGraphics draws with y up; flip so row 0 is the top, as Metal expects.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)

            ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            // Checkerboard band.
            let cell = 32
            for y in stride(from: height - 160, to: height - 32, by: cell) {
                for x in stride(from: 32, to: width - 32, by: cell) where ((x / cell) + (y / cell)) % 2 == 0 {
                    ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }

            // Line-pair wedges: 1, 2, 4 and 8 pixel lines.
            for (i, w) in [1, 2, 4, 8].enumerated() {
                let x0 = 32 + i * 220
                for k in stride(from: 0, to: 200, by: w * 2) {
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                    ctx.fill(CGRect(x: x0 + k, y: height - 400, width: w, height: 200))
                }
            }

            // Text, top-down (flip back for AppKit text drawing).
            NSGraphicsContext.saveGraphicsState()
            let nsctx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.current = nsctx
            func draw(_ s: String, size: CGFloat, y: CGFloat, weight: NSFont.Weight = .regular) {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size, weight: weight),
                    .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1),
                ]
                NSAttributedString(string: s, attributes: attrs).draw(at: CGPoint(x: 32, y: y))
            }
            draw("Halliday", size: 96, y: 24, weight: .bold)
            draw("Quad layer test — 1600 × 1000 texture, 1.6 m wide, 2 m away", size: 36, y: 150)
            for (i, size) in [28, 22, 18, 14, 11].enumerated() {
                draw("\(size) pt: The quick brown fox jumps over the lazy dog. 0123456789", size: CGFloat(size), y: 220 + CGFloat(i) * 44)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return pixels
    }
}
