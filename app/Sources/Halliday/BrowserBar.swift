// The browser's bar in VR (ROADMAP W11.B, A.7): tabs, toolbar and address bar drawn by Halliday in
// Night Glass above the browser's page (the window itself shows only the page). The address bar is
// typed with the Mac keyboard (AppDelegate routes key presses here) or the virtual keyboard; while
// typing, matching bookmarks and visited pages are suggested under it. The same field searches the
// page (the magnifier button, or ⌘F).

import AppKit

@MainActor
final class BrowserBar: VRPanel {
    private weak var browser: BrowserWindow?
    /// The glass's width in dmm (the page's width as seen from the viewer).
    let barWidth: CGFloat

    private struct Tab: Equatable {
        var title: String
        var isPrivate: Bool
        var isLoading: Bool
    }

    /// What the text field is being used for.
    enum Field: Equatable { case address, find }

    private struct Model: Equatable {
        var tabs: [Tab] = []
        var active = 0
        var url = ""
        var canGoBack = false, canGoForward = false, hasVideo = false, bookmarked = false
        /// The text being typed; nil when not editing.
        var editing: String?
        var field = Field.address
        /// The whole text is selected (typing replaces it), as after focusing the bar.
        var allSelected = false
        var suggestions: [BrowserHistory.Suggestion] = []
        /// The suggestion chosen with the arrow keys, if any.
        var selected: Int?
        /// Find: the last search found nothing.
        var notFound = false
    }

    private var model = Model() {
        didSet {
            guard model != oldValue else { return }
            // The suggestions hang below the glass, over the page: that area takes the pointer and
            // is drawn over the page only while they are shown.
            extraSurface = model.suggestions.isEmpty ? nil : dropdown(count: model.suggestions.count)
            layer.sortBias = model.suggestions.isEmpty ? 0 : 0.3
            setNeedsDisplay()
        }
    }

    var isEditing: Bool { model.editing != nil }
    /// Called when the field starts being edited: Halliday must have the keyboard.
    var onWantsKeyboard: (() -> Void)?
    /// The bar's "new window" and "settings" buttons.
    var onNewWindow: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Called with a message for the user (find: no match).
    var onNotice: ((String) -> Void)?

