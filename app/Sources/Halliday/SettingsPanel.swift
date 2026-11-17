// The full Settings panel (ROADMAP W11 B.5), in Night Glass: the place, then a row per setting
// (board 20: a coloured tile, the setting, its control): space, panel distance, dimming, the
// pointer's speed, the keyboard, sounds, reduce motion. (The browser's settings are beside the browser:
// BrowserSettings.)
// Quick settings above the dock has the first three; this has everything. All of it is kept
// between runs (`Settings`).

import AppKit
import CHallidayCore

@MainActor
final class SettingsPanel: VRPanel {
    private let settings = Settings.shared
    var onClose: (() -> Void)?
    /// The browser's current page, for "use the current page as home".
    var currentPage: (() -> String?)?
    var onNotice: ((String) -> Void)?

    static let distance: Float = 1.2
    static let below: Float = 4

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 620, height: CGFloat = 744
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }
    private var tracks: [String: CGRect] = [:]

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
        onPress = { [weak self] id in if let p = self?.lastPoint { self?.slide(id, to: p) } }
        onDrag = { [weak self] id, p in self?.slide(id, to: p) }
        setNeedsDisplay()
    }

    private func activate(_ id: String) {
        switch id {
        case "close": onClose?()
        case "mode:seated": settings.mode = .seated
        case "mode:roomScale": settings.mode = .roomScale
        case "identity:vision": setIdentity(true)
        case "identity:mac": setIdentity(false)
        case "home:start": settings.homePage = ""
        case "home:current":
            if let page = currentPage?(), page.hasPrefix("http") { settings.homePage = page } else { onNotice?("Open the page you want as home in the browser first") }
        case "history:clear":
            BrowserHistory.shared.clearHistory()
            onNotice?("The browser's history was cleared")
        case "keyboard:auto": settings.keyboardAuto.toggle()
        case "motion:reduce": settings.reduceMotion.toggle()
        case "environment:folder": NSWorkspace.shared.open(Environments.folder)
        case "environment:prev": placePage = max(0, placePage - 1)
        case "environment:next": placePage += 1
        default:
            if id.hasPrefix("place:") { settings.environment = String(id.dropFirst(6)) }
        }
        setNeedsDisplay()
    }

    /// The places offered, re-read each time the panel opens (images come and go in the folder).
    private var places = Environments.all()
    private var placePage = 0

    func reload() {
        places = Environments.all()
        placePage = 0
        setNeedsDisplay()
    }

    private func setIdentity(_ vision: Bool) {
        guard settings.visionIdentity != vision else { return }
        settings.visionIdentity = vision
        onNotice?("Sites will see \(vision ? "an Apple Vision Pro" : "a Mac") in tabs opened after the browser is reopened")
    }

    private func slide(_ id: String, to p: CGPoint) {
        guard let track = tracks[id] else { return }
        let t = Float(max(0, min(1, (p.x - track.minX) / track.width)))
        func value(_ r: ClosedRange<Float>) -> Float { r.lowerBound + t * (r.upperBound - r.lowerBound) }
        switch id {
        case "distance": settings.panelDistance = (value(Settings.panelDistanceRange) * 10).rounded() / 10
        case "dimming": settings.dimming = (value(Settings.dimmingRange) * 20).rounded() / 20
        case "speed": settings.pointerSpeed = (value(Settings.pointerSpeedRange) * 10).rounded() / 10
        case "sound":
            let before = settings.soundVolume
            settings.soundVolume = (t * 10).rounded() / 10
            if settings.soundVolume != before { Sounds.play(.release) } // hear the level being set
        default: return
        }
        setNeedsDisplay()
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let x = g.minX + 28, w = g.width - 56
        // The header (board 20): the title and whose settings these are.
        NightGlass.drawText("Settings", at: CGPoint(x: x, y: g.minY + 18), style: .title)
        NightGlass.drawText("Halliday, on this Mac", at: CGPoint(x: x, y: g.minY + 50), style: .caption, color: NightGlass.secondary)
        let close = CGRect(x: g.maxX - 60, y: g.minY + 18, width: 40, height: 40)
        iconButton(ctx, "close", "xmark", close, symbolSize: 14, quiet: true)
        var y = g.minY + 86

        // The place: a row of places, five at a time.
        y = section(ctx, "Place", x: x, y: y)
        let perPage = 5, gap: CGFloat = 10
        let pages = max(1, (places.count + perPage - 1) / perPage)
        placePage = min(placePage, pages - 1)
        let tile = (w - CGFloat(perPage - 1) * gap) / CGFloat(perPage)
        for (k, place) in places.dropFirst(placePage * perPage).prefix(perPage).enumerated() {
            let id = "place:\(place.id)"
            let rect = CGRect(x: x + CGFloat(k) * (tile + gap), y: y, width: tile, height: 92)
            control(id, rect)
            let chosen = settings.environment == place.id
            let swatch = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 60)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: swatch, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.clip()
            let colors = [place.swatch.0.cgColor, place.swatch.1.cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0.15, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: swatch.minY), end: CGPoint(x: 0, y: swatch.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            if let file = place.file {
                let scene = Environments.sceneExtensions.contains(file.pathExtension.lowercased())
                NightGlass.drawSymbol(scene ? "cube" : "photo", in: swatch, size: 18, color: NSColor(white: 1, alpha: 0.8))
            }
            ctx.restoreGState()
            if chosen || hovered == id {
                ctx.addPath(CGPath(roundedRect: swatch.insetBy(dx: 1, dy: 1), cornerWidth: 13, cornerHeight: 13, transform: nil))
                ctx.setStrokeColor((chosen ? NightGlass.accent : NSColor(white: 1, alpha: 0.5)).cgColor)
                ctx.setLineWidth(2)
                ctx.strokePath()
            }
            let size = NightGlass.textSize(place.name, style: .caption)
            NightGlass.drawText(place.name, at: CGPoint(x: rect.midX - min(size.width, tile) / 2, y: swatch.maxY + 8), style: .caption,
                                color: chosen ? NightGlass.text : NightGlass.secondary, width: tile)
        }
        y += 100
        // Your own 360° images: the folder, and paging when there are more than five places.
        let folderLabel = "Add 360° images…"
        let fw = NightGlass.textSize(folderLabel, style: .label).width + 28
        button(ctx, "environment:folder", folderLabel, CGRect(x: x, y: y, width: fw, height: 36))
        if pages > 1 {
            button(ctx, "environment:next", "›", CGRect(x: x + w - 44, y: y, width: 44, height: 36))
            button(ctx, "environment:prev", "‹", CGRect(x: x + w - 96, y: y, width: 44, height: 36))
        }
        y += 52

        // The rest as rows (board 20): a coloured tile, the setting, its control on the right.
        func fraction(_ v: Float, _ r: ClosedRange<Float>) -> CGFloat { CGFloat((v - r.lowerBound) / (r.upperBound - r.lowerBound)) }
        let rx = g.minX + 14, rw = g.width - 28
        y = row(ctx, "Space", "figure.stand", (0x5FD6C4, 0x1C8C86), ids: ["mode:seated", "mode:roomScale"], x: rx, y: y, width: rw) { r in
            _ = self.segmented(ctx, [("mode:seated", "Seated", self.settings.mode == .seated), ("mode:roomScale", "Room-scale", self.settings.mode == .roomScale)],
                               x: r.maxX - 14 - 270, y: r.midY - 22, width: 270)
        }
        y = sliderRow(ctx, "distance", "Panel distance", "arrow.left.and.right", (0x7FD3FF, 0x2A7FBF), String(format: "%.1f m", settings.panelDistance),
                      fraction(settings.panelDistance, Settings.panelDistanceRange), x: rx, y: y, width: rw)
        y = sliderRow(ctx, "dimming", "Dimming", "moon", (0x9AA6FF, 0x4A55C9), "\(Int((settings.dimming * 100).rounded()))%",
                      fraction(settings.dimming, Settings.dimmingRange), x: rx, y: y, width: rw)
        y = sliderRow(ctx, "speed", "Pointer speed", "cursorarrow.motionlines", (0x6FA8FF, 0x2D58D8), String(format: "%.1f×", settings.pointerSpeed),
                      fraction(settings.pointerSpeed, Settings.pointerSpeedRange), x: rx, y: y, width: rw)
        y = row(ctx, "Keyboard for text fields", "keyboard", (0x8FE39B, 0x2E9E5C), ids: ["keyboard:auto"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "keyboard:auto", self.settings.keyboardAuto, CGRect(x: r.maxX - 14 - 60, y: r.midY - 17, width: 60, height: 34))
        }
        y = sliderRow(ctx, "sound", "Sounds", "speaker.wave.2", (0xFF8FC2, 0xC9407F),
                      settings.soundVolume < 0.01 ? "Off" : "\(Int((settings.soundVolume * 100).rounded()))%", CGFloat(settings.soundVolume), x: rx, y: y, width: rw)
        _ = row(ctx, "Reduce motion", "sparkles", (0xB79BFF, 0x6A47D6), ids: ["motion:reduce"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "motion:reduce", self.settings.reduceMotion, CGRect(x: r.maxX - 14 - 60, y: r.midY - 17, width: 60, height: 34))
        }

        let version = "Halliday · core \(String(cString: halliday_core_version()))"
        NightGlass.drawText(version, at: CGPoint(x: x, y: g.maxY - 30), style: .caption, color: NightGlass.tertiary)
    }

    private static let rowHeight: CGFloat = 56

    /// One row (board 20): lit under the pointer when it is on one of its controls, a coloured
    /// tile, the title, and what `trailing` draws at its right end. Returns the next row's top.
    private func row(_ ctx: CGContext, _ title: String, _ symbol: String, _ colors: (UInt32, UInt32), ids: [String],
                     x: CGFloat, y: CGFloat, width: CGFloat, trailing: (CGRect) -> Void) -> CGFloat {
        let r = CGRect(x: x, y: y, width: width, height: Self.rowHeight)
        if let h = hovered, ids.contains(h) { NightGlass.fill(ctx, r, radius: 16, color: NSColor(white: 1, alpha: 0.06)) }
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        NightGlass.drawAppTile(ctx, CGRect(x: r.minX + 14, y: r.midY - 17, width: 34, height: 34), radius: 10, colors: (c(colors.0), c(colors.1)),
                               symbol: symbol, symbolSize: 16)
        let size = NightGlass.textSize(title, style: .body)
        NightGlass.drawText(title, at: CGPoint(x: r.minX + 62, y: r.midY - size.height / 2), style: .body)
        trailing(r)
        return y + Self.rowHeight + 4
    }

    /// A row with a slider and its value at the right end.
    private func sliderRow(_ ctx: CGContext, _ id: String, _ title: String, _ symbol: String, _ colors: (UInt32, UInt32), _ value: String,
                           _ fraction: CGFloat, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        row(ctx, title, symbol, colors, ids: [id], x: x, y: y, width: width) { r in
            let valueSize = NightGlass.textSize(value, style: .label, tabular: true)
            NightGlass.drawText(value, at: CGPoint(x: r.maxX - 14 - valueSize.width, y: r.midY - valueSize.height / 2), style: .label,
                                color: NightGlass.secondary, tabular: true)
            let start = r.minX + 230, end = r.maxX - 14 - 64
            self.tracks[id] = self.slider(ctx, id, row: CGRect(x: start, y: r.midY - 20, width: end - start, height: 40), fraction: fraction)
        }
    }

    private func section(_ ctx: CGContext, _ title: String, x: CGFloat, y: CGFloat) -> CGFloat {
        NightGlass.drawSection(title, at: CGPoint(x: x, y: y - 2))
        return y + 24
    }




}
