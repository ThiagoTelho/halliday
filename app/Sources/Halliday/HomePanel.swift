// Home (ROADMAP W13.6, design board 10): what the user sees when nothing is open. The time and
// date (and a running timer), favourites (Halliday's apps and the Mac apps pinned from the
// launcher by holding them) and "continue": the last few things across Halliday. It fades as soon
// as anything opens, and comes back when everything is closed.

import AppKit

@MainActor
final class HomePanel: VRPanel {
    /// Called with what was chosen.
    var onLaunch: ((AppLauncher.App) -> Void)?
    var onContinue: ((Item) -> Void)?
    var onAllApps: (() -> Void)?

    /// One thing to continue.
    struct Item {
        enum Kind { case video(URL), page(URL), note(URL), windows([(bundle: String, name: String)]) }
        let kind: Kind
        let title: String
        let detail: String
        let symbol: String
    }

    private var favourites: [AppLauncher.App] = []
    private var items: [Item] = []
    private var icons: [String: CGImage] = [:]
    private var shownMinute = ""
    private var shownTimer = ""

    static let distance: Float = 1.6
    /// A little above eye level (negative: above).
    static let below: Float = -6

    private static let margin: CGFloat = 30
    private static let width: CGFloat = 900, height: CGFloat = 510
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    // --- Favourites, kept between runs ---

    private static let favouritesKey = "homeFavourites"
    static let maxFavourites = 7
    private static let defaultFavourites = ["halliday:browser", "halliday:files", "halliday:videos", "halliday:photos", "halliday:music", "halliday:games"]

