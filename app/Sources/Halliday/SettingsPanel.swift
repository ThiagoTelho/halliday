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
    var onRefreshRate: ((Int) -> Void)?
    var refreshState: (() -> (rates: [Int], current: Int, busy: Bool))?

    static let distance: Float = 1.2
    static let below: Float = 4

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 620, height: CGFloat = 920
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }
    private var tracks: [String: CGRect] = [:]
    private var showingGameImage = false
    private var showingTracking = false
    private var showingFOV = false

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
        case "page:general": showingGameImage = false; showingTracking = false; showingFOV = false
        case "page:gameImage": showingGameImage = true; showingTracking = false; showingFOV = false
        case "page:tracking": showingGameImage = false; showingTracking = true; showingFOV = false
        case "page:fov": showingGameImage = false; showingTracking = false; showingFOV = true
        case "tracking:led": settings.senseLEDFeedback.toggle()
        case "game:fsr": settings.gameFSREnabled.toggle()
        case "game:crop": settings.gameCropEnabled.toggle()
        case "game:sharpening": settings.gameSharpeningEnabled.toggle()
        case "game:half:off": settings.gameHalfFrameRateMode = .off
        case "game:half:on": settings.gameHalfFrameRateMode = .on
        case "game:half:auto": settings.gameHalfFrameRateMode = .auto
        case "game:spacewarp": settings.setGameSpacewarp(!settings.gameSpacewarpEnabled)
        case "game:systemAudio": settings.gameSystemAudio.toggle()
        case "display:90": onRefreshRate?(90)
        case "display:120": onRefreshRate?(120)
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
        case "game:scale": settings.gameRenderPercent = Int((50 + t * 50) / 5 + 0.5) * 5
        case "game:sharpness": settings.gameSharpness = (t * 20).rounded() / 20
        case "game:cropHorizontal", "game:cropVertical":
            guard settings.gameCropEnabled else { return }
            let fraction = ((0.5 + t * 0.5) * 100).rounded() / 100
            if id == "game:cropHorizontal" { settings.gameCropHorizontal = fraction }
            else { settings.gameCropVertical = fraction }
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
        NightGlass.drawText("\(RuntimePaths.displayName), on this Mac", at: CGPoint(x: x, y: g.minY + 50), style: .caption, color: NightGlass.secondary)
        let close = CGRect(x: g.maxX - 60, y: g.minY + 18, width: 40, height: 40)
        iconButton(ctx, "close", "xmark", close, symbolSize: 14, quiet: true)
        var y = g.minY + 86
        tracks.removeAll(keepingCapacity: true)
        y = segmented(ctx, [("page:general", "General", !showingGameImage && !showingTracking && !showingFOV),
                            ("page:gameImage", "Game image", showingGameImage),
                            ("page:tracking", "Tracking", showingTracking),
                            ("page:fov", "FOV", showingFOV)], x: x, y: y, width: w)
        y += 4
        animates = showingTracking
        if showingFOV {
            drawFOV(ctx, x: x, y: y, width: w)
            drawVersion(x: x)
            return
        }
        if showingTracking {
            drawTracking(ctx, x: x, y: y, width: w)
            drawVersion(x: x)
            return
        }

        if showingGameImage {
            drawGameImage(ctx, x: x, y: y, width: w)
            drawVersion(x: x)
            return
        }

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
        y = row(ctx, "Reduce motion", "sparkles", (0xB79BFF, 0x6A47D6), ids: ["motion:reduce"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "motion:reduce", self.settings.reduceMotion, CGRect(x: r.maxX - 14 - 60, y: r.midY - 17, width: 60, height: 34))
        }

        y = row(ctx, "Game audio in PS VR2", "headphones", (0x7FD3FF, 0x2A7FBF), ids: ["game:systemAudio"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "game:systemAudio", self.settings.gameSystemAudio, CGRect(x: r.maxX - 14 - 60, y: r.midY - 17, width: 60, height: 34))
        }
        let refresh = refreshState?() ?? (rates: [], current: 0, busy: false)
        _ = row(ctx, "Refresh rate", "display", (0xB79BFF, 0x6A47D6), ids: ["display:90", "display:120"], x: rx, y: y, width: rw) { r in
            let left = CGRect(x: r.maxX - 14 - 224, y: r.midY - 20, width: 106, height: 40)
            self.button(ctx, "display:90", "90 Hz", left, symbol: refresh.current == 90 ? "checkmark" : nil,
                        enabled: !refresh.busy && refresh.rates.contains(90), selected: refresh.current == 90)
            self.button(ctx, "display:120", "120 Hz", left.offsetBy(dx: 118, dy: 0), symbol: refresh.current == 120 ? "checkmark" : nil,
                        enabled: !refresh.busy && refresh.rates.contains(120), selected: refresh.current == 120)
        }

        drawVersion(x: x)
    }

    private func drawTracking(_ ctx: CGContext, x: CGFloat, y start: CGFloat, width: CGFloat) {
        let y = section(ctx, "PS VR2 tracking", x: x, y: start)
        let rx = glass.minX + 14, rw = glass.width - 28
        _ = row(ctx, "LED sync feedback", "lightbulb", (0xFFBF77, 0xBA7430), ids: ["tracking:led"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "tracking:led", self.settings.senseLEDFeedback, CGRect(x: r.maxX - 74, y: r.midY - 17, width: 60, height: 34))
        }
    }

    private func drawFOV(_ ctx: CGContext, x: CGFloat, y start: CGFloat, width: CGFloat) {
        var y = section(ctx, "Game field of view", x: x, y: start)
        let rx = glass.minX + 14, rw = glass.width - 28
        y = row(ctx, "FOV crop", "crop", (0xF09283, 0xB02A45), ids: ["game:crop"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "game:crop", self.settings.gameCropEnabled, CGRect(x: r.maxX - 74, y: r.midY - 17, width: 60, height: 34))
        }
        y = sliderRow(ctx, "game:cropHorizontal", "Horizontal FOV", "arrow.left.and.right", (0x7FD3FF, 0x2A7FBF),
                      "\(Int((settings.gameCropHorizontal * 100).rounded()))%", CGFloat((settings.gameCropHorizontal - 0.5) * 2),
                      enabled: settings.gameCropEnabled, x: rx, y: y, width: rw)
        y = sliderRow(ctx, "game:cropVertical", "Vertical FOV", "arrow.up.and.down", (0xB79BFF, 0x6A47D6),
                      "\(Int((settings.gameCropVertical * 100).rounded()))%", CGFloat((settings.gameCropVertical - 0.5) * 2),
                      enabled: settings.gameCropEnabled, x: rx, y: y, width: rw)
        NightGlass.drawText("100% keeps the full field; lower values remove outer edges.", at: CGPoint(x: x, y: y + 8), style: .caption, color: NightGlass.secondary, width: width)
        NightGlass.drawText("Pixel density stays the same. The inner eye edges are preserved.", at: CGPoint(x: x, y: y + 34), style: .caption, color: NightGlass.secondary, width: width)
        let geometry = gameImageSettingsGeometry(settings)
        NightGlass.drawText("\(geometry.renderSize.width)×\(geometry.renderSize.height) per eye at \(settings.gameRenderPercent)% render scale",
                            at: CGPoint(x: x, y: y + 68), style: .caption, color: NightGlass.secondary, width: width)
        NightGlass.drawText("Restart the game to apply FOV changes.", at: CGPoint(x: x, y: y + 102), style: .caption, color: NightGlass.secondary, width: width)
    }

    private func drawGameImage(_ ctx: CGContext, x: CGFloat, y start: CGFloat, width: CGFloat) {
        var y = section(ctx, "Game image", x: x, y: start)
        let rx = glass.minX + 14, rw = glass.width - 28
        y = row(ctx, "FSR 1", "sparkles", (0x8FE39B, 0x2E9E5C), ids: ["game:fsr"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "game:fsr", self.settings.gameFSREnabled, CGRect(x: r.maxX - 14 - 60, y: r.midY - 17, width: 60, height: 34))
        }
        NightGlass.drawText("Reconstructs lower-resolution game frames before display.", at: CGPoint(x: x, y: y + 4), style: .caption,
                            color: NightGlass.secondary, width: width)
        y += 42
        y = sliderRow(ctx, "game:scale", "Game render scale", "square.resize", (0x7FD3FF, 0x2A7FBF), "\(settings.gameRenderPercent)%",
                      CGFloat(settings.gameRenderPercent - 50) / 50, x: rx, y: y, width: rw)
        let geometry = gameImageSettingsGeometry(settings)
        NightGlass.drawText("\(geometry.renderSize.width)×\(geometry.renderSize.height) → \(geometry.imageTarget.width)×\(geometry.imageTarget.height) per eye",
                            at: CGPoint(x: x, y: y + 4), style: .caption, color: NightGlass.secondary, width: width)
        NightGlass.drawText("Lower is faster; higher keeps more detail.", at: CGPoint(x: x, y: y + 30), style: .caption,
                            color: NightGlass.secondary, width: width)
        y += 60
        y = row(ctx, "Half frame rate", "speedometer", (0xFFBF77, 0xBA7430), ids: ["game:half:off", "game:half:on", "game:half:auto"], x: rx, y: y, width: rw) { r in
            _ = self.segmented(ctx, GameHalfFrameRateMode.allCases.map {
                ("game:half:" + $0.rawValue, $0.title, self.settings.gameHalfFrameRateMode == $0)
            }, x: r.maxX - 14 - 234, y: r.midY - 22, width: 234)
        }
        NightGlass.drawText("Every other refresh: 60 game FPS at 120 Hz; 45 at 90 Hz.", at: CGPoint(x: x, y: y + 4), style: .caption,
                            color: NightGlass.secondary, width: width)
        NightGlass.drawText("Auto follows game performance and checks for recovery.", at: CGPoint(x: x, y: y + 26), style: .caption,
                            color: NightGlass.secondary, width: width)
        y += 54
        y = row(ctx, "Spacewarp 2×", "square.stack.3d.up", (0x7FD3FF, 0x2A7FBF), ids: ["game:spacewarp"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "game:spacewarp", self.settings.gameSpacewarpEnabled, CGRect(x: r.maxX - 14 - 60, y: r.midY - 17, width: 60, height: 34))
        }
        NightGlass.drawText("At 120 Hz: 60 game frames + 60 generated frames per second.", at: CGPoint(x: x, y: y + 4), style: .caption,
                            color: NightGlass.secondary, width: width)
        NightGlass.drawText("Auto generates only at half rate; Off shows real frames.", at: CGPoint(x: x, y: y + 26), style: .caption,
                            color: NightGlass.secondary, width: width)
        y += 54
        y = row(ctx, "RCAS sharpening", "sparkles", (0xB79BFF, 0x6A47D6), ids: ["game:sharpening"], x: rx, y: y, width: rw) { r in
            self.toggle(ctx, "game:sharpening", self.settings.gameSharpeningEnabled, CGRect(x: r.maxX - 14 - 60, y: r.midY - 17, width: 60, height: 34))
        }
        y = sliderRow(ctx, "game:sharpness", "Sharpness", "circle.lefthalf.filled", (0xB79BFF, 0x6A47D6), "\(Int((settings.gameSharpness * 100).rounded()))%",
                      CGFloat(settings.gameSharpness), x: rx, y: y, width: rw)
        NightGlass.drawText("Sharpening works with FSR on or off.", at: CGPoint(x: x, y: y + 8), style: .caption,
                            color: NightGlass.secondary, width: width)
        NightGlass.drawText("Restart the game to apply crop or render scale.", at: CGPoint(x: x, y: y + 34), style: .caption,
                            color: NightGlass.secondary, width: width)
        NightGlass.drawText("100%, crop and image effects off: original game image.", at: CGPoint(x: x, y: y + 60), style: .caption,
                            color: NightGlass.secondary, width: width)
    }

    private func drawVersion(x: CGFloat) {
        let version = "\(RuntimePaths.displayName) · core \(String(cString: halliday_core_version()))"
        NightGlass.drawText(version, at: CGPoint(x: x, y: glass.maxY - 30), style: .caption, color: NightGlass.tertiary)
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
                           _ fraction: CGFloat, enabled: Bool = true, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        row(ctx, title, symbol, colors, ids: enabled ? [id] : [], x: x, y: y, width: width) { r in
            let valueSize = NightGlass.textSize(value, style: .label, tabular: true)
            NightGlass.drawText(value, at: CGPoint(x: r.maxX - 14 - valueSize.width, y: r.midY - valueSize.height / 2), style: .label,
                                color: NightGlass.secondary, tabular: true)
            let start = r.minX + 230, end = r.maxX - 14 - 64
            let track = self.slider(ctx, id, row: CGRect(x: start, y: r.midY - 20, width: end - start, height: 40), fraction: fraction, enabled: enabled)
            if enabled { self.tracks[id] = track }
        }
    }

    private func section(_ ctx: CGContext, _ title: String, x: CGFloat, y: CGFloat) -> CGFloat {
        NightGlass.drawSection(title, at: CGPoint(x: x, y: y - 2))
        return y + 24
    }




}
