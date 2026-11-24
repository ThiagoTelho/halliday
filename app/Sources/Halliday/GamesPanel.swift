// Games (ROADMAP W14.8, design board 15): the VR games in GameHub, each with its state checked live
// and the one thing to do about it. The first time, it asks before writing anything.
// The model is `GameLibrary`.

import AppKit

@MainActor
final class GamesPanel: VRPanel {
    private let library = GameLibrary.shared
    var onClose: (() -> Void)?
    /// Asks AppDelegate to open a URL (GameHub's launch link) or GameHub itself.
    var onPlay: ((GameEntry) -> Void)?
    var onSetUp: ((GameEntry) -> Void)?
    var onUndo: ((GameEntry) -> Void)?
    var onOpenGameHub: (() -> Void)?
    /// "Install an app": the owner lets the user choose an `.apk` file.
    var onInstall: (() -> Void)?
    /// A Quest app's "Remove".
    var onRemove: ((GameEntry) -> Void)?
    var onNotice: ((String, Bool) -> Void)?

    private var selected: String?
    private var scroll = 0
    private var scrollRemainder: CGFloat = 0
    /// The first-time screen's "Choose games" was pressed: the list, with nothing set up yet.
    private var choosing = false

    static let distance: Float = 1.3
    static let below: Float = 4

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 960, height: CGFloat = 660
    private static let listWidth: CGFloat = 500, rowHeight: CGFloat = 64, visibleRows = 7
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
    }

    /// Opening: the library is read again (its state is checked live).
    func prepare() {
        // Debug: --games-choose opens on the list, past the first-time screen (nothing is written).
        choosing = CommandLine.arguments.contains("--games-choose")
        library.refresh()
        setNeedsDisplay()
    }

    func scroll(by dy: CGFloat) {
        scrollRemainder -= dy
        let rows = Int(scrollRemainder / 40)
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows) * 40
        let clamped = max(0, min(max(0, library.games.count - Self.visibleRows), scroll + rows))
        guard clamped != scroll else { return }
        scroll = clamped
        setNeedsDisplay()
    }

    private var current: GameEntry? {
        library.games.first { $0.id == selected } ?? library.games.first
    }

    private func activate(_ id: String) {
        switch id {
        case "close": onClose?()
        case "refresh": library.refresh()
        case "install": onInstall?()
        case "consent:all":
            let n = library.setUpAll()
            onNotice?(n == 0 ? "Nothing to set up yet: start a game once from GameHub" : "\(n) game\(n == 1 ? "" : "s") set up for Halliday", n == 0)
        case "consent:choose": choosing = true
        case "consent:later": library.setsUpNewGames.toggle()
        case "auto":
            // On the list, the switch is also the user's yes to Halliday writing the file.
            if library.consented { library.setsUpNewGames.toggle() } else { library.consented = true; library.setsUpNewGames = true }
        default:
            if id.hasPrefix("game:") { selected = String(id.dropFirst(5)) }
            if id.hasPrefix("act:"), let game = current { act(String(id.dropFirst(4)), game) }
        }
        setNeedsDisplay(fade: true)
    }

    private func act(_ action: String, _ game: GameEntry) {
        switch action {
        case "play": onPlay?(game)
        case "gamehub": onOpenGameHub?()
        case "setup", "repair", "update":
            if let onSetUp { onSetUp(game); break }
            if library.setUp(game) {
                onNotice?("\(game.name) is ready to play in Halliday", false)
            } else {
                onNotice?("Couldn't set up \(game.name): the log says why", true)
            }
        case "undo":
            if let onUndo { onUndo(game) }
            else if library.undo(game) { onNotice?("\(game.name) uses its own settings again", false) }
        case "forget":
            _ = library.removeCrossOverExecutable(game)
        case "leave": selected = nil
        case "remove": onRemove?(game)
        default: break
        }
    }

    // --- Drawing ---

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius + 2, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        iconButton(ctx, "close", "xmark", CGRect(x: g.maxX - 56, y: g.minY + 16, width: 40, height: 40), symbolSize: 14, quiet: true)
        if !library.loaded {
            NightGlass.drawText("Games", at: CGPoint(x: g.minX + 28, y: g.minY + 24), style: .display, weight: .semibold)
            skeletonRows(ctx, in: CGRect(x: g.minX + 16, y: g.minY + 90, width: Self.listWidth - 32, height: g.height - 120),
                         rowHeight: Self.rowHeight, thumbnail: CGSize(width: 48, height: 48))
            return
        }
        if !library.hasGameHub, !library.hasCrossOver, library.games.isEmpty {
            message(ctx, in: g, symbol: "gamecontroller", title: "No games yet",
                    detail: "Install a standalone headset app from its .apk file, or a Windows VR game in GameHub or CrossOver.",
                    action: ("install", "Install an app"))
            return
        }
        if library.games.isEmpty {
            message(ctx, in: g, symbol: "gamecontroller", title: "No games yet",
                    detail: "Install a standalone headset app or a Windows VR game. Add other Windows executables in the companion's Windows games page.",
                    action: ("install", "Install an app"))
            return
        }
        // The first-time screen, unless every game is set up already (by `--install-openvr`) or
        // waits for its first launch: then there is nothing to ask.
        let toSetUp = library.games.contains { !$0.isCrossOver && $0.container != nil && $0.status != .ready }
        if !library.consented, !choosing, toSetUp {
            drawConsent(ctx, g)
            return
        }
        drawList(ctx, g)
        drawDetail(ctx, CGRect(x: g.minX + Self.listWidth, y: g.minY, width: g.width - Self.listWidth, height: g.height))
    }

    private func drawConsent(_ ctx: CGContext, _ g: CGRect) {
        let c = CGRect(x: g.midX - 300, y: g.minY + 112, width: 600, height: g.height - 160)
        let icon = CGRect(x: c.minX, y: c.minY, width: 56, height: 56)
        NightGlass.fill(ctx, icon, radius: 16, color: NightGlass.accent.withAlphaComponent(0.20))
        NightGlass.drawSymbol("gamecontroller", in: icon, size: 26, color: NightGlass.accent)
        var y = c.minY + 80
        NightGlass.drawText("Play your GameHub VR games here", at: CGPoint(x: c.minX, y: y), style: .display, weight: .semibold, width: c.width)
        y += 44
        let n = library.games.filter { !$0.isCrossOver && $0.quest == nil }.count
        for line in NightGlass.wrap("Halliday found \(n) VR game\(n == 1 ? "" : "s") in GameHub. To play them in Halliday, it becomes their VR runtime instead of SteamVR.",
                                    style: .body, width: c.width) {
            NightGlass.drawText(line, at: CGPoint(x: c.minX, y: y), style: .body, color: NightGlass.secondary)
            y += 24
        }
        y += 16
        for (symbol, text) in [("doc.text", "One small file in each game's Wine container, and Halliday's runtime in Halliday's own folder. Nothing else changes."),
                               ("arrow.uturn.backward", "Undo, per game, puts back what was there before."),
                               ("lock.shield", "No network, no account. Games still start through GameHub.")] {
            NightGlass.drawSymbol(symbol, in: CGRect(x: c.minX, y: y, width: 22, height: 22), size: 15, color: NightGlass.secondary)
            for line in NightGlass.wrap(text, style: .label, width: c.width - 36) {
                NightGlass.drawText(line, at: CGPoint(x: c.minX + 36, y: y + 2), style: .label, color: NightGlass.text)
                y += 21
            }
            y += 10
        }
        y += 6
        NightGlass.drawText("Also set up games I add later", at: CGPoint(x: c.minX, y: y + 5), style: .body)
        toggle(ctx, "consent:later", library.setsUpNewGames, CGRect(x: c.maxX - 52, y: y, width: 52, height: 30))
        y += 58
        button(ctx, "consent:choose", "Choose games", CGRect(x: c.maxX - 340, y: y, width: 160, height: 48))
        button(ctx, "consent:all", "Set up all", CGRect(x: c.maxX - 170, y: y, width: 170, height: 48), kind: .main)
    }

    private func drawList(_ ctx: CGContext, _ g: CGRect) {
        let x = g.minX + 24
        NightGlass.drawText("Games", at: CGPoint(x: x, y: g.minY + 24), style: .display, weight: .semibold)
        // "GameHub" while every game is one of its; with Quest apps among them, just how many.
        let count = "\(library.games.count) installed"
        let cw = NightGlass.textSize(count, style: .caption, weight: .semibold).width + 22
        let chipRect = CGRect(x: g.minX + Self.listWidth - 24 - 52 - 48 - cw, y: g.minY + 30, width: cw, height: 28)
        NightGlass.fill(ctx, chipRect, radius: 14, color: NSColor(white: 1, alpha: 0.10))
        NightGlass.drawText(count, at: CGPoint(x: chipRect.minX + 11, y: chipRect.midY - 8), style: .caption, color: NightGlass.text, weight: .semibold)
        iconButton(ctx, "refresh", "arrow.clockwise", CGRect(x: g.minX + Self.listWidth - 24 - 44, y: g.minY + 22, width: 44, height: 44), backed: true)
        // Install an app from its .apk file.
        iconButton(ctx, "install", "plus", CGRect(x: g.minX + Self.listWidth - 24 - 44 - 48, y: g.minY + 22, width: 44, height: 44), backed: true)
        // Divider between list and detail.
        NightGlass.fill(ctx, CGRect(x: g.minX + Self.listWidth, y: g.minY + 20, width: 1, height: g.height - 40), radius: 0,
                        color: NSColor(white: 1, alpha: 0.08))

        let top = g.minY + 84
        let chosen = current?.id
        for (k, game) in library.games.dropFirst(scroll).prefix(Self.visibleRows).enumerated() {
            let r = CGRect(x: g.minX + 14, y: top + CGFloat(k) * Self.rowHeight, width: Self.listWidth - 30, height: Self.rowHeight - 4)
            row(ctx, "game:\(game.id)", r, radius: 16, rest: game.id == chosen ? 0.10 : 0)
            Self.drawTile(ctx, CGRect(x: r.minX + 8, y: r.minY + 6, width: 48, height: 48), seed: game.id, symbolSize: 0)
            let chip = statusChip(game.status)
            let chipW = NightGlass.textSize(chip.text, style: .caption, weight: .semibold).width + (chip.symbol == nil ? 20 : 38)
            let textW = r.width - 48 - 30 - chipW - 12
            NightGlass.drawText(game.name, at: CGPoint(x: r.minX + 70, y: r.minY + 10), style: .body, weight: .medium, width: textW)
            NightGlass.drawText(subline(game), at: CGPoint(x: r.minX + 70, y: r.minY + 34), style: .caption, color: NightGlass.secondary, width: textW)
            drawChip(ctx, chip, CGRect(x: r.maxX - 10 - chipW, y: r.midY - 12, width: chipW, height: 24))
        }
        if library.games.count > Self.visibleRows {
            let shown = "\(scroll + 1)–\(min(library.games.count, scroll + Self.visibleRows)) of \(library.games.count) · scroll for more"
            NightGlass.drawText(shown, at: CGPoint(x: x, y: top + CGFloat(Self.visibleRows) * Self.rowHeight + 2), style: .caption, color: NightGlass.tertiary)
        }
        // The choice about games added later.
        let y = g.maxY - 60
        NightGlass.fill(ctx, CGRect(x: g.minX + 24, y: y - 12, width: Self.listWidth - 48, height: 1), radius: 0, color: NSColor(white: 1, alpha: 0.08))
        NightGlass.drawText("Set up games I add to GameHub", at: CGPoint(x: x, y: y + 6), style: .label, color: NightGlass.text)
        toggle(ctx, "auto", library.consented && library.setsUpNewGames, CGRect(x: g.minX + Self.listWidth - 24 - 52, y: y, width: 52, height: 30))
    }

    private func drawDetail(_ ctx: CGContext, _ d: CGRect) {
        guard let game = current else { return }
        let x = d.minX + 24, w = d.width - 48
        let art = CGRect(x: x, y: d.minY + 24, width: w - 52, height: 150)
        Self.drawTile(ctx, art, seed: game.id, symbolSize: 44, radius: 20)
        var y = art.maxY + 18
        NightGlass.drawText(game.name, at: CGPoint(x: x, y: y), style: .title, weight: .semibold, width: w)
        y += 32
        let chip = statusChip(game.status)
        let chipW = NightGlass.textSize(chip.text, style: .caption, weight: .semibold).width + (chip.symbol == nil ? 20 : 38)
        drawChip(ctx, chip, CGRect(x: x, y: y, width: chipW, height: 24))
        y += 40
        for line in NightGlass.wrap(body(game), style: .label, width: w).prefix(6) {
            NightGlass.drawText(line, at: CGPoint(x: x, y: y), style: .label, color: NightGlass.text)
            y += 21
        }
        // The actions: the main one, then the others.
        let actions = self.actions(game)
        var by = d.maxY - 24 - 48
        if actions.count > 1 {
            let others = Array(actions.dropFirst())
            let bw = (w - CGFloat(others.count - 1) * 8) / CGFloat(others.count)
            for (i, a) in others.enumerated() {
                button(ctx, "act:\(a.id)", a.title, CGRect(x: x + CGFloat(i) * (bw + 8), y: by, width: bw, height: 48), kind: a.kind)
            }
            by -= 56
        }
        if let main = actions.first {
            button(ctx, "act:\(main.id)", main.title, CGRect(x: x, y: by, width: w, height: 48), symbol: main.symbol, kind: .main)
        }
    }

    private struct Action {
        let id: String, title: String
        var symbol: String? = nil
        var kind: ButtonKind = .plain
    }

    private func actions(_ g: GameEntry) -> [Action] {
        if g.nativeAlyx != nil {
            return [Action(id: "play", title: "Play", symbol: "play.fill")]
        }
        // A Quest app is Halliday's own to start and to remove.
        if g.quest != nil {
            let remove = Action(id: "remove", title: "Remove", kind: .quiet)
            switch g.status {
            case .stopped: return [Action(id: "play", title: "Try again", symbol: "play.fill"), remove]
            default: return [Action(id: "play", title: "Play", symbol: "play.fill"), remove]
            }
        }
        if g.isCrossOver {
            var result: [Action] = switch g.status {
            case .ready, .stopped:
                [Action(id: "play", title: "Play", symbol: "play.fill"), Action(id: "undo", title: "Undo bottle set-up", kind: .quiet)]
            case .changed:
                [Action(id: "undo", title: "Undo Halliday set-up"), Action(id: "leave", title: "Leave current settings", kind: .quiet)]
            default:
                [Action(id: "setup", title: "Set up bottle")]
            }
            if g.isManualCrossOver { result.append(Action(id: "forget", title: "Remove entry", kind: .quiet)) }
            return result
        }
        return switch g.status {
        case .ready: [Action(id: "play", title: "Play", symbol: "play.fill"), Action(id: "gamehub", title: "Open GameHub"),
                      Action(id: "undo", title: "Undo set-up", kind: .quiet)]
        case .stopped: [Action(id: "play", title: "Play again", symbol: "play.fill"), Action(id: "gamehub", title: "Open GameHub")]
        case .notSetUp: [Action(id: "setup", title: "Set up")]
        case .firstLaunch: [Action(id: "gamehub", title: "Open GameHub", symbol: "arrow.up.forward.app")]
        case .changed: [Action(id: "repair", title: "Repair"), Action(id: "leave", title: "Leave it", kind: .quiet)]
        case .update: [Action(id: "update", title: "Update")]
        }
    }

    private func body(_ g: GameEntry) -> String {
        if g.nativeAlyx != nil {
            if case .stopped(let why) = g.status { return why }
            return "\(g.sourceLabel). Play starts this existing Alyx installation in Halliday."
        }
        if let game = g.crossOver {
            if case .stopped(let why) = g.status { return why }
            if g.status == .changed { return "Another application changed this bottle's VR settings. Halliday leaves those changes in place." }
            return "\(g.sourceLabel). Play uses the CrossOver version selected in the companion. Set up and Undo affect every game in this bottle."
                + (game.executable == nil ? " Steam keeps its existing launch options." : " This executable was added manually.")
        }
        if g.quest != nil, g.status == .ready {
            if let at = g.lastPlayed, let minutes = g.lastMinutes {
                return "Last played \(Self.when(at)): it ran in Halliday for \(GameBar.duration(max(1, minutes)))."
            }
            return "A Quest app, installed in Halliday from its APK file. Play starts it here; it shows as soon as it draws."
        }
        switch g.status {
        case .ready:
            if let at = g.lastPlayed, let minutes = g.lastMinutes {
                return "Last played \(Self.when(at)): it ran in Halliday for \(GameBar.duration(max(1, minutes)))."
            }
            return "Set up for Halliday. Play starts it through GameHub; Halliday shows it as soon as it draws."
        case .stopped(let why): return why
        case .notSetUp: return "This game still uses SteamVR's settings, so it won't show in Halliday. Set up writes one file into its Wine container."
        case .firstLaunch: return "GameHub makes a game's container the first time it starts. Start it once from GameHub; Halliday sets it up as soon as the container appears."
        case .changed: return "Its VR settings point somewhere else now, probably SteamVR or another runtime. Repair points them back at Halliday."
        case .update: return "Its container points at Halliday's runtime in another place. Update points it at this Halliday's; the game's files aren't touched."
        }
    }

    private func subline(_ g: GameEntry) -> String {
        if g.isCrossOver || g.nativeAlyx != nil { return g.sourceLabel }
        if g.quest != nil, g.status == .ready { return g.lastPlayed.map { "Played \(Self.when($0))" } ?? "Quest app" }
        return switch g.status {
        case .ready: g.lastPlayed.map { "Played \(Self.when($0))" } ?? "Ready to play"
        case .stopped: "Tried, and stopped"
        case .notSetUp: "Uses SteamVR's settings"
        case .firstLaunch: "Installed, never started"
        case .changed: "Another app changed it"
        case .update: "Runtime from another Halliday"
        }
    }

    private static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = NightGlass.dateLocale
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date).lowercased()
    }

    // --- Status chips and tiles ---

    private struct Chip {
        let text: String
        let symbol: String?
        let fill: NSColor, color: NSColor
    }

    private static let amber = NSColor(srgbRed: 1, green: 0xCB / 255, blue: 0x91 / 255, alpha: 1)

    private func statusChip(_ s: GameEntry.Status) -> Chip {
        switch s {
        case .ready: Chip(text: "Ready", symbol: "checkmark", fill: NightGlass.accent.withAlphaComponent(0.18),
                          color: NSColor(srgbRed: 0xB9 / 255, green: 0xD1 / 255, blue: 1, alpha: 1))
        case .stopped: Chip(text: "Stopped at launch", symbol: "exclamationmark", fill: NightGlass.danger.withAlphaComponent(0.18),
                            color: NSColor(srgbRed: 1, green: 0xB8 / 255, blue: 0xB0 / 255, alpha: 1))
        case .firstLaunch: Chip(text: "First launch", symbol: nil, fill: NSColor(white: 1, alpha: 0.10), color: NSColor(white: 0.85, alpha: 1))
        case .notSetUp: Chip(text: "Not set up", symbol: nil, fill: NightGlass.warning.withAlphaComponent(0.18), color: Self.amber)
        case .changed: Chip(text: "Changed", symbol: nil, fill: NightGlass.warning.withAlphaComponent(0.18), color: Self.amber)
        case .update: Chip(text: "Update", symbol: nil, fill: NightGlass.warning.withAlphaComponent(0.18), color: Self.amber)
        }
    }

    private func drawChip(_ ctx: CGContext, _ chip: Chip, _ rect: CGRect) {
        NightGlass.fill(ctx, rect, radius: rect.height / 2, color: chip.fill)
        var x = rect.minX + 10
        if let symbol = chip.symbol {
            NightGlass.drawSymbol(symbol, in: CGRect(x: x, y: rect.minY, width: 14, height: rect.height), size: 10, color: chip.color, weight: .bold)
            x += 18
        }
        NightGlass.drawText(chip.text, at: CGPoint(x: x, y: rect.midY - 8), style: .caption, color: chip.color, weight: .semibold)
    }

    /// A game's tile: a deep two-tone gradient picked from `seed` (no game art is copied), and the
    /// controller symbol when `symbolSize` > 0.
    static func drawTile(_ ctx: CGContext, _ rect: CGRect, seed: String, symbolSize: CGFloat, radius: CGFloat? = nil) {
        let palettes: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 0x3E / 255, green: 0x6E / 255, blue: 0x7A / 255, alpha: 1), NSColor(srgbRed: 0x1D / 255, green: 0x3B / 255, blue: 0x4F / 255, alpha: 1)),
            (NSColor(srgbRed: 0x4B / 255, green: 0x3A / 255, blue: 0x6B / 255, alpha: 1), NSColor(srgbRed: 0x24 / 255, green: 0x1B / 255, blue: 0x38 / 255, alpha: 1)),
            (NSColor(srgbRed: 0x6B / 255, green: 0x4B / 255, blue: 0x32 / 255, alpha: 1), NSColor(srgbRed: 0x33 / 255, green: 0x23 / 255, blue: 0x1A / 255, alpha: 1)),
            (NSColor(srgbRed: 0x2F / 255, green: 0x5A / 255, blue: 0x4A / 255, alpha: 1), NSColor(srgbRed: 0x17 / 255, green: 0x30 / 255, blue: 0x2A / 255, alpha: 1)),
            (NSColor(srgbRed: 0x5A / 255, green: 0x30 / 255, blue: 0x46 / 255, alpha: 1), NSColor(srgbRed: 0x2C / 255, green: 0x18 / 255, blue: 0x22 / 255, alpha: 1)),
            (NSColor(srgbRed: 0x34 / 255, green: 0x40 / 255, blue: 0x5E / 255, alpha: 1), NSColor(srgbRed: 0x1A / 255, green: 0x20 / 255, blue: 0x30 / 255, alpha: 1)),
        ]
        let hash = seed.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) ^ $1.value }
        let (a, b) = palettes[Int(hash % UInt32(palettes.count))]
        let r = radius ?? rect.height * 0.25
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
        if symbolSize > 0 {
            NightGlass.drawSymbol("gamecontroller", in: rect, size: symbolSize, color: NSColor(white: 0.92, alpha: 0.9))
        }
    }
}
