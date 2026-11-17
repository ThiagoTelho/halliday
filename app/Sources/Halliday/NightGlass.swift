// Night Glass: Halliday's VR design system (ROADMAP W11.B). The reference design is the canvas
// "Halliday VR UI" (docs/ui.md links it); this file is its code form: colors, sizes and the drawing
// pieces every Halliday-drawn panel uses.
//
// Sizes are in dmm: one millimeter seen from one meter away. A panel's size in dmm is an angle, so a
// panel at 2 m is twice as large in meters as at 1 m and its buttons look the same size.

import AppKit

enum NightGlass {
    // --- Color ---
    /// The glass's tint. The place behind it shows through, blurred (the renderer does that where a
    /// panel declares its glass: `VRPanel.drawGlass`); over a window the renderer makes it denser.
    static let glass = NSColor(srgbRed: 20 / 255, green: 22 / 255, blue: 30 / 255, alpha: 0.52)
    /// The tint of large panels full of text (lists, settings).
    static let solidGlass = NSColor(srgbRed: 20 / 255, green: 22 / 255, blue: 30 / 255, alpha: 0.78)
    /// Something needs attention (a problem, a limit reached).
    static let warning = NSColor(srgbRed: 0xF0 / 255, green: 0xA0 / 255, blue: 0x4B / 255, alpha: 1)
    static let hairline = NSColor(white: 1, alpha: 0.12)
    static let rim = NSColor(white: 1, alpha: 0.10)
    static let text = NSColor(srgbRed: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF7 / 255, alpha: 1)
    static let secondary = NSColor(srgbRed: 0xA9 / 255, green: 0xAE / 255, blue: 0xBD / 255, alpha: 1)
    static let tertiary = NSColor(srgbRed: 0x8A / 255, green: 0x90 / 255, blue: 0xA0 / 255, alpha: 1)
    static let disabled = NSColor(srgbRed: 0x5E / 255, green: 0x64 / 255, blue: 0x75 / 255, alpha: 1)
    /// Actions that end something (quit a game): soft coral, never the accent (design board 14).
    static let danger = NSColor(srgbRed: 0xFF / 255, green: 0xA3 / 255, blue: 0x99 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 0x8A / 255, green: 0xB4 / 255, blue: 0xFF / 255, alpha: 1)
    static let privateTint = NSColor(srgbRed: 0xB6 / 255, green: 0x9C / 255, blue: 0xFF / 255, alpha: 1)
    static let chip = NSColor(srgbRed: 236 / 255, green: 238 / 255, blue: 244 / 255, alpha: 0.96)
    static let chipText = NSColor(srgbRed: 0x16 / 255, green: 0x18 / 255, blue: 0x1F / 255, alpha: 1)
    /// Fill of a control under the pointer, and while pressed.
    static let hoverFill = NSColor(white: 1, alpha: 0.12)
    static let pressFill = NSColor(white: 1, alpha: 0.20)
    /// "Lifted" surfaces: the active tab, a selected segment.
    static let lifted = NSColor(white: 1, alpha: 0.13)

    /// The accent as linear-ish shader values (the eye buffer is not sRGB-encoded, so these are the
    /// same numbers as the sRGB color).
    static let accentRGB = SIMD3<Float>(0x8A / 255, 0xB4 / 255, 1)

    /// Dates in Halliday's own panels are written in the language of its interface (English) or,
    /// if the user prefers another for apps, in that one, rather than in the region's language.
    static var dateLocale: Locale { Locale(identifier: Locale.preferredLanguages.first ?? "en") }

    // --- Shape ---
    static let panelRadius: CGFloat = 28
    static let cardRadius: CGFloat = 14

    // --- Type (dmm) ---
    enum TextStyle {
        case display, title, body, label, caption
        var size: CGFloat {
            switch self {
            case .display: 28
            case .title: 20
            case .body: 16
            case .label: 14
            case .caption: 12
            }
        }
        var weight: NSFont.Weight {
            switch self {
            case .display: .bold
            case .title: .semibold
            case .body: .regular
            case .label: .medium
            case .caption: .regular
            }
        }
    }

