// The window picker (ROADMAP W5 5.9, rebuilt in W12 A.2): a Night Glass panel listing every window
// of the Mac's apps, to bring them into VR or send them back. Every window is listed (the grid
// scrolls); one that can't come in as it is says why, and where there is a way (a minimized or
// full-screen window) a click takes it. Opened with M or the dock's Windows button.

import AppKit
import ScreenCaptureKit

@MainActor
final class WindowPicker: VRPanel {
    private let manager: WindowManager
    private(set) var isOpen = false
    var onClose: (() -> Void)?
    /// Called with a message for the user when a click can't do what was asked.
    var onNotice: ((String) -> Void)?
    /// The empty panel's way forward: the app launcher.
    var onOpenApps: (() -> Void)?

    private var candidates: [WindowManager.Candidate] = []
    private var thumbnails: [CGWindowID: CGImage] = [:]
    private var thumbnailsRequested: Set<CGWindowID> = []
    private var loading = false
    /// Windows being brought in or sent back right now.
    private var busy: Set<CGWindowID> = []
    /// First visible row of cards.
    private var scroll = 0
    private var scrollRemainder: CGFloat = 0
    private var refreshTimer: Timer?

    static let distance: Float = 1.2
    static let below: Float = 4

    // Layout (dmm).
    private static let margin: CGFloat = 24
    private static let width: CGFloat = 960, height: CGFloat = 700
    private static let header: CGFloat = 76, columns = 3, rows = 2, gap: CGFloat = 14, inset: CGFloat = 20
    /// The layout bar along the bottom (design board 11).
    private static let footer: CGFloat = 80
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }
    private static var card: CGSize {
        CGSize(width: (width - 2 * inset - CGFloat(columns - 1) * gap) / CGFloat(columns),
               height: (height - header - footer - inset - CGFloat(rows - 1) * gap) / CGFloat(rows))
    }
    private var totalRows: Int { (candidates.count + Self.columns - 1) / Self.columns }

    init(renderer: Renderer, manager: WindowManager) {
        self.manager = manager
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
    }

    func open() {
        isOpen = true
        scroll = 0
        snap("scroll")
        reload()
        // The Mac's windows change while the panel is open: keep the list current.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(quiet: true) }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        onClose?()
    }

    /// Re-reads the window list; `quiet` keeps the current list on screen meanwhile.
    private func reload(quiet: Bool = false) {
        if !quiet {
            loading = true
            setNeedsDisplay()
        }
        Task { @MainActor in
            let list = await manager.candidates() ?? []
            guard isOpen else { return }
            loading = false
            if list.map(\.key) != candidates.map(\.key) {
                candidates = list
                setScroll(scroll, force: true)
            }
            // Thumbnails of windows that left are dropped; new ones are fetched.
            let ids = Set(list.map(\.window.windowID))
            thumbnails = thumbnails.filter { ids.contains($0.key) }
            requestThumbnails()
        }
    }

    private var visible: ArraySlice<WindowManager.Candidate> {
        candidates.dropFirst(scroll * Self.columns).prefix(Self.columns * Self.rows)
    }

    private func requestThumbnails() {
        let wanted = visible.filter { $0.window.isOnScreen && !thumbnailsRequested.contains($0.window.windowID) }.map(\.window)
        guard !wanted.isEmpty else { return }
        for w in wanted { thumbnailsRequested.insert(w.windowID) }
        Task { @MainActor [weak self] in
            for w in wanted {
                guard let image = await Self.thumbnail(of: w), let self else { continue }
                thumbnails[w.windowID] = Self.fitted(image)
                if isOpen { setNeedsDisplay() }
            }
        }
    }

    /// The thumbnail at the size it is drawn (scaling a large capture on every redraw is slow).
    private static func fitted(_ image: CGImage) -> CGImage {
        let area = CGSize(width: (card.width - 24) * pixelsPerDmm, height: (card.height - 98) * pixelsPerDmm)
        let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height), 1)
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    private static func thumbnail(of window: SCWindow) async -> CGImage? {
        let config = SCStreamConfiguration()
        let scale = min(1, 420 / max(window.frame.width, 1))
        config.width = max(2, Int(window.frame.width * scale * 2))
        config.height = max(2, Int(window.frame.height * scale * 2))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                            configuration: config)
    }

    /// Scrolls the grid (mouse wheel); `dy` in points.
    func scroll(by dy: CGFloat) {
        scrollRemainder -= dy
        let rows = Int(scrollRemainder / 40)
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows) * 40
        setScroll(scroll + rows)
    }

    private func setScroll(_ value: Int, force: Bool = false) {
        let clamped = max(0, min(max(0, totalRows - Self.rows), value))
        guard clamped != scroll || force else { return }
        scroll = clamped
        setNeedsDisplay()
        requestThumbnails()
    }

    private func activate(_ id: String) {
        switch id {
        case "close": close()
        case "layout:remember": Settings.shared.rememberLayouts.toggle()
        case "layout:arc-all": manager.bringAllToArc()
        case "apps": onOpenApps?()
        case "permission":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            onNotice?("System Settings is open on the Mac's screen")
        case "pageup": setScroll(scroll - Self.rows); setNeedsDisplay(fade: true)
        case "pagedown": setScroll(scroll + Self.rows); setNeedsDisplay(fade: true)
        default:
            if id.hasPrefix("layout:"), let l = WindowManager.Layout(rawValue: String(id.dropFirst(7))) {
                manager.setLayout(l)
                setNeedsDisplay(fade: true)
                return
            }
            guard id.hasPrefix("card:"), let i = Int(id.dropFirst(5)), candidates.indices.contains(i) else { return }
            choose(candidates[i])
        }
    }

    private func choose(_ c: WindowManager.Candidate) {
        let id = c.window.windowID
        guard !busy.contains(id) else { return }
        busy.insert(id)
        setNeedsDisplay()
        Task { @MainActor in
            if c.state == .inVR {
                manager.sendBack(id)
            } else {
                await manager.bring(c)
            }
            busy.remove(id)
            thumbnailsRequested.remove(id)
            if isOpen { reload(quiet: true) }
            setNeedsDisplay()
        }
    }

    // --- Drawing ---

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let left = g.minX + Self.inset, right = g.maxX - Self.inset

        NightGlass.drawText("Windows", at: CGPoint(x: left + 4, y: g.minY + 18), style: .title)
        let count = "\(manager.windows.count) of \(manager.maxWindows) in VR"
        NightGlass.drawText(count, at: CGPoint(x: left + 4, y: g.minY + 46), style: .caption, color: NightGlass.secondary, tabular: true)
        let headerMid = g.minY + Self.header / 2
        iconButton(ctx, "close", "xmark", CGRect(x: right - 40, y: headerMid - 20, width: 40, height: 40), symbolSize: 14, quiet: true)
        if totalRows > Self.rows {
            iconButton(ctx, "pagedown", "chevron.down", CGRect(x: right - 88, y: headerMid - 20, width: 40, height: 40),
                       enabled: scroll + Self.rows < totalRows)
            iconButton(ctx, "pageup", "chevron.up", CGRect(x: right - 132, y: headerMid - 20, width: 40, height: 40), enabled: scroll > 0)
            let first = scroll * Self.columns + 1, last = min(candidates.count, (scroll + Self.rows) * Self.columns)
            let text = "\(first)–\(last) of \(candidates.count)"
            let size = NightGlass.textSize(text, style: .caption)
            NightGlass.drawText(text, at: CGPoint(x: right - 144 - size.width, y: headerMid - size.height / 2), style: .caption,
                                color: NightGlass.tertiary)
        }

        drawLayoutBar(ctx, left: left, right: right, bottom: g.maxY - 18)
        let cardSize = Self.card
        if candidates.isEmpty {
            let area = CGRect(x: left, y: g.minY + Self.header, width: right - left, height: g.maxY - g.minY - Self.header - Self.inset)
            if loading {
                // Cards in the shape of what is coming.
                for k in 0..<(Self.columns * Self.rows) {
                    let rect = CGRect(x: left + CGFloat(k % Self.columns) * (cardSize.width + Self.gap),
                                      y: g.minY + Self.header + CGFloat(k / Self.columns) * (cardSize.height + Self.gap),
                                      width: cardSize.width, height: cardSize.height)
                    let s = max(0.3, 1 - CGFloat(k) * 0.14)
                    skeleton(ctx, CGRect(x: rect.minX + 12, y: rect.minY + 12, width: rect.width - 24, height: rect.height - 98), radius: 10, strength: s)
                    skeleton(ctx, CGRect(x: rect.minX + 16, y: rect.maxY - 64, width: 150, height: 10), radius: 5, strength: s)
                    skeleton(ctx, CGRect(x: rect.minX + 16, y: rect.maxY - 36, width: 100, height: 8), radius: 4, strength: s)
                }
            } else if !manager.hasPermission {
                message(ctx, in: area, symbol: "lock", title: "macOS hasn't let Halliday see the Mac's windows",
                        detail: "Allow Halliday under Screen Recording in System Settings, on the Mac's screen, then try again.",
                        action: ("permission", "Open System Settings"), problem: true)
            } else {
                message(ctx, in: area, symbol: "macwindow", title: "No windows are open on the Mac",
                        detail: "Windows of the Mac's apps are listed here, to bring into VR.", action: ("apps", "Open an app"))
            }
            return
        }

        // The cards, clipped to their area.
        // (Scrolling is instant: a glide redrew the whole panel every frame, too slow for 120 Hz; the
        // page buttons cross-fade instead. A glide on the GPU is for later.)
        let offset = CGFloat(scroll)
        let rowStep = cardSize.height + Self.gap
        ctx.saveGState()
        ctx.clip(to: CGRect(x: left - 4, y: g.minY + Self.header, width: right - left + 8, height: CGFloat(Self.rows) * rowStep - Self.gap))
        let firstRow = max(0, Int(offset.rounded(.down)))
        let start = firstRow * Self.columns, end = min(candidates.count, (Int(offset.rounded(.up)) + Self.rows) * Self.columns)
        for index in start..<max(start, end) {
            let c = candidates[index]
            let id = "card:\(index)"
            let rect = CGRect(x: left + CGFloat(index % Self.columns) * (cardSize.width + Self.gap),
                              y: g.minY + Self.header + (CGFloat(index / Self.columns) - offset) * rowStep,
                              width: cardSize.width, height: cardSize.height)
            let isBusy = busy.contains(c.window.windowID)
            row(ctx, id, rect, radius: 20, selected: c.state == .inVR, rest: 0.06, enabled: !isBusy)

            // Thumbnail, fitted into the top of the card.
            let area = CGRect(x: rect.minX + 12, y: rect.minY + 12, width: rect.width - 24, height: rect.height - 98)
            if let image = thumbnails[c.window.windowID] {
                let aspect = CGFloat(image.width) / CGFloat(image.height)
                var fit = area
                if aspect > area.width / area.height {
                    fit.size.height = area.width / aspect
                    fit.origin.y += (area.height - fit.height) / 2
                } else {
                    fit.size.width = area.height * aspect
                    fit.origin.x += (area.width - fit.width) / 2
                }
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: fit, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.clip()
                ctx.translateBy(x: fit.minX, y: fit.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.setAlpha(isBusy ? 0.4 : 1)
                ctx.draw(image, in: CGRect(origin: .zero, size: fit.size))
                ctx.restoreGState()
            } else {
                NightGlass.fill(ctx, area, radius: 10, color: NSColor(white: 1, alpha: 0.04))
                let symbol: String
                switch c.state {
                case .minimized: symbol = "arrow.down.right.and.arrow.up.left"
                case .fullScreen: symbol = "arrow.up.left.and.arrow.down.right"
                case .otherSpace: symbol = "rectangle.on.rectangle.slash"
                default: symbol = "macwindow"
                }
                NightGlass.drawSymbol(symbol, in: area, size: 24, color: NightGlass.tertiary)
            }

            let textWidth = rect.width - 32
            // "App — Title" when the second line is taken by the window's state.
            let named = c.state == .ready || c.title.isEmpty || c.title == c.appName ? c.appName : "\(c.appName) — \(c.title)"
            NightGlass.drawText(named, at: CGPoint(x: rect.minX + 16, y: rect.maxY - 70), style: .body, color: NightGlass.text,
                                weight: .medium, width: textWidth)
            let (detail, color): (String, NSColor)
            if isBusy {
                (detail, color) = (c.state == .inVR ? "Sending back…" : "Bringing in…", NightGlass.accent)
            } else {
                switch c.state {
                case .inVR: (detail, color) = ("In VR · click to send back", NightGlass.accent)
                case .ready: (detail, color) = (c.title.isEmpty ? "Untitled" : c.title, NightGlass.secondary)
                case .minimized: (detail, color) = ("Minimized · click to bring in", NightGlass.secondary)
                case .fullScreen: (detail, color) = ("Full screen · click to bring in", NightGlass.secondary)
                case .otherSpace: (detail, color) = ("In another Space · click to bring in", NightGlass.secondary)
                }
            }
            if isBusy { spinner(ctx, center: CGPoint(x: rect.minX + 23, y: rect.maxY - 31), radius: 6) }
            NightGlass.drawText(detail, at: CGPoint(x: rect.minX + (isBusy ? 38 : 16), y: rect.maxY - 38), style: .caption, color: color, width: textWidth - (isBusy ? 22 : 0))
        }
        ctx.restoreGState()
    }


    /// Layout: the four arrangements, remembering them for these apps, and everything back to the arc.
    private func drawLayoutBar(_ ctx: CGContext, left: CGFloat, right: CGFloat, bottom: CGFloat) {
        let y = bottom - 44
        ctx.setFillColor(NightGlass.hairline.cgColor)
        ctx.fill(CGRect(x: left, y: y - 16, width: right - left, height: 1))
        NightGlass.drawSection("Layout", at: CGPoint(x: left + 4, y: y + 12))
        segmented(ctx, WindowManager.Layout.allCases.map { ("layout:\($0.rawValue)", $0.label, manager.layout == $0) },
                  x: left + 76, y: y, width: 420)
        let back = "Back to the arc"
        let bw = NightGlass.textSize(back, style: .label, weight: .medium).width + 40
        button(ctx, "layout:arc-all", back, CGRect(x: right - bw, y: y, width: bw, height: 44), symbol: "arrow.uturn.backward",
               enabled: manager.layout != .arc || manager.windows.contains { $0.placement != nil })
        let label = "Remember for these apps"
        let lw = NightGlass.textSize(label, style: .label).width
        toggle(ctx, "layout:remember", Settings.shared.rememberLayouts, CGRect(x: right - bw - 76, y: y + 7, width: 52, height: 30))
        NightGlass.drawText(label, at: CGPoint(x: right - bw - 88 - lw, y: y + 13), style: .label, color: NightGlass.secondary)
    }
}
