// The app launcher (ROADMAP W13.1): an Apps panel in Night Glass. Halliday's own apps first, then
// the Mac's applications with their icons. Typing on the Mac keyboard filters the list. Choosing a
// Mac app starts it (or uses it if it is running) and its window is brought into VR.

import AppKit

@MainActor
final class AppLauncher: VRPanel {
    struct App: Equatable {
        /// "halliday:browser" for Halliday's own; the bundle path for a Mac app.
        let id: String
        let name: String
        let url: URL?
        let symbol: String?
    }

    /// Called with the app the user chose.
    var onLaunch: ((App) -> Void)?
    var onClose: (() -> Void)?

    static let own = [
        App(id: "halliday:browser", name: "Browser", url: nil, symbol: "globe"),
        App(id: "halliday:videos", name: "Videos", url: nil, symbol: "play.rectangle"),
        App(id: "halliday:files", name: "Files", url: nil, symbol: "folder"),
        App(id: "halliday:photos", name: "Photos", url: nil, symbol: "photo.on.rectangle"),
        App(id: "halliday:notes", name: "Notes", url: nil, symbol: "note.text"),
        App(id: "halliday:clock", name: "Clock", url: nil, symbol: "timer"),
        App(id: "halliday:music", name: "Music", url: nil, symbol: "music.note"),
        App(id: "halliday:games", name: "Games", url: nil, symbol: "gamecontroller"),
        App(id: "halliday:windows", name: "Mac Windows", url: nil, symbol: "macwindow.on.rectangle"),
        App(id: "halliday:settings", name: "Settings", url: nil, symbol: "gearshape"),
        App(id: "halliday:controls", name: "Controls", url: nil, symbol: "dpad"),
    ]
    private var macApps: [App] = []
    private var filter = ""
    /// The Mac's apps are being read for the first time.
    private var scanning = false
    private var icons: [String: CGImage] = [:]
    private var scroll = 0
    private var scrollRemainder: CGFloat = 0

    static let distance: Float = 1.2
    static let below: Float = 4

