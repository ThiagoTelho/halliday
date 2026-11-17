// The browser's own settings (ROADMAP W11 B.5): a small Night Glass panel beside the browser,
// opened from the gear in its bar. What sites see, the home page, the history and page zoom. (The
// general settings are in SettingsPanel.)

import AppKit

@MainActor
final class BrowserSettings: VRPanel {
    private let settings = Settings.shared
    private weak var browser: BrowserWindow?
    var onClose: (() -> Void)?
    var onNotice: ((String) -> Void)?

    private static let margin: CGFloat = 20
    private static let width: CGFloat = 340, height: CGFloat = 510
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer, browser: BrowserWindow) {
        self.browser = browser
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
        setNeedsDisplay()
    }

    private func activate(_ id: String) {
        switch id {
        case "close": onClose?()
        case "identity:vision": setIdentity(true)
        case "identity:mac": setIdentity(false)
        case "home:start": settings.homePage = ""
        case "home:current":
            if let page = browser?.displayURL, page.hasPrefix("http") { settings.homePage = page } else { onNotice?("Open the page you want as home first") }
        case "history:show": browser?.showHistory()
        case "history:clear":
            BrowserHistory.shared.clearHistory()
            onNotice?("The browser's history was cleared")
        case "zoom:out": browser?.zoom(-1)
        case "zoom:in": browser?.zoom(1)
        case "zoom:reset": browser?.zoom(0)
        default:
            if id.hasPrefix("vrsize:"), let eye = Int(id.dropFirst(7)), eye != settings.vrPageEye {
                settings.vrPageEye = eye
                onNotice?("VR pages entered from now on render \(eye) pixels per eye")
            }
        }
        setNeedsDisplay()
    }

    private func setIdentity(_ vision: Bool) {
        guard settings.visionIdentity != vision else { return }
        settings.visionIdentity = vision
        onNotice?("Sites will see \(vision ? "an Apple Vision Pro" : "a Mac") in browser windows opened from now on")
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let x = g.minX + 22, w = g.width - 44
        NightGlass.drawText("Browser", at: CGPoint(x: x, y: g.minY + 18), style: .title)
        let close = CGRect(x: g.maxX - 54, y: g.minY + 12, width: 40, height: 40)
        iconButton(ctx, "close", "xmark", close, symbolSize: 14, quiet: true)
        var y = g.minY + 64

        y = label(ctx, "Sites see", x: x, y: y)
        y = segmented(ctx, [("identity:vision", "Vision Pro", settings.visionIdentity), ("identity:mac", "Mac", !settings.visionIdentity)], x: x, y: y, width: w)

        y = label(ctx, "Home page", x: x, y: y + 6)
        let home = settings.homePage.isEmpty ? "Halliday's start page" : (URL(string: settings.homePage)?.host ?? settings.homePage)
        NightGlass.drawText(home, at: CGPoint(x: x, y: y), style: .label, width: w)
        y += 26
        let half = (w - 8) / 2
        button(ctx, "home:start", "Start page", CGRect(x: x, y: y, width: half, height: 40))
        button(ctx, "home:current", "This page", CGRect(x: x + half + 8, y: y, width: half, height: 40))
        y += 52

        y = label(ctx, "Zoom", x: x, y: y + 6)
        let zoom = Int(((browser?.active?.webView.pageZoom ?? 1) * 100).rounded())
        button(ctx, "zoom:out", "−", CGRect(x: x, y: y, width: 56, height: 40))
        button(ctx, "zoom:reset", "\(zoom)%", CGRect(x: x + 64, y: y, width: w - 128, height: 40))
        button(ctx, "zoom:in", "+", CGRect(x: x + w - 56, y: y, width: 56, height: 40))
        y += 52

        y = label(ctx, "VR pages", x: x, y: y + 6)
        let names = ["Fast", "Balanced", "Sharp", "Sharpest"]
        y = segmented(ctx, zip(Settings.vrPageSizes, names).map { ("vrsize:\($0.0)", $0.1, settings.vrPageEye == $0.0) }, x: x, y: y, width: w)

        y = label(ctx, "History", x: x, y: y + 6)
        let pages = BrowserHistory.shared.recent.count, marks = BrowserHistory.shared.bookmarks.count
        NightGlass.drawText("\(pages) page\(pages == 1 ? "" : "s") · \(marks) bookmark\(marks == 1 ? "" : "s")", at: CGPoint(x: x, y: y), style: .label)
        y += 26
        button(ctx, "history:show", "Show history", CGRect(x: x, y: y, width: half, height: 40), enabled: pages > 0)
        button(ctx, "history:clear", "Clear history", CGRect(x: x + half + 8, y: y, width: half, height: 40), enabled: pages > 0)
    }

    private func label(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat) -> CGFloat {
        NightGlass.drawSection(text, at: CGPoint(x: x, y: y - 2))
        return y + 22
    }


}
