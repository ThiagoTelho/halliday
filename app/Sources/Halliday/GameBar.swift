// Halliday over a running game (ROADMAP W14.10, design board 14, option A): the game keeps
// running, its world stays around the user dimmed and blurred (`Renderer.gameAway`), and this bar
// sits in front with the dock below it. Back to the game, Recenter, and Quit game, which asks first;
// a game that doesn't quit within 10 s can be force quit. Above them, what one wants to set
// without leaving the game: Halliday's volume, seated or room-scale, the floor's height in the
// game's world, and passthrough.

import AppKit

@MainActor
final class GameBar: VRPanel {
    enum Moment: Equatable {
        case bar
        case confirm
        case quitting(since: Double)
        case stuck
    }

    private(set) var moment: Moment = .bar
    var name = "The game"
    var startedAt: Date?
    var onBack: (() -> Void)?
    var onRecenter: (() -> Void)?
    var onQuit: (() -> Void)?
    var onForceQuit: (() -> Void)?
    /// The floor of the game's world up or down a step (meters), and the height it is at now.
    var onFloor: ((Float) -> Void)?
    var floorLift: (() -> Float)?
    /// Passthrough: switch it, and whether it is on (nil without the headset: no button).
    var onPassthrough: (() -> Void)?
    var passthrough: (() -> Bool?)?
    /// The controllers' batteries as a line ("L 80% · R 65%"; nil with none connected).
    var batteries: (() -> String?)?
    /// Starts setting where the controllers point (the owner counts down and does it).
    var onCalibrate: (() -> Void)?
    /// The header's right side as last drawn (the time, the batteries): redrawn when it changes.
    private var corner = ""
    private var cornerNow: String {
        let time = Self.clock.string(from: Date())
        return batteries?().map { "\(time)\n\($0)" } ?? time
    }
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private var tracks: [String: CGRect] = [:]