    // Layout (dmm).
    private static let margin: CGFloat = 24
    private static let width: CGFloat = 960, height: CGFloat = 620
    private static let header: CGFloat = 76, columns = 6, rows = 3, inset: CGFloat = 20
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }
    private static var cell: CGSize {
        CGSize(width: (width - 2 * inset) / CGFloat(columns), height: (height - header - inset) / CGFloat(rows))
    }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
        // Held for a moment, an app is pinned to Home (or unpinned) instead of opened.
        onPress = { [weak self] id in
            guard id.hasPrefix("app:") else { return }
            self?.holdTimer?.invalidate()
            self?.holdTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.held(id) }
            }
        }
    }

    private var holdTimer: Timer?
    /// Called with a message after an app was pinned or unpinned.
    var onNotice: ((String) -> Void)?

    private func held(_ id: String) {
        guard pressed == id, let i = Int(id.dropFirst(4)), shown.indices.contains(i) else { return }
        let app = shown[i]
        cancelPress() // the release that follows doesn't open it
        switch HomePanel.togglePin(app.id) {
        case true?: onNotice?("\(app.name) is on Home")
        case false?: onNotice?("\(app.name) was taken off Home")
        case nil: onNotice?("Home has room for \(HomePanel.maxFavourites) favourites: hold one to take it off first")
        }
        Sounds.play(.release)
        setNeedsDisplay(fade: true)
    }

    /// Clears the filter and re-reads the Mac's applications (they come and go).
    func prepare() {
        filter = ""
        scroll = 0
        snap("scroll")
        scanning = macApps.isEmpty
        setNeedsDisplay()
        Task.detached(priority: .userInitiated) {
            let found = Self.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanning = false
                if found != self.macApps { self.macApps = found }
                self.setNeedsDisplay()
            }
        }
    }

    /// The applications in the usual folders, by name.
    private nonisolated static func scan() -> [App] {
        let fm = FileManager.default
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen: Set<String> = [], list: [App] = []
        let own = Bundle.main.bundleURL.standardizedFileURL.path
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = folder + "/" + item
                guard path != own, seen.insert(item).inserted else { continue }
                list.append(App(id: path, name: fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                                url: URL(fileURLWithPath: path), symbol: nil))
            }
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var shown: [App] {
        let all = Self.own + macApps
        guard !filter.isEmpty else { return all }
        let f = filter.lowercased()
        // Names that start with what was typed first, then names that contain it.
        return all.filter { $0.name.lowercased().hasPrefix(f) } + all.filter { !$0.name.lowercased().hasPrefix(f) && $0.name.lowercased().contains(f) }
    }

    private var totalRows: Int { (shown.count + Self.columns - 1) / Self.columns }

    /// A key press while the launcher is open: letters filter, Delete erases, Return opens the first
    /// match. Returns true if the key was used.
    func key(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        switch event.keyCode {
        case 53: return false // Esc closes (handled by the owner)
        case 36, 76:
            if let first = shown.first { onLaunch?(first) }
            return true
        case 51:
            if !filter.isEmpty { filter.removeLast() }
        default:
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) })
            else { return true }
            filter += chars
        }
        scroll = 0
        snap("scroll")
        setNeedsDisplay()
        return true
    }

    /// Text from the virtual keyboard.
    func insert(_ text: String) {
        filter += text
        scroll = 0
        snap("scroll")
        setNeedsDisplay()
    }

    func deleteBackward() {
        guard !filter.isEmpty else { return }
        filter.removeLast()
        scroll = 0
        snap("scroll")
        setNeedsDisplay()
    }

    func commit() { if let first = shown.first { onLaunch?(first) } }

    func scroll(by dy: CGFloat) {
        scrollRemainder -= dy
        let rows = Int(scrollRemainder / 40)
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows) * 40
        setScroll(scroll + rows)
    }

    private func setScroll(_ value: Int) {
        let clamped = max(0, min(max(0, totalRows - Self.rows), value))
        guard clamped != scroll else { return }
        scroll = clamped
        setNeedsDisplay()
    }

    private func activate(_ id: String) {
        switch id {
        case "close": onClose?()
        case "clear":
            filter = ""
            scroll = 0
        snap("scroll")
            setNeedsDisplay()
        case "pageup": setScroll(scroll - Self.rows); setNeedsDisplay(fade: true)
        case "pagedown": setScroll(scroll + Self.rows); setNeedsDisplay(fade: true)
        default:
            guard id.hasPrefix("app:"), let i = Int(id.dropFirst(4)) else { return }
            let list = shown
            if list.indices.contains(i) { onLaunch?(list[i]) }
        }
    }

    // Icons are never loaded while drawing (reading an app's icon takes several milliseconds, and a
    // page has 18): a page is drawn with placeholders at once and its icons arrive one at a time,
    // each rendered once at exactly the size it is shown.
    private var iconsRequested: Set<String> = []
    private var iconQueue: [App] = []
    private var loadingIcons = false

    private func icon(for app: App) -> CGImage? {
        if let cached = icons[app.id] { return cached }
        if app.url != nil, iconsRequested.insert(app.id).inserted {
            iconQueue.append(app)
            loadIcons()
        }
        return nil
    }

    private func loadIcons() {
        guard !loadingIcons else { return }
        loadingIcons = true
        Task { @MainActor [weak self] in
            var sinceRedraw = 0
            while let self, !self.iconQueue.isEmpty {
                let app = self.iconQueue.removeFirst()
                if let url = app.url, let image = Self.render(NSWorkspace.shared.icon(forFile: url.path)) { self.icons[app.id] = image }
                sinceRedraw += 1
                if sinceRedraw >= 3 || self.iconQueue.isEmpty {
                    sinceRedraw = 0
                    self.setNeedsDisplay()
                }
                try? await Task.sleep(nanoseconds: 4_000_000) // leave the frame its time
            }
            self?.loadingIcons = false
        }
    }

    /// The icon as a bitmap of exactly the pixels it covers on the panel.
    static func renderIcon(_ icon: NSImage) -> CGImage? { render(icon) }

    private static func render(_ icon: NSImage) -> CGImage? {
        let side = Int(72 * pixelsPerDmm)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        icon.draw(in: CGRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let left = g.minX + Self.inset, right = g.maxX - Self.inset
        let headerMid = g.minY + Self.header / 2

        NightGlass.drawText("Apps", at: CGPoint(x: left + 12, y: g.minY + 18), style: .title)
        let hint = filter.isEmpty ? "Type to search · hold an app to pin it to Home" : "“\(filter)”"
        NightGlass.drawText(hint, at: CGPoint(x: left + 12, y: g.minY + 46), style: .caption,
                            color: filter.isEmpty ? NightGlass.tertiary : NightGlass.accent)
        iconButton(ctx, "close", "xmark", CGRect(x: right - 40, y: headerMid - 20, width: 40, height: 40), symbolSize: 14, quiet: true)
        if totalRows > Self.rows {
            iconButton(ctx, "pagedown", "chevron.down", CGRect(x: right - 88, y: headerMid - 20, width: 40, height: 40),
                       enabled: scroll + Self.rows < totalRows)
            iconButton(ctx, "pageup", "chevron.up", CGRect(x: right - 132, y: headerMid - 20, width: 40, height: 40), enabled: scroll > 0)
        }

        let list = shown
        if list.isEmpty {
            message(ctx, in: CGRect(x: left, y: g.minY + Self.header, width: right - left, height: g.maxY - g.minY - Self.header - Self.inset),
                    symbol: "magnifyingglass", title: "No app is called “\(filter)”",
                    detail: "Apps in the Mac's Applications folders are listed here.", action: ("clear", "Clear search"))
            return
        }
        let cell = Self.cell
        // The grid, clipped to its area.
        // (Scrolling is instant: a glide redrew the whole panel every frame, too slow for 120 Hz; the
        // page buttons cross-fade instead. A glide on the GPU is for later.)
        let offset = CGFloat(scroll)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: left - 4, y: g.minY + Self.header, width: right - left + 8, height: CGFloat(Self.rows) * cell.height))
        let firstRow = max(0, Int(offset.rounded(.down)))
        let start = firstRow * Self.columns, end = min(list.count, (Int(offset.rounded(.up)) + Self.rows) * Self.columns)
        for index in start..<max(start, end) {
            let app = list[index]
            let id = "app:\(index)"
            let rect = CGRect(x: left + CGFloat(index % Self.columns) * cell.width,
                              y: g.minY + Self.header + (CGFloat(index / Self.columns) - offset) * cell.height,
                              width: cell.width, height: cell.height).insetBy(dx: 4, dy: 4)
            row(ctx, id, rect, radius: 20)
            let iconRect = CGRect(x: rect.midX - 36, y: rect.minY + 22, width: 72, height: 72)
            if let symbol = app.symbol {
                // Halliday's own apps: each its lit tile (board 19).
                if let colors = NightGlass.appColors(app.id) {
                    NightGlass.drawAppTile(ctx, iconRect, radius: 20, colors: colors, symbol: symbol, symbolSize: 29)
                } else {
                    NightGlass.fill(ctx, iconRect, radius: 18, color: NightGlass.accent.withAlphaComponent(0.20))
                    NightGlass.drawSymbol(symbol, in: iconRect, size: 28, color: NightGlass.accent, weight: .medium)
                }
            } else if let image = icon(for: app) {
                ctx.saveGState()
                ctx.translateBy(x: iconRect.minX, y: iconRect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .none // already at its size
                ctx.draw(image, in: CGRect(origin: .zero, size: iconRect.size))
                ctx.restoreGState()
            } else {
                skeleton(ctx, iconRect.insetBy(dx: 4, dy: 4), radius: 16) // its icon is on the way
            }
            if HomePanel.favouriteIDs.contains(app.id) {
                NightGlass.drawSymbol("pin.fill", in: CGRect(x: iconRect.maxX - 6, y: iconRect.minY - 8, width: 20, height: 20), size: 11,
                                      color: NightGlass.accent, weight: .semibold)
            }
            let nameWidth = rect.width - 12
            let size = NightGlass.textSize(app.name, style: .label)
            NightGlass.drawText(app.name, at: CGPoint(x: rect.midX - min(size.width, nameWidth) / 2, y: iconRect.maxY + 12), style: .label,
                                width: nameWidth)
        }
        ctx.restoreGState()
        // The Mac's apps are still being read: their places, in the shape of what is coming.
        if scanning, filter.isEmpty {
            for k in list.count..<(Self.columns * Self.rows) {
                let rect = CGRect(x: left + CGFloat(k % Self.columns) * cell.width, y: g.minY + Self.header + CGFloat(k / Self.columns) * cell.height,
                                  width: cell.width, height: cell.height).insetBy(dx: 4, dy: 4)
                let s = max(0.25, 1 - CGFloat(k - list.count) * 0.07)
                skeleton(ctx, CGRect(x: rect.midX - 32, y: rect.minY + 26, width: 64, height: 64), radius: 16, strength: s)
                skeleton(ctx, CGRect(x: rect.midX - 36, y: rect.minY + 108, width: 72, height: 10), radius: 5, strength: s)
            }
        }
    }

}
