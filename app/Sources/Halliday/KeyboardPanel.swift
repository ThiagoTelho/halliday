// The virtual keyboard (ROADMAP W11 B.10): a Night Glass keyboard typed with the saber, for when
// the Mac's keyboard is out of reach (in the headset). It types into Halliday's own fields (the
// address bar, the launcher's search) or, while a window is in use, into that window's app, as real
// key events. Keys act when pressed, not when released: typing must not wait for the button to come
// up. The Mac keyboard keeps working alongside it.

import AppKit

@MainActor
final class KeyboardPanel: VRPanel {
    enum Special { case delete, enter, left, right, tab, escape }

    /// Called with text to type, and with keys that aren't text.
    var onText: ((String) -> Void)?
    var onSpecial: ((Special) -> Void)?
    var onHide: (() -> Void)?

    private enum Shift { case off, once, locked }
    private var shift = Shift.off
    private var symbols = false
    private var lastShiftPress = 0.0
    /// Backspace repeats while held.
    private var repeatTimer: Timer?

    static let distance: Float = 0.85
    static let below: Float = 31

    // Layout (dmm).
    private static let margin: CGFloat = 20
    private static let key = CGSize(width: 58, height: 54)
    private static let gap: CGFloat = 6
    private static let pad: CGFloat = 16
    private static let rowWidth: CGFloat = 10 * key.width + 9 * gap
    private static let width: CGFloat = rowWidth + 2 * pad
    private static let height: CGFloat = 4 * key.height + 3 * gap + 2 * pad
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let marks = ["1234567890", "-/:;()$&@\"", ".,?!'#%+="]

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onPress = { [weak self] id in self?.pressed(key: id) }
        setNeedsDisplay()
    }

    private func pressed(key id: String) {
        repeatTimer?.invalidate()
        switch id {
        case "shift":
            let now = CACurrentMediaTime()
            // Twice quickly locks capitals; once capitalizes the next letter.
            shift = shift == .off ? (now - lastShiftPress < 0.4 ? .locked : .once) : (shift == .once && now - lastShiftPress < 0.4 ? .locked : .off)
            lastShiftPress = now
        case "symbols":
            symbols.toggle()
        case "delete":
            onSpecial?(.delete)
            // Held: after a moment it repeats, until the button comes up.
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.pressed == "delete" else {
                        self.repeatTimer?.invalidate()
                        return
                    }
                    if CACurrentMediaTime() - self.lastKeyDown > 0.45 { self.onSpecial?(.delete) }
                }
            }
        case "enter": onSpecial?(.enter)
        case "left": onSpecial?(.left)
        case "right": onSpecial?(.right)
        case "tab": onSpecial?(.tab)
        case "space": onText?(" ")
        case "hide": onHide?()
        default:
            guard id.hasPrefix("k:") else { return }
            var text = String(id.dropFirst(2))
            if shift != .off { text = text.uppercased() }
            onText?(text)
            if shift == .once { shift = .off }
        }
        lastKeyDown = CACurrentMediaTime()
        setNeedsDisplay()
    }

    private var lastKeyDown = 0.0

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let left = g.minX + Self.pad
        let rows = symbols ? Self.marks : Self.letters
        func y(_ row: Int) -> CGFloat { g.minY + Self.pad + CGFloat(row) * (Self.key.height + Self.gap) }
        let step = Self.key.width + Self.gap

        // Row 1: ten keys.
        for (i, c) in rows[0].enumerated() { letter(ctx, c, CGRect(x: left + CGFloat(i) * step, y: y(0), width: Self.key.width, height: Self.key.height)) }
        // Row 2: nine or ten keys, centered.
        let inset2 = (Self.rowWidth - CGFloat(rows[1].count) * Self.key.width - CGFloat(rows[1].count - 1) * Self.gap) / 2
        for (i, c) in rows[1].enumerated() { letter(ctx, c, CGRect(x: left + inset2 + CGFloat(i) * step, y: y(1), width: Self.key.width, height: Self.key.height)) }
        // Row 3: shift, the letters, delete.
        let side = (Self.rowWidth - CGFloat(rows[2].count) * Self.key.width - CGFloat(rows[2].count + 1) * Self.gap) / 2
        if symbols {
            action(ctx, "tab", symbol: "arrow.right.to.line", CGRect(x: left, y: y(2), width: side, height: Self.key.height))
        } else {
            action(ctx, "shift", symbol: shift == .locked ? "capslock.fill" : (shift == .once ? "shift.fill" : "shift"),
                   CGRect(x: left, y: y(2), width: side, height: Self.key.height), lit: shift != .off)
        }
        for (i, c) in rows[2].enumerated() {
            letter(ctx, c, CGRect(x: left + side + Self.gap + CGFloat(i) * step, y: y(2), width: Self.key.width, height: Self.key.height))
        }
        action(ctx, "delete", symbol: "delete.left", CGRect(x: left + Self.rowWidth - side, y: y(2), width: side, height: Self.key.height))
        // Row 4: layer switch, hide, arrows, space, return.
        var x = left
        func place(_ w: CGFloat) -> CGRect { defer { x += w + Self.gap }; return CGRect(x: x, y: y(3), width: w, height: Self.key.height) }
        action(ctx, "symbols", label: symbols ? "ABC" : "123", place(84))
        action(ctx, "hide", symbol: "keyboard.chevron.compact.down", place(Self.key.width))
        action(ctx, "left", symbol: "arrow.left", place(Self.key.width))
        action(ctx, "right", symbol: "arrow.right", place(Self.key.width))
        let enterWidth: CGFloat = 110
        action(ctx, "space", label: "space", place(left + Self.rowWidth - x - enterWidth - Self.gap), quiet: true)
        action(ctx, "enter", symbol: "return", place(enterWidth), accent: true)
    }

    private func letter(_ ctx: CGContext, _ c: Character, _ rect: CGRect) {
        let id = "k:\(c)"
        control(id, rect)
        NightGlass.fill(ctx, rect, radius: 14, color: pressed == id ? NSColor(white: 1, alpha: 0.34) : NSColor(white: 1, alpha: hovered == id ? 0.18 : 0.09))
        let shown = shift != .off && !symbols ? String(c).uppercased() : String(c)
        let size = NightGlass.textSize(shown, style: .title, weight: .medium)
        NightGlass.drawText(shown, at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), style: .title, weight: .medium)
    }

    private func action(_ ctx: CGContext, _ id: String, symbol: String? = nil, label: String? = nil, _ rect: CGRect,
                        lit: Bool = false, accent: Bool = false, quiet: Bool = false) {
        control(id, rect)
        let base: NSColor = accent ? NightGlass.accent.withAlphaComponent(0.28) : NSColor(white: 1, alpha: lit ? 0.26 : (quiet ? 0.09 : 0.05))
        NightGlass.fill(ctx, rect, radius: 14, color: pressed == id ? NSColor(white: 1, alpha: 0.34)
            : (hovered == id ? NSColor(white: 1, alpha: accent ? 0.30 : 0.16) : base))
        let color = accent ? NightGlass.accent : (lit ? NSColor.white : NightGlass.secondary)
        if let symbol {
            NightGlass.drawSymbol(symbol, in: rect, size: 17, color: color, weight: .medium)
        } else if let label {
            let size = NightGlass.textSize(label, style: .label, weight: .medium)
            NightGlass.drawText(label, at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), style: .label,
                                color: quiet ? NightGlass.tertiary : color, weight: .medium)
        }
    }
}