    static let distance: Float = 1.1
    static let below: Float = 4
    /// How long a game has to quit before Force quit is offered.
    static let quitWait = 10.0

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 680, height: CGFloat = 404
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
        onPress = { [weak self] id in if let p = self?.lastPoint { self?.slide(id, to: p) } }
        onDrag = { [weak self] id, p in self?.slide(id, to: p) }
    }

    private func slide(_ id: String, to p: CGPoint) {
        guard let track = tracks[id] else { return }
        let t = Float(max(0, min(1, (p.x - track.minX) / track.width)))
        if id == "volume" {
            Settings.shared.volume = (t * 20).rounded() / 20
        } else if id == "brightness" {
            let r = Settings.brightnessRange
            Settings.shared.brightness = ((r.lowerBound + t * (r.upperBound - r.lowerBound)) * 20).rounded() / 20
        } else {
            return
        }
        setNeedsDisplay()
    }

    /// Back to the first moment (each time Halliday comes up).
    func reset() {
        moment = .bar
        setNeedsDisplay()
    }

    /// The game asked to quit hasn't, after `quitWait`: offer Force quit.
    func tick() {
        if moment == .bar, corner != cornerNow { setNeedsDisplay() }
        if case .quitting(let since) = moment, CACurrentMediaTime() - since > Self.quitWait {
            moment = .stuck
            setNeedsDisplay(fade: true)
        }
    }

    /// Acts as if control `id` was clicked (scripted tests: `--game-keys quitask@T`).
    func choose(_ id: String) { activate(id) }

    private func activate(_ id: String) {
        switch id {
        case "back": onBack?()
        case "recenter": onRecenter?()
        case "floor:up": onFloor?(0.05)
        case "floor:down": onFloor?(-0.05)
        case "passthrough": onPassthrough?()
        case "calibrate": onCalibrate?()
        case _ where id.hasPrefix("mode:"):
            if let mode = Settings.Mode(rawValue: String(id.dropFirst(5))) { Settings.shared.mode = mode }
        case "quit": moment = .confirm
        case "keep": moment = .bar
        case "quit:confirm":
            moment = .quitting(since: CACurrentMediaTime())
            onQuit?()
        case "wait": moment = .quitting(since: CACurrentMediaTime())
        case "force": onForceQuit?()
        default: break
        }
        setNeedsDisplay(fade: true)
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius + 2, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass.insetBy(dx: 24, dy: 22)
        switch moment {
        case .bar: drawBar(ctx, g)
        case .confirm:
            dialog(ctx, g, title: "Quit \(name)?", detail: "Anything since the game last saved may be lost.")
            let w: CGFloat = 150
            button(ctx, "keep", "Keep playing", CGRect(x: g.maxX - 2 * w - 10, y: g.maxY - 48, width: w, height: 48))
            button(ctx, "quit:confirm", "Quit game", CGRect(x: g.maxX - w, y: g.maxY - 48, width: w, height: 48), kind: .dangerMain)
        case .quitting:
            animates = true
            spinner(ctx, center: CGPoint(x: g.minX + 12, y: g.minY + 16), radius: 9)
            NightGlass.drawText("Asking \(name) to quit", at: CGPoint(x: g.minX + 34, y: g.minY + 2), style: .title, weight: .semibold,
                                width: g.width - 34)
            NightGlass.drawText("It closes on its own, the way it would from its menu.", at: CGPoint(x: g.minX, y: g.minY + 46),
                                style: .body, color: NightGlass.secondary, width: g.width)
            button(ctx, "back", "Back to the game", CGRect(x: g.maxX - 190, y: g.maxY - 48, width: 190, height: 48))
        case .stuck:
            dialog(ctx, g, title: "\(name) isn't answering",
                   detail: "It was asked to quit \(Int(Self.quitWait)) seconds ago. Force quit closes it at once, without saving.")
            let w: CGFloat = 140
            button(ctx, "wait", "Wait", CGRect(x: g.maxX - 2 * w - 10, y: g.maxY - 48, width: w, height: 48))
            button(ctx, "force", "Force quit", CGRect(x: g.maxX - w, y: g.maxY - 48, width: w, height: 48), kind: .dangerMain)
        }
    }

    private func dialog(_ ctx: CGContext, _ g: CGRect, title: String, detail: String) {
        NightGlass.drawText(title, at: CGPoint(x: g.minX, y: g.minY + 2), style: .title, weight: .semibold, width: g.width)
        var y = g.minY + 44
        for line in NightGlass.wrap(detail, style: .body, width: g.width).prefix(2) {
            NightGlass.drawText(line, at: CGPoint(x: g.minX, y: y), style: .body, color: NightGlass.secondary)
            y += NightGlass.textSize("Ag", style: .body).height + 3
        }
    }

    private func drawBar(_ ctx: CGContext, _ g: CGRect) {
        // The game: its tile, its name, how long it has been played.
        let tile = CGRect(x: g.minX, y: g.minY, width: 72, height: 72)
        GamesPanel.drawTile(ctx, tile, seed: name, symbolSize: 30)
        // The time and the controllers' batteries, on the right.
        corner = cornerNow
        var cornerWidth: CGFloat = 0
        for (i, line) in corner.split(separator: "\n").enumerated() {
            let size = NightGlass.textSize(String(line), style: i == 0 ? .label : .caption, tabular: true)
            cornerWidth = max(cornerWidth, size.width)
            NightGlass.drawText(String(line), at: CGPoint(x: g.maxX - size.width, y: tile.minY + (i == 0 ? 12 : 44)), style: i == 0 ? .label : .caption,
                                color: i == 0 ? NightGlass.text : NightGlass.secondary, tabular: true)
        }
        NightGlass.drawText(name, at: CGPoint(x: tile.maxX + 18, y: tile.minY + 10), style: .title, weight: .semibold,
                            width: g.width - tile.width - 18 - cornerWidth - 16)
        var status = "Paused"
        if let startedAt {
            let minutes = Int(Date().timeIntervalSince(startedAt) / 60)
            status += minutes < 1 ? " · just started" : " · playing for \(Self.duration(minutes))"
        }
        NightGlass.drawText(status, at: CGPoint(x: tile.maxX + 18, y: tile.minY + 44), style: .body, color: NightGlass.secondary)
        // Settings for while one plays. Volume and the mode; then the floor and passthrough.
        let settings = Settings.shared
        let half = (g.width - 24) / 2
        var row = tile.maxY + 20
        let volume = settings.volume < 0.01 ? "Off" : "\(Int((settings.volume * 100).rounded()))%"
        NightGlass.drawText("Volume", at: CGPoint(x: g.minX, y: row), style: .caption, color: NightGlass.secondary)
        NightGlass.drawText(volume, at: CGPoint(x: g.minX + half - NightGlass.textSize(volume, style: .caption, tabular: true).width, y: row),
                            style: .caption, tabular: true)
        tracks["volume"] = slider(ctx, "volume", row: CGRect(x: g.minX, y: row + 20, width: half, height: 40), fraction: CGFloat(settings.volume))
        NightGlass.drawText("Mode", at: CGPoint(x: g.minX + half + 24, y: row), style: .caption, color: NightGlass.secondary)
        _ = segmented(ctx, Settings.Mode.allCases.map { ("mode:\($0.rawValue)", $0.label, settings.mode == $0) },
                      x: g.minX + half + 24, y: row + 18, width: half)
        row += 70
        let right = g.minX + half + 24
        // The headset's brightness (with the headset), and the floor of the game's world.
        if passthrough?() != nil {
            let br = Settings.brightnessRange
            let shown = "\(Int((settings.brightness * 100).rounded()))%"
            NightGlass.drawText("Brightness", at: CGPoint(x: g.minX, y: row), style: .caption, color: NightGlass.secondary)
            NightGlass.drawText(shown, at: CGPoint(x: g.minX + half - NightGlass.textSize(shown, style: .caption, tabular: true).width, y: row),
                                style: .caption, tabular: true)
            tracks["brightness"] = slider(ctx, "brightness", row: CGRect(x: g.minX, y: row + 20, width: half, height: 40),
                                          fraction: CGFloat((settings.brightness - br.lowerBound) / (br.upperBound - br.lowerBound)))
        }
        let lift = floorLift?() ?? 0
        NightGlass.drawText("Floor", at: CGPoint(x: right, y: row), style: .caption, color: NightGlass.secondary)
        NightGlass.drawText(abs(lift) < 0.005 ? "As measured" : String(format: "%+.0f cm", lift * 100), at: CGPoint(x: right, y: row + 30),
                            style: .label, tabular: true)
        iconButton(ctx, "floor:down", "chevron.down", CGRect(x: right + half - 92, y: row + 18, width: 44, height: 44), symbolSize: 14)
        iconButton(ctx, "floor:up", "chevron.up", CGRect(x: right + half - 44, y: row + 18, width: 44, height: 44), symbolSize: 14)
        row += 72
        if let on = passthrough?() {
            button(ctx, "passthrough", on ? "Passthrough on" : "Passthrough", CGRect(x: g.minX, y: row, width: half, height: 44),
                   symbol: on ? "eye.fill" : "eye")
        }
        if batteries?() != nil {
            button(ctx, "calibrate", "Calibrate pointer", CGRect(x: right, y: row, width: half, height: 44), symbol: "scope")
        }
        let y = g.maxY - 48
        button(ctx, "back", "Back to the game", CGRect(x: g.minX, y: y, width: 210, height: 48), symbol: "play.fill", kind: .main)
        button(ctx, "recenter", "Recenter", CGRect(x: g.minX + 220, y: y, width: 140, height: 48), symbol: "scope")
        button(ctx, "quit", "Quit game", CGRect(x: g.maxX - 150, y: y, width: 150, height: 48), symbol: "xmark", kind: .danger)
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