    // Layout (dmm).
    private static let margin: CGFloat = 20 // room for the shadow
    private static let height: CGFloat = 116
    private static let suggestionRow: CGFloat = 48
    private static let dropdownRoom: CGFloat = 5 * suggestionRow + 20
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: barWidth, height: Self.height) }
    /// The address field as last drawn.
    private var fieldRect = CGRect.zero

    init(renderer: Renderer, browser: BrowserWindow, width: CGFloat) {
        self.browser = browser
        barWidth = width
        let size = CGSize(width: width + 2 * Self.margin, height: Self.height + 2 * Self.margin + Self.dropdownRoom)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
        refresh()
    }

    /// Re-reads the browser's state; redraws only if something shown changed.
    func refresh() {
        guard let browser else { return }
        var m = model
        m.tabs = browser.tabs.map { Tab(title: $0.title, isPrivate: $0.isPrivate, isLoading: $0.webView.isLoading) }
        m.active = browser.tabs.firstIndex { $0 === browser.active } ?? 0
        m.url = browser.displayURL
        m.canGoBack = browser.active?.webView.canGoBack ?? false
        m.canGoForward = browser.active?.webView.canGoForward ?? false
        m.hasVideo = browser.bestVideo != nil
        m.bookmarked = browser.isBookmarked
        model = m
    }

    // --- Editing the field (address or find) ---

    func beginEditing(_ field: Field = .address) {
        var m = model
        m.field = field
        m.editing = field == .address ? model.url : ""
        m.allSelected = field == .address && !model.url.isEmpty
        m.suggestions = []
        m.selected = nil
        m.notFound = false
        model = m
        onWantsKeyboard?()
    }

    func endEditing() {
        var m = model
        m.editing = nil
        m.allSelected = false
        m.suggestions = []
        m.selected = nil
        m.notFound = false
        model = m
    }

    private func setText(_ text: String) {
        var m = model
        m.editing = text
        m.allSelected = false
        m.selected = nil
        m.notFound = false
        // Private tabs don't read the history either.
        let isPrivate = browser?.active?.isPrivate == true
        m.suggestions = m.field == .address && !isPrivate ? BrowserHistory.shared.suggestions(for: text) : []
        model = m
    }

    /// Types `text` at the end of the field (keyboard, virtual keyboard, paste).
    func insert(_ text: String) {
        guard let current = model.editing else { return }
        setText(model.allSelected ? text : current + text)
    }

    func deleteBackward(all: Bool = false) {
        guard let current = model.editing else { return }
        setText(model.allSelected || all ? "" : String(current.dropLast()))
    }

    /// Return: goes to the chosen suggestion or to what was typed; in find, to the next match.
    func commit(backwards: Bool = false) {
        guard let text = model.editing else { return }
        if model.field == .find {
            browser?.find(text, backwards: backwards) { [weak self] found in
                guard let self, self.model.field == .find, self.model.editing != nil else { return }
                self.model.notFound = !found
            }
            return
        }
        let chosen = model.selected.flatMap { model.suggestions.indices.contains($0) ? model.suggestions[$0] : nil }
        endEditing()
        if let chosen { browser?.load(chosen.url) } else { browser?.navigate(text) }
    }

    /// Up/down through the suggestions.
    func moveSelection(_ step: Int) {
        guard !model.suggestions.isEmpty else { return }
        let n = model.suggestions.count
        model.selected = model.selected.map { ($0 + step + n) % n } ?? (step > 0 ? 0 : n - 1)
    }

    /// A key press while the field is being edited. Returns true if it was used.
    func key(_ event: NSEvent) -> Bool {
        guard model.editing != nil else { return false }
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: commit(backwards: event.modifierFlags.contains(.shift))
        case 53: endEditing()
        case 51: deleteBackward(all: command)
        case 125: moveSelection(1)
        case 126: moveSelection(-1)
        default:
            if command {
                if event.charactersIgnoringModifiers == "a" { model.allSelected = model.editing?.isEmpty == false }
                return event.charactersIgnoringModifiers == "a"
            }
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) })
            else { return true } // other keys: ignored while editing, not passed to Halliday's keys
            insert(chars)
        }
        return true
    }

    /// ⌘V while editing.
    func paste() {
        guard model.editing != nil, let pasted = NSPasteboard.general.string(forType: .string) else { return }
        insert(pasted.components(separatedBy: .newlines).joined(separator: " "))
    }

    // --- Actions ---

    private func activate(_ id: String) {
        guard let browser else { return }
        if id.hasPrefix("suggestion:"), let i = Int(id.dropFirst(11)), model.suggestions.indices.contains(i) {
            let s = model.suggestions[i]
            endEditing()
            browser.load(s.url)
            refresh()
            return
        }
        if id != "address" { endEditing() }
        if id.hasPrefix("tab:"), let i = Int(id.dropFirst(4)), browser.tabs.indices.contains(i) {
            browser.select(browser.tabs[i])
        } else if id.hasPrefix("close:"), let i = Int(id.dropFirst(6)), browser.tabs.indices.contains(i) {
            browser.close(browser.tabs[i])
        } else {
            switch id {
            case "newtab": browser.openNewTab(private: false)
            case "newprivate": browser.openNewTab(private: true)
            case "back": browser.goBack()
            case "forward": browser.goForward()
            case "reload": browser.reloadPage()
            case "watch": browser.watchInVR()
            case "bookmark": browser.toggleBookmark()
            case "newwindow": onNewWindow?()
            case "settings": onSettings?()
            case "find": beginEditing(.find)
            case "address": if !isEditing { beginEditing() }
            default: break
            }
        }
        refresh()
    }

    // --- Drawing ---

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        drawTabs(ctx, y: g.minY + 12, left: g.minX + 14, right: g.maxX - 14)
        drawToolbar(ctx, y: g.minY + 60, left: g.minX + 14, right: g.maxX - 14)
        drawSuggestions(ctx)
    }

    private func drawTabs(_ ctx: CGContext, y: CGFloat, left: CGFloat, right: CGFloat) {
        let h: CGFloat = 40, gap: CGFloat = 6, button: CGFloat = 40
        // Tabs share the row up to 240 each, leaving room for "+" and the buttons on the right
        // (private tab, new window, browser settings).
        let room = right - left - 4 * (button + gap)
        let n = CGFloat(max(model.tabs.count, 1))
        let width = min(240, (room - (n - 1) * gap) / n)
        var x = left
        for (i, tab) in model.tabs.enumerated() {
            let rect = CGRect(x: x, y: y, width: width, height: h)
            let isActive = i == model.active
            let id = "tab:\(i)", closeID = "close:\(i)"
            let isHovered = hovered == id || hovered == closeID
            if tab.isPrivate {
                control(id, rect)
                NightGlass.fill(ctx, rect, radius: h / 2, color: NightGlass.privateTint.withAlphaComponent(pressed == id ? 0.32 : (isActive ? 0.22 : (isHovered ? 0.16 : 0.10))))
            } else {
                row(ctx, id, rect, radius: h / 2, rest: isActive ? 0.13 : 0)
                if isHovered, hovered == closeID, !isActive { NightGlass.fill(ctx, rect, radius: h / 2, color: NSColor(white: 1, alpha: 0.10)) }
            }
            // Icon: loading arc, private mask, or a dot.
            let icon = CGRect(x: rect.minX + 12, y: rect.midY - 8, width: 16, height: 16)
            if tab.isLoading {
                spinner(ctx, center: CGPoint(x: icon.midX, y: icon.midY), radius: 6.5)
            } else if tab.isPrivate {
                NightGlass.drawSymbol("eyeglasses", in: icon, size: 13, color: NightGlass.privateTint, weight: .medium)
            } else {
                NightGlass.fill(ctx, icon.insetBy(dx: 1, dy: 1), radius: 7, color: isActive ? NightGlass.accent : NightGlass.disabled)
            }
            // Close button on the active or pointed-at tab (if the tab is wide enough for it).
            let showClose = (isActive || isHovered) && width >= 96
            let textRight = showClose ? rect.maxX - 36 : rect.maxX - 12
            let color = tab.isPrivate ? NSColor(srgbRed: 0xD4 / 255, green: 0xC6 / 255, blue: 1, alpha: 1)
                : (isActive ? NightGlass.text : NightGlass.secondary)
            if textRight - (icon.maxX + 8) > 20 {
                let size = NightGlass.textSize("Ag", style: .label)
                NightGlass.drawText(tab.title, at: CGPoint(x: icon.maxX + 8, y: rect.midY - size.height / 2), style: .label,
                                    color: color, weight: isActive ? .medium : .regular, width: textRight - (icon.maxX + 8))
            }
            if showClose {
                let close = CGRect(x: rect.maxX - 34, y: rect.midY - 14, width: 28, height: 28)
                // 40 dmm to hit, 28 to look at.
                control(closeID, close.insetBy(dx: -6, dy: -6))
                if hovered == closeID { NightGlass.fill(ctx, close, radius: 14, color: NSColor(white: 1, alpha: pressed == closeID ? 0.26 : 0.13)) }
                NightGlass.drawSymbol("xmark", in: close, size: 10, color: hovered == closeID ? .white : NightGlass.secondary, weight: .semibold)
            }
            x += width + gap
        }
        iconButton(ctx, "newtab", "plus", CGRect(x: x, y: y, width: button, height: button))
        iconButton(ctx, "settings", "gearshape", CGRect(x: right - button, y: y, width: button, height: button))
        iconButton(ctx, "newwindow", "plus.rectangle.on.rectangle", CGRect(x: right - 2 * button - 4, y: y, width: button, height: button))
        iconButton(ctx, "newprivate", "eyeglasses", CGRect(x: right - 3 * button - 8, y: y, width: button, height: button), tint: NightGlass.privateTint)
    }

    private func drawToolbar(_ ctx: CGContext, y: CGFloat, left: CGFloat, right: CGFloat) {
        let button: CGFloat = 40, h: CGFloat = 44
        var x = left
        for (id, symbol, enabled) in [("back", "chevron.left", model.canGoBack), ("forward", "chevron.right", model.canGoForward),
                                      ("reload", "arrow.clockwise", true)] {
            iconButton(ctx, id, symbol, CGRect(x: x, y: y + 2, width: button, height: button), enabled: enabled)
            x += button + 4
        }
        // Right side: find in page, bookmark, and "Watch in VR" when the page has a video.
        var end = right
        iconButton(ctx, "find", "magnifyingglass", CGRect(x: end - button, y: y + 2, width: button, height: button),
                   tint: model.field == .find && isEditing ? NightGlass.accent : nil)
        end -= button + 4
        let canBookmark = model.url.hasPrefix("http")
        iconButton(ctx, "bookmark", model.bookmarked ? "star.fill" : "star", CGRect(x: end - button, y: y + 2, width: button, height: button),
                   enabled: canBookmark, tint: model.bookmarked ? NightGlass.accent : nil)
        end -= button + 8
        if model.hasVideo {
            let label = "Watch in VR"
            let w = NightGlass.textSize(label, style: .label, weight: .semibold).width + 54
            let rect = CGRect(x: end - w, y: y + 2, width: w, height: button)
            self.button(ctx, "watch", label, rect, symbol: "play.rectangle", kind: .main)
            end = rect.minX - 8
        }
        // The field: the address, or the text searched in the page.
        let field = CGRect(x: x + 4, y: y, width: end - x - 4, height: h)
        fieldRect = field
        control("address", field)
        if isEditing { focusRing(ctx, field, color: model.notFound ? NightGlass.warning : NightGlass.accent) }
        NightGlass.fill(ctx, field, radius: h / 2, color: isEditing ? NSColor(srgbRed: 14 / 255, green: 15 / 255, blue: 21 / 255, alpha: 1)
            : NSColor(white: 0, alpha: hovered == "address" ? 0.42 : 0.32))
        let secure = model.url.hasPrefix("https://")
        NightGlass.drawSymbol(isEditing || model.url.isEmpty ? "magnifyingglass" : (secure ? "lock.fill" : "globe"),
                              in: CGRect(x: field.minX + 14, y: field.minY, width: 18, height: h), size: 12, color: NightGlass.secondary, weight: .medium)
        let textX = field.minX + 40, textWidth = field.width - 58
        let lineHeight = NightGlass.textSize("Ag", style: .body).height
        let textY = field.midY - lineHeight / 2
        if let text = model.editing {
            let shown = Self.tail(of: text, fitting: textWidth)
            let size = NightGlass.textSize(shown, style: .body)
            if model.allSelected, !shown.isEmpty {
                NightGlass.fill(ctx, CGRect(x: textX - 3, y: textY - 2, width: size.width + 6, height: lineHeight + 4), radius: 5,
                                color: NightGlass.accent.withAlphaComponent(0.35))
            }
            NightGlass.drawText(shown, at: CGPoint(x: textX, y: textY), style: .body, color: .white)
            if !model.allSelected, caretOn(for: text) {
                NightGlass.fill(ctx, CGRect(x: textX + (shown.isEmpty ? 0 : size.width) + 1, y: textY, width: 1.5, height: lineHeight), radius: 0.75, color: NightGlass.accent)
            }
            if text.isEmpty {
                NightGlass.drawText(model.field == .find ? "Find in this page" : "Search or enter address", at: CGPoint(x: textX + 6, y: textY),
                                    style: .body, color: NightGlass.tertiary)
            } else if model.notFound {
                let note = "No match"
                let w = NightGlass.textSize(note, style: .caption).width
                NightGlass.drawText(note, at: CGPoint(x: field.maxX - w - 18, y: field.midY - 7), style: .caption, color: NightGlass.warning)
            }
        } else if model.url.isEmpty {
            NightGlass.drawText("Search or enter address", at: CGPoint(x: textX, y: textY), style: .body, color: NightGlass.tertiary, width: textWidth)
        } else {
            // Host in full strength, the rest of the address dimmer.
            let (host, rest) = Self.split(model.url)
            let hostSize = NightGlass.drawText(host, at: CGPoint(x: textX, y: textY), style: .body, color: NightGlass.text, width: textWidth)
            if !rest.isEmpty, textWidth - hostSize.width > 30 {
                NightGlass.drawText(rest, at: CGPoint(x: textX + hostSize.width, y: textY), style: .body, color: NightGlass.tertiary,
                                    width: textWidth - hostSize.width)
            }
        }
    }

    /// Where the suggestions go: under the field, as wide as it.
    private func dropdown(count: Int) -> CGRect {
        let field = fieldRect == .zero ? CGRect(x: glass.minX + 150, y: glass.minY + 60, width: barWidth - 300, height: 44) : fieldRect
        return CGRect(x: field.minX, y: glass.maxY + 6, width: field.width, height: CGFloat(count) * Self.suggestionRow + 12)
    }

    private func drawSuggestions(_ ctx: CGContext) {
        guard !model.suggestions.isEmpty else { return }
        let box = dropdown(count: model.suggestions.count)
        NightGlass.fill(ctx, box, radius: 22, color: NSColor(srgbRed: 28 / 255, green: 31 / 255, blue: 42 / 255, alpha: 0.98))
        ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 21.5, cornerHeight: 21.5, transform: nil))
        ctx.setStrokeColor(NightGlass.hairline.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        let lineHeight = NightGlass.textSize("Ag", style: .body).height
        for (i, s) in model.suggestions.enumerated() {
            let id = "suggestion:\(i)"
            let row = CGRect(x: box.minX + 6, y: box.minY + 6 + CGFloat(i) * Self.suggestionRow, width: box.width - 12, height: Self.suggestionRow)
            self.row(ctx, id, row, rest: model.selected == i ? 0.10 : 0)
            let symbol = s.kind == .bookmark ? "star.fill" : s.kind == .history ? "clock" : "magnifyingglass"
            NightGlass.drawSymbol(symbol, in: CGRect(x: row.minX + 10, y: row.minY, width: 22, height: row.height), size: 13,
                                  color: s.kind == .bookmark ? NightGlass.accent : NightGlass.secondary, weight: .medium)
            let textX = row.minX + 42, width = row.width - 54
            let title = s.title.isEmpty ? (s.url.host ?? s.url.absoluteString) : s.title
            let titleSize = NightGlass.drawText(title, at: CGPoint(x: textX, y: row.midY - lineHeight / 2), style: .body, width: width * 0.62)
            if s.kind != .search, width - titleSize.width > 80 {
                let host = "— " + (s.url.host?.replacingOccurrences(of: "www.", with: "") ?? "")
                NightGlass.drawText(host, at: CGPoint(x: textX + titleSize.width + 10, y: row.midY - lineHeight / 2 + 1), style: .label,
                                    color: NightGlass.tertiary, width: width - titleSize.width - 10)
            }
        }
    }


    /// "https://host/path" → ("host", "/path").
    private static func split(_ url: String) -> (String, String) {
        guard let c = URLComponents(string: url), let host = c.host else { return (url, "") }
        let rest = url.range(of: host).map { String(url[$0.upperBound...]) } ?? ""
        return (host, rest == "/" ? "" : rest)
    }

    /// The end of `text` that fits in `width` (the caret is at the end).
    private static func tail(of text: String, fitting width: CGFloat) -> String {
        var shown = Substring(text)
        while shown.count > 1, NightGlass.textSize(String(shown), style: .body).width > width { shown = shown.dropFirst() }
        return String(shown)
    }
}