    /// Meters for `dmm` at `distance` meters.
    static func meters(_ dmm: CGFloat, at distance: Float) -> Float { Float(dmm) / 1000 * distance }

    // --- Drawing (in a flipped context whose units are dmm) ---

    /// A Night Glass surface: dark translucent fill, hairline edge and a light rim along the top.
    /// `solid`: for large panels that sit over other content (lists, settings), nearly opaque so
    /// what is behind doesn't show through the text.
    static func drawGlass(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, solid: Bool = false) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // No drop shadow: CoreGraphics takes tens of milliseconds to blur one around a large panel,
        // on every redraw, and it hardly shows against the dark environment.
        ctx.addPath(path)
        ctx.setFillColor((solid ? solidGlass : glass).cgColor)
        ctx.fillPath()
        // Light from above (board 19): a soft highlight over the top third, strongest at the edge.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = [rim.cgColor, NSColor(white: 1, alpha: 0.03).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.35, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.minY + rect.height * 0.34), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
        ctx.setStrokeColor(hairline.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        // Edge light: the top edge catches the light, brightest in the middle.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(radius, rect.height / 2)))
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius - 0.75, cornerHeight: radius - 0.75, transform: nil))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let edge = [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 0.34).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: edge, locations: [0.04, 0.5, 0.96]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
        }
        ctx.restoreGState()
    }

    static func fill(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, color: NSColor) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.height / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    nonisolated(unsafe) private static var fontCache: [String: NSFont] = [:]

    /// `tabular`: digits all of one width, for numbers that change in place (clocks, times, values).
    static func font(_ style: TextStyle, weight: NSFont.Weight? = nil, tabular: Bool = false) -> NSFont {
        let w = weight ?? style.weight
        let key = "\(style.size)|\(w.rawValue)|\(tabular)"
        if let f = fontCache[key] { return f }
        let f = tabular ? NSFont.monospacedDigitSystemFont(ofSize: style.size, weight: w) : NSFont.systemFont(ofSize: style.size, weight: w)
        fontCache[key] = f
        return f
    }

    // Text is laid out once and kept (a CoreText line per string, style, color and width): laying
    // out a panel's twenty-odd strings again on every redraw took most of the redraw's time.
    private struct Line {
        let line: CTLine
        let size: CGSize
        let ascent: CGFloat
    }

    nonisolated(unsafe) private static var lineCache: [String: Line] = [:]

    private static func line(_ s: String, style: TextStyle, weight: NSFont.Weight?, color: NSColor, width: CGFloat?, tabular: Bool = false) -> Line {
        let key = "\(s)|\(style.size)|\((weight ?? style.weight).rawValue)|\(color.description)|\(width.map { Int($0) } ?? -1)|\(tabular)"
        if let cached = lineCache[key] { return cached }
        if lineCache.count > 3000 { lineCache.removeAll() } // clocks and timecodes keep making new strings
        let f = font(style, weight: weight, tabular: tabular)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
        var lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if let width, lineWidth > width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            if let cut = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) {
                line = cut
                lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
        // The line box AppKit uses for this font, so text sits where it did before.
        let height = ceil(f.ascender - f.descender + f.leading)
        let made = Line(line: line, size: CGSize(width: ceil(lineWidth), height: height), ascent: f.ascender)
        lineCache[key] = made
        return made
    }

    /// Text with its top-left at `origin`, truncated to `width` if given. Returns its size.
    @discardableResult
    static func drawText(_ s: String, at origin: CGPoint, style: TextStyle, color: NSColor = text,
                         weight: NSFont.Weight? = nil, width: CGFloat? = nil, tabular: Bool = false) -> CGSize {
        let l = line(s, style: style, weight: weight, color: color, width: width, tabular: tabular)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return l.size }
        // The panel's context is flipped (y down): glyphs are flipped back, baseline below the top.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: origin.x, y: origin.y + l.ascent)
        CTLineDraw(l.line, ctx)
        return l.size
    }

    static func textSize(_ s: String, style: TextStyle, weight: NSFont.Weight? = nil, tabular: Bool = false) -> CGSize {
        line(s, style: style, weight: weight, color: text, width: nil, tabular: tabular).size
    }

    /// `s` broken into lines no wider than `width`, at spaces.
    static func wrap(_ s: String, style: TextStyle, width: CGFloat) -> [String] {
        var lines: [String] = [], current = ""
        for word in s.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if !current.isEmpty, textSize(candidate, style: style).width > width {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    nonisolated(unsafe) private static var symbolCache: [String: (image: CGImage, size: CGSize)] = [:]

    /// An SF Symbol centered in `rect`, `size` dmm tall, in `color`.
    static func drawSymbol(_ name: String, in rect: CGRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        // Symbols are rendered once into a bitmap at the panel's pixel density and kept: configuring
        // and drawing an NSImage symbol takes about a millisecond, and a panel draws a dozen.
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color.description)"
        let symbol: (image: CGImage, size: CGSize)
        if let cached = symbolCache[key] {
            symbol = cached
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            let scale: CGFloat = 2 // VRPanel.pixelsPerDmm
            let w = Int(ceil(image.size.width * scale)), h = Int(ceil(image.size.height * scale))
            guard w > 0, h > 0, let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let saved = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current = saved
            guard let made = bitmap.makeImage() else { return }
            symbol = (made, CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
            symbolCache[key] = symbol
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = CGRect(x: (rect.midX - symbol.size.width / 2).rounded(.toNearestOrEven) , y: rect.midY - symbol.size.height / 2,
                       width: symbol.size.width, height: symbol.size.height)
        // The panel's context is flipped: the bitmap is drawn upright.
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(symbol.image, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// The light label chip (tooltips), centered above `anchorX`, bottom at `bottom`.
    static func drawChip(_ ctx: CGContext, _ s: String, centerX: CGFloat, bottom: CGFloat) {
        let size = textSize(s, style: .label, weight: .semibold)
        let rect = CGRect(x: centerX - size.width / 2 - 14, y: bottom - 32, width: size.width + 28, height: 32)
        fill(ctx, rect, radius: 16, color: chip)
        drawText(s, at: CGPoint(x: rect.minX + 14, y: rect.midY - size.height / 2), style: .label, color: chipText, weight: .semibold)
    }

    // --- Refined (design board 19) ---

    /// Each of Halliday's own apps has a colour: its tile's gradient, top to bottom. The accent
    /// stays for focus and selection.
    static func appColors(_ id: String) -> (NSColor, NSColor)? {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch id {
        case "halliday:browser": return (c(0x6FA8FF), c(0x2D58D8))
        case "halliday:files": return (c(0x5FD6C4), c(0x1C8C86))
        case "halliday:videos": return (c(0xFF8A7A), c(0xD2434F))
        case "halliday:photos": return (c(0xFFC870), c(0xE0882A))
        case "halliday:music": return (c(0xFF8FC2), c(0xC9407F))
        case "halliday:games": return (c(0xB79BFF), c(0x6A47D6))
        case "halliday:notes": return (c(0xFFD86B), c(0xC9961E))
        case "halliday:clock": return (c(0x7FD3FF), c(0x2A7FBF))
        case "halliday:windows": return (c(0x9AA6FF), c(0x4A55C9))
        case "halliday:settings": return (c(0xB4BACB), c(0x5D6478))
        case "halliday:controls": return (c(0x8FE39B), c(0x2E9E5C))
        default: return nil
        }
    }

    /// A lit glass tile: the colours' gradient, light along its top edge, a soft shadow drawn as a
    /// shape (no CoreGraphics blur), and the symbol in white.
    static func drawAppTile(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, colors: (NSColor, NSColor), symbol: String?, symbolSize: CGFloat) {
        // A soft shadow of the tile's own colour under it (board 19: lit tiles glow a little
        // below), in layers: a hard offset copy showed as a dark notch at the tile's edge.
        let low = rect.offsetBy(dx: 0, dy: 5).insetBy(dx: 4, dy: 4)
        for k in 0..<5 {
            let d = CGFloat(k) * 2.2
            fill(ctx, low.insetBy(dx: -d, dy: -d), radius: radius - 4 + d, color: colors.1.withAlphaComponent(0.10 - CGFloat(k) * 0.016))
        }
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [colors.0.cgColor, colors.1.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX * 0.3 + rect.minX * 0.7, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        // Light along the top edge, and a darker one along the bottom.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: radius))
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius - 0.75, cornerHeight: radius - 0.75, transform: nil))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.45).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()
        if let symbol { drawSymbol(symbol, in: rect, size: symbolSize, color: .white, weight: .semibold) }
    }

    /// A picture's area in a card (board 19's "things to continue are pictures"): the colours'
    /// gradient, darker, with the symbol large and faint, and the app's name in a chip.
    static func drawPictureArea(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, colors: (NSColor, NSColor), symbol: String, chipText: String) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let a = colors.0.blended(withFraction: 0.55, of: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.08, alpha: 1)) ?? colors.0
        let b = colors.1.blended(withFraction: 0.78, of: NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)) ?? colors.1
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        drawSymbol(symbol, in: CGRect(x: rect.maxX - 74, y: rect.midY - 22, width: 64, height: 56), size: 34, color: NSColor(white: 1, alpha: 0.30), weight: .medium)
        ctx.restoreGState()
        let s = textSize(chipText, style: .caption, weight: .semibold)
        let chip = CGRect(x: rect.minX + 10, y: rect.minY + 10, width: s.width + 18, height: 22)
        fill(ctx, chip, radius: 11, color: NSColor(srgbRed: 0.04, green: 0.03, blue: 0.06, alpha: 0.55))
        drawText(chipText, at: CGPoint(x: chip.minX + 9, y: chip.midY - s.height / 2), style: .caption, color: .white, weight: .semibold)
    }

    /// A section's name (board 19: sentence case, not capitals).
    static func drawSection(_ s: String, at origin: CGPoint) {
        drawText(s, at: origin, style: .label, color: NSColor(srgbRed: 0xE4 / 255, green: 0xE6 / 255, blue: 0xEE / 255, alpha: 1), weight: .semibold)
    }

    /// The lit blue of main controls (board 20), top and bottom; brighter under the pointer.
    static let litTop = NSColor(srgbRed: 0x86 / 255, green: 0xB2 / 255, blue: 1, alpha: 1)
    static let litBottom = NSColor(srgbRed: 0x3F / 255, green: 0x6F / 255, blue: 0xE6 / 255, alpha: 1)

    /// A rounded shape filled with a gradient, top to bottom (`vertical`) or left to right.
    static func fillGradient(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, _ a: NSColor, _ b: NSColor, vertical: Bool = true) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.height / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY),
                                   end: vertical ? CGPoint(x: rect.minX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }
        ctx.restoreGState()
    }

    /// Light along a shape's top edge (board 20: every control catches the light from above).
    static func topLight(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, alpha: CGFloat) {
        let r = min(radius, rect.height / 2)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(r, 2)))
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: max(r - 0.75, 0), cornerHeight: max(r - 0.75, 0), transform: nil))
        ctx.setStrokeColor(NSColor(white: 1, alpha: alpha).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A soft glow around a shape, drawn as a few widening fills (no CoreGraphics blur).
    static func glow(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, color: NSColor, strength: CGFloat) {
        for k in 1...4 {
            let d = CGFloat(k) * 2.5
            fill(ctx, rect.insetBy(dx: -d, dy: -d), radius: radius + d, color: color.withAlphaComponent(strength * 0.09 / CGFloat(k)))
        }
    }
}