    static var favouriteIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: favouritesKey) ?? defaultFavourites }
        set { UserDefaults.standard.set(Array(newValue.prefix(maxFavourites)), forKey: favouritesKey) }
    }

    /// Pins or unpins an app. Returns true if it is pinned afterwards; false and no change if the
    /// row is full.
    @discardableResult
    static func togglePin(_ id: String) -> Bool? {
        var ids = favouriteIDs
        if let i = ids.firstIndex(of: id) {
            ids.remove(at: i)
            favouriteIDs = ids
            return false
        }
        guard ids.count < maxFavourites else { return nil }
        ids.append(id)
        favouriteIDs = ids
        return true
    }

    // --- The windows that were in VR when Halliday last quit ---

    private static let lastAppsKey = "lastVRApps"

    static func rememberApps(_ apps: [(bundle: String, name: String)]) {
        UserDefaults.standard.set(apps.map { [$0.bundle, $0.name] }, forKey: lastAppsKey)
    }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
    }

    /// Reads the favourites and what there is to continue (call when Home appears).
    func prepare() {
        favourites = Self.favouriteIDs.compactMap { id in
            if let own = AppLauncher.own.first(where: { $0.id == id }) { return own }
            guard FileManager.default.fileExists(atPath: id) else { return nil }
            let name = FileManager.default.displayName(atPath: id).replacingOccurrences(of: ".app", with: "")
            return AppLauncher.App(id: id, name: name, url: URL(fileURLWithPath: id), symbol: nil)
        }
        items = Self.continueItems()
        // Debug (`--sample-home`): example cards instead of the user's own, for screenshots. Their
        // actions open nothing that exists.
        if CommandLine.arguments.contains("--sample-home") {
            favourites = Self.defaultFavourites.compactMap { id in AppLauncher.own.first { $0.id == id } }
            let none = URL(fileURLWithPath: "/nonexistent")
            items = [Item(kind: .video(none), title: "Northern lights, 360°", detail: "Videos · 14 min left", symbol: "play.rectangle"),
                     Item(kind: .page(none), title: "WebXR Samples", detail: "Browser · immersive-web.github.io", symbol: "globe"),
                     Item(kind: .note(none), title: "Trip ideas", detail: "Notes · edited 20 min ago", symbol: "note.text"),
                     Item(kind: .windows([]), title: "Mail and Calendar", detail: "2 windows you had in VR · bring them back", symbol: "macwindow.on.rectangle")]
        }
        setNeedsDisplay()
        loadIcons()
    }

    private func loadIcons() {
        let missing = favourites.filter { $0.url != nil && icons[$0.id] == nil }
        guard !missing.isEmpty else { return }
        Task { @MainActor [weak self] in
            for app in missing {
                guard let self, let url = app.url, let image = AppLauncher.renderIcon(NSWorkspace.shared.icon(forFile: url.path)) else { continue }
                icons[app.id] = image
                setNeedsDisplay(fade: true)
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
        }
    }

    /// The last four things across Halliday, newest first.
    private static func continueItems() -> [Item] {
        var dated: [(Date, Item)] = []
        // (No video here: the unfinished ones are in Videos, under "Continue watching".)
        // The last page.
        if let page = BrowserHistory.shared.recent.first, let url = URL(string: page.url) {
            let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? page.url
            dated.append((page.lastVisit, Item(kind: .page(url), title: page.title.isEmpty ? host : page.title, detail: "Browser · \(host)", symbol: "globe")))
        }
        // The newest note with something in it.
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let notes = (try? FileManager.default.contentsOfDirectory(at: NotesPanel.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let newest = notes.filter { $0.pathExtension == "txt" }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .first { (try? String(contentsOf: $0.0, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        if let (url, date) = newest, let text = try? String(contentsOf: url, encoding: .utf8) {
            let title = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "Note"
            dated.append((date, Item(kind: .note(url), title: title, detail: "Notes · edited \(Self.ago(date))", symbol: "note.text")))
        }
        // The windows that were in VR when Halliday last quit.
        let apps = (UserDefaults.standard.array(forKey: lastAppsKey) as? [[String]] ?? []).compactMap { $0.count == 2 ? (bundle: $0[0], name: $0[1]) : nil }
        if !apps.isEmpty {
            let names = Array(NSOrderedSet(array: apps.map(\.name))).compactMap { $0 as? String }
            let title = names.count <= 2 ? names.joined(separator: " and ") : "\(names[0]), \(names[1]) and \(names.count - 2) more"
            dated.append((.distantPast, Item(kind: .windows(apps), title: title,
                                             detail: "\(apps.count) window\(apps.count == 1 ? "" : "s") you had in VR · bring them back", symbol: "macwindow.on.rectangle")))
        }
        return dated.sorted { $0.0 > $1.0 }.prefix(4).map(\.1)
    }

    private static func ago(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let f = DateFormatter()
        f.locale = NightGlass.dateLocale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }

    /// Redraws when what it shows changes: the minute, a running timer (call each frame).
    func tick() {
        let minute = Self.timeFormatter.string(from: Date())
        let timer = ClockModel.shared.timerRunning ? ClockModel.format(ClockModel.shared.timerLeft) : ""
        if minute != shownMinute || timer != shownTimer { setNeedsDisplay() }
    }

    private func activate(_ id: String) {
        if id == "fav:all" { onAllApps?(); return }
        if id.hasPrefix("fav:"), let i = Int(id.dropFirst(4)), favourites.indices.contains(i) { onLaunch?(favourites[i]); return }
        if id.hasPrefix("cont:"), let i = Int(id.dropFirst(5)), items.indices.contains(i) { onContinue?(items[i]) }
    }

    // --- Drawing ---

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = NightGlass.dateLocale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    override var hoverIsLocal: Bool { true }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: 30)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let x = g.minX + 34, right = g.maxX - 34
        // The time, large and light (board 19), and the date.
        let time = Self.timeFormatter.string(from: Date())
        shownMinute = time
        let size = NightGlass.textSize(time, style: .display, weight: .light, tabular: true)
        let scale: CGFloat = 3.0
        ctx.saveGState()
        ctx.translateBy(x: x - 2, y: g.minY + 18)
        ctx.scaleBy(x: scale, y: scale)
        NightGlass.drawText(time, at: .zero, style: .display, weight: .light, tabular: true)
        ctx.restoreGState()
        NightGlass.drawText(Self.dateFormatter.string(from: Date()), at: CGPoint(x: x + 2, y: g.minY + 18 + size.height * scale - 2), style: .body,
                            color: NSColor(srgbRed: 0xE3 / 255, green: 0xE5 / 255, blue: 0xEC / 255, alpha: 1))
        // A running timer, as a chip at the right.
        let timer = ClockModel.shared
        shownTimer = timer.timerRunning ? ClockModel.format(timer.timerLeft) : ""
        if timer.timerRunning {
            let label = "Timer · \(shownTimer)"
            let w = NightGlass.textSize(label, style: .label, tabular: true).width
            let chip = CGRect(x: right - w - 46, y: g.minY + 92, width: w + 46, height: 34)
            NightGlass.fill(ctx, chip, radius: 17, color: NSColor(white: 1, alpha: 0.09))
            NightGlass.drawSymbol("timer", in: CGRect(x: chip.minX + 10, y: chip.minY + 7, width: 20, height: 20), size: 13,
                                  color: NSColor(srgbRed: 0xF6 / 255, green: 0xC2 / 255, blue: 0x7E / 255, alpha: 1), weight: .semibold)
            NightGlass.drawText(label, at: CGPoint(x: chip.minX + 34, y: chip.midY - 9), style: .label, tabular: true)
        }

        // Favourites: up to seven, and the launcher.
        var y = g.minY + 154
        NightGlass.drawSection("Favourites", at: CGPoint(x: x, y: y))
        y += 26
        let tile: CGFloat = 94, gap: CGFloat = 4
        var tx = x - 12
        for (i, app) in favourites.enumerated() {
            drawTile(ctx, "fav:\(i)", CGRect(x: tx, y: y, width: tile, height: 108), id: app.id, name: app.name, symbol: app.symbol, icon: icons[app.id])
            tx += tile + gap
        }
        drawTile(ctx, "fav:all", CGRect(x: tx, y: y, width: tile, height: 108), id: "", name: "All apps", symbol: "square.grid.2x2", icon: nil, outlined: true)

        // Continue: up to four, as pictures (board 19).
        y += 128
        NightGlass.drawSection("Continue", at: CGPoint(x: x, y: y))
        y += 26
        guard !items.isEmpty else {
            NightGlass.drawText("Videos, pages, notes and windows you use show up here, to pick up where you left off.",
                                at: CGPoint(x: x, y: y + 8), style: .label, color: NightGlass.secondary, width: right - x)
            return
        }
        let cw = (right - x - 36) / 4, ch: CGFloat = 150
        for (i, item) in items.enumerated() {
            let rect = CGRect(x: x + CGFloat(i) * (cw + 12), y: y, width: cw, height: ch)
            row(ctx, "cont:\(i)", rect, radius: 20, rest: 0.06)
            let (app, chip): (String, String) = switch item.kind {
            case .video: ("halliday:videos", "Videos")
            case .page: ("halliday:browser", "Browser")
            case .note: ("halliday:notes", "Notes")
            case .windows: ("halliday:windows", "Mac windows")
            }
            let picture = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 94)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.clip()
            NightGlass.drawPictureArea(ctx, picture, radius: 0, colors: NightGlass.appColors(app) ?? (NightGlass.accent, NightGlass.accent), symbol: item.symbol, chipText: chip)
            ctx.restoreGState()
            NightGlass.drawText(item.title, at: CGPoint(x: rect.minX + 12, y: picture.maxY + 10), style: .label, weight: .semibold, width: rect.width - 24)
            NightGlass.drawText(item.detail, at: CGPoint(x: rect.minX + 12, y: picture.maxY + 31), style: .caption, color: NightGlass.secondary, width: rect.width - 24)
        }
    }

    private func drawTile(_ ctx: CGContext, _ id: String, _ rect: CGRect, id app: String, name: String, symbol: String?, icon: CGImage?, outlined: Bool = false) {
        row(ctx, id, rect, radius: 22)
        let iconRect = CGRect(x: rect.midX - 33, y: rect.minY + 8, width: 66, height: 66)
        if let icon {
            ctx.saveGState()
            ctx.translateBy(x: iconRect.minX, y: iconRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(icon, in: CGRect(origin: .zero, size: iconRect.size))
            ctx.restoreGState()
        } else if outlined {
            NightGlass.fill(ctx, iconRect, radius: 20, color: NSColor(white: 1, alpha: 0.10))
            if let symbol { NightGlass.drawSymbol(symbol, in: iconRect, size: 24, color: NightGlass.text, weight: .medium) }
        } else if let colors = NightGlass.appColors(app) {
            NightGlass.drawAppTile(ctx, iconRect, radius: 20, colors: colors, symbol: symbol, symbolSize: 26)
        } else {
            NightGlass.fill(ctx, iconRect, radius: 20, color: NSColor(white: 1, alpha: 0.08))
            if let symbol { NightGlass.drawSymbol(symbol, in: iconRect, size: 26, color: NightGlass.secondary, weight: .medium) }
        }
        let s = NightGlass.textSize(name, style: .label)
        NightGlass.drawText(name, at: CGPoint(x: rect.midX - min(s.width, rect.width - 8) / 2, y: iconRect.maxY + 9), style: .label, width: rect.width - 8)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
