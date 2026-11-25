// Night Glass controls (ROADMAP W12 C.6, design board 7): one drawing of every control for all of
// Halliday's panels, with the same states everywhere. Hover lifts and brightens (the control grows a
// little), press sinks and is the brightest moment, disabled is dim, loading keeps the control's
// size. And the moments every panel has besides its content (board 8): loading, empty, error.
//
// These are called from a panel's `draw(in:)`: each declares its control and draws it.

import AppKit

extension VRPanel {
    enum ControlState {
        case rest, hover, pressed, disabled
    }

    func state(of id: String, enabled: Bool = true) -> ControlState {
        !enabled ? .disabled : pressed == id ? .pressed : hovered == id ? .hover : .rest
    }

    /// `rect` as the state shows it: a little larger under the pointer, a little smaller while held.
    private func shaped(_ rect: CGRect, _ state: ControlState, lift: CGFloat) -> CGRect {
        switch state {
        case .hover: rect.insetBy(dx: -rect.width * lift / 2, dy: -rect.height * lift / 2)
        case .pressed: rect.insetBy(dx: rect.width * lift * 0.4, dy: rect.height * lift * 0.4)
        default: rect
        }
    }

    private static let iconRest = NSColor(srgbRed: 0xD2 / 255, green: 0xD6 / 255, blue: 0xE2 / 255, alpha: 1)

    /// A round button with a symbol. `backed`: it has a faint fill at rest (a main control among
    /// others); `selected`: it is on (lifted fill). `quiet`: dimmer at rest (secondary actions).
    func iconButton(_ ctx: CGContext, _ id: String, _ symbol: String, _ rect: CGRect, symbolSize: CGFloat = 15,
                    enabled: Bool = true, tint: NSColor? = nil, backed: Bool = false, selected: Bool = false, quiet: Bool = false, lit: Bool = false) {
        control(id, rect, enabled: enabled)
        let state = state(of: id, enabled: enabled)
        let shape = shaped(rect, state, lift: 0.06)
        // `lit`: the main control of a bar (board 20's play button), the lit blue, a white symbol.
        if lit, state != .disabled {
            let up: CGFloat = state == .hover ? 0.16 : (state == .pressed ? -0.12 : 0)
            let top = (up >= 0 ? NightGlass.litTop.blended(withFraction: up, of: .white) : NightGlass.litTop.blended(withFraction: -up, of: .black)) ?? NightGlass.litTop
            let bottom = (up >= 0 ? NightGlass.litBottom.blended(withFraction: up, of: .white) : NightGlass.litBottom.blended(withFraction: -up, of: .black)) ?? NightGlass.litBottom
            NightGlass.glow(ctx, shape, radius: shape.height / 2, color: NightGlass.litBottom, strength: 0.7)
            NightGlass.fillGradient(ctx, shape, radius: shape.height / 2, top, bottom)
            NightGlass.topLight(ctx, shape, radius: shape.height / 2, alpha: 0.5)
            NightGlass.drawSymbol(symbol, in: rect, size: state == .pressed ? symbolSize - 1 : symbolSize, color: .white, weight: .semibold)
            return
        }
        switch state {
        case .pressed: NightGlass.fill(ctx, shape, radius: shape.height / 2, color: NSColor(white: 1, alpha: 0.26))
        case .hover: NightGlass.fill(ctx, shape, radius: shape.height / 2, color: NSColor(white: 1, alpha: 0.13))
        case .rest where selected: NightGlass.fill(ctx, shape, radius: shape.height / 2, color: NightGlass.lifted)
        case .rest where backed: NightGlass.fill(ctx, shape.insetBy(dx: 2, dy: 2), radius: shape.height / 2, color: NSColor(white: 1, alpha: 0.08))
        default: break
        }
        let color: NSColor = switch state {
        case .disabled: NightGlass.disabled
        case .hover, .pressed: tint ?? .white
        case .rest: tint ?? (selected || backed ? .white : (quiet ? NightGlass.secondary : Self.iconRest))
        }
        NightGlass.drawSymbol(symbol, in: rect, size: state == .pressed ? symbolSize - 1 : symbolSize, color: color, weight: .medium)
    }

    enum ButtonKind {
        /// An ordinary action.
        case plain
        /// The one thing to do next (accent).
        case main
        /// Text only until the pointer is on it.
        case quiet
        /// Ends something (Quit game): coral text.
        case danger
        /// Confirms the end (the second Quit, Force quit): filled coral.
        case dangerMain
    }

    /// A pill button with a title, and a symbol before it if given. `busy`: a spinner takes the
    /// symbol's place and the button doesn't take clicks; its size stays.
    func button(_ ctx: CGContext, _ id: String, _ title: String, _ rect: CGRect, symbol: String? = nil, kind: ButtonKind = .plain,
                enabled: Bool = true, busy: Bool = false, selected: Bool = false) {
        control(id, rect, enabled: enabled && !busy)
        let state = busy ? ControlState.rest : state(of: id, enabled: enabled)
        let shape = shaped(rect, state, lift: 0.03)
        let fill: NSColor, baseText: NSColor
        switch (kind, state) {
        case (_, .disabled): (fill, baseText) = (NSColor(white: 1, alpha: 0.04), NightGlass.disabled)
        case (.main, .rest): (fill, baseText) = (NightGlass.accent.withAlphaComponent(0.20), NightGlass.accent)
        case (.main, .hover): (fill, baseText) = (NightGlass.accent.withAlphaComponent(0.36), .white)
        case (.main, .pressed): (fill, baseText) = (NightGlass.accent, NSColor(srgbRed: 0x0A / 255, green: 0x0B / 255, blue: 0x10 / 255, alpha: 1))
        case (.danger, .rest): (fill, baseText) = (NSColor(white: 1, alpha: 0.09), NightGlass.danger)
        case (.danger, .hover): (fill, baseText) = (NightGlass.danger.withAlphaComponent(0.22), .white)
        case (.danger, .pressed): (fill, baseText) = (NightGlass.danger.withAlphaComponent(0.36), .white)
        case (.dangerMain, .rest): (fill, baseText) = (NightGlass.danger, NSColor(srgbRed: 0x20 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1))
        case (.dangerMain, .hover): (fill, baseText) = (NightGlass.danger.blended(withFraction: 0.18, of: .white) ?? NightGlass.danger,
                                                    NSColor(srgbRed: 0x20 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1))
        case (.dangerMain, .pressed): (fill, baseText) = (NightGlass.danger.blended(withFraction: 0.35, of: .white) ?? NightGlass.danger,
                                                      NSColor(srgbRed: 0x20 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1))
        case (.quiet, .rest): (fill, baseText) = (.clear, NightGlass.secondary)
        case (.quiet, .hover): (fill, baseText) = (NSColor(white: 1, alpha: 0.08), .white)
        case (_, .rest): (fill, baseText) = (NSColor(white: 1, alpha: 0.09), NightGlass.text)
        case (_, .hover): (fill, baseText) = (NSColor(white: 1, alpha: 0.16), .white)
        case (_, .pressed): (fill, baseText) = (NSColor(white: 1, alpha: 0.28), .white)
        }
        var text = baseText
        // A confirmed selection remains visible even while changing modes or
        // when this display currently offers only one supported rate.
        if (kind == .main && state != .disabled) || selected {
            // Lit (board 20): the blue's gradient, white label, light along the top.
            let up = state == .hover ? 0.16 : (state == .pressed ? -0.12 : 0)
            let top = up >= 0 ? NightGlass.litTop.blended(withFraction: up, of: .white) : NightGlass.litTop.blended(withFraction: -up, of: .black)
            let bottom = up >= 0 ? NightGlass.litBottom.blended(withFraction: up, of: .white) : NightGlass.litBottom.blended(withFraction: -up, of: .black)
            NightGlass.fillGradient(ctx, shape, radius: shape.height / 2, top ?? NightGlass.litTop, bottom ?? NightGlass.litBottom)
            NightGlass.topLight(ctx, shape, radius: shape.height / 2, alpha: 0.5)
            text = .white
        } else {
            NightGlass.fill(ctx, shape, radius: shape.height / 2, color: fill)
            if fill.alphaComponent > 0.02, state != .disabled { NightGlass.topLight(ctx, shape, radius: shape.height / 2, alpha: 0.16) }
        }
        if selected {
            ctx.addPath(CGPath(roundedRect: shape.insetBy(dx: 0.75, dy: 0.75), cornerWidth: shape.height / 2, cornerHeight: shape.height / 2, transform: nil))
            ctx.setStrokeColor(NightGlass.accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
        let weight: NSFont.Weight = selected || kind == .main || kind == .dangerMain ? .semibold : .medium
        let lead: CGFloat = symbol != nil || busy ? 26 : 0
        let size = NightGlass.textSize(title, style: .label, weight: weight)
        let width = min(size.width, rect.width - 20 - lead)
        let x = rect.midX - (width + lead) / 2
        if busy {
            spinner(ctx, center: CGPoint(x: x + 9, y: rect.midY), radius: 7, color: text)
        } else if let symbol {
            NightGlass.drawSymbol(symbol, in: CGRect(x: x, y: rect.minY, width: 18, height: rect.height), size: 14, color: text, weight: .medium)
        }
        NightGlass.drawText(title, at: CGPoint(x: x + lead, y: rect.midY - size.height / 2), style: .label, color: text, weight: weight, width: width + 1)
    }

    /// The background of a row or a card in a list: nothing at rest, lit under the pointer,
    /// brightest while pressed; `selected` is the accent with a thin ring.
    func row(_ ctx: CGContext, _ id: String, _ rect: CGRect, radius: CGFloat = 16, selected: Bool = false, rest: CGFloat = 0, enabled: Bool = true) {
        control(id, rect, enabled: enabled)
        let state = state(of: id, enabled: enabled)
        switch state {
        case .pressed: NightGlass.fill(ctx, rect, radius: radius, color: NSColor(white: 1, alpha: 0.22))
        case .hover: NightGlass.fill(ctx, rect, radius: radius, color: NSColor(white: 1, alpha: max(0.10, rest + 0.06)))
        default:
            if selected {
                NightGlass.fill(ctx, rect, radius: radius, color: NightGlass.accent.withAlphaComponent(0.20))
            } else if rest > 0 {
                NightGlass.fill(ctx, rect, radius: radius, color: NSColor(white: 1, alpha: rest))
            }
        }
        if selected {
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius - 0.75, cornerHeight: radius - 0.75, transform: nil))
            ctx.setStrokeColor(NightGlass.accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
    }

    /// Choices side by side, one of them on: (id, label, on). Returns the y below it.
    @discardableResult
    func segmented(_ ctx: CGContext, _ items: [(String, String, Bool)], x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let box = CGRect(x: x, y: y, width: width, height: 44)
        NightGlass.fill(ctx, box, radius: 22, color: NSColor(white: 0, alpha: 0.30))
        let segment = (width - 8) / CGFloat(items.count)
        // The selected segment's fill slides from the old choice to the new one.
        if let chosen = items.firstIndex(where: { $0.2 }) {
            let key = "segmented:" + items.map(\.0).joined(separator: ",")
            let at = eased(key, CGFloat(chosen))
            let on = CGRect(x: box.minX + 4 + at * segment, y: y + 4, width: segment, height: 36)
            NightGlass.fill(ctx, on, radius: 18, color: NSColor(white: 1, alpha: 0.16))
            NightGlass.topLight(ctx, on, radius: 18, alpha: 0.25)
        }
        for (i, (id, label, selected)) in items.enumerated() {
            let rect = CGRect(x: box.minX + 4 + CGFloat(i) * segment, y: y + 4, width: segment, height: 36)
            control(id, rect)
            let state = state(of: id)
            if state == .pressed {
                NightGlass.fill(ctx, rect, radius: 18, color: NSColor(white: 1, alpha: 0.24))
            } else if selected, state == .hover {
                NightGlass.fill(ctx, rect, radius: 18, color: NSColor(white: 1, alpha: 0.04))
            } else if state == .hover, !selected {
                NightGlass.fill(ctx, rect, radius: 18, color: NSColor(white: 1, alpha: 0.07))
            }
            let size = NightGlass.textSize(label, style: .label, weight: selected ? .medium : .regular)
            NightGlass.drawText(label, at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), style: .label,
                                color: selected || state == .hover ? .white : Self.iconRest, weight: selected ? .medium : .regular)
        }
        return y + 52
    }

    /// A slider in `row` (its hit area, 40 dmm tall). Returns the track, for mapping the pointer to
    /// a value while it is dragged.
    @discardableResult
    func slider(_ ctx: CGContext, _ id: String, row: CGRect, fraction: CGFloat, enabled: Bool = true) -> CGRect {
        let track = CGRect(x: row.minX + 12, y: row.midY - 3, width: row.width - 24, height: 6)
        control(id, row, enabled: enabled)
        let state = state(of: id, enabled: enabled)
        ctx.saveGState()
        if !enabled { ctx.setAlpha(0.35) }
        defer { ctx.restoreGState() }
        NightGlass.fill(ctx, track, radius: 3, color: NSColor(white: 1, alpha: state == .rest ? 0.12 : 0.18))
        let f = max(0, min(1, fraction))
        if f > 0.005 {
            let filled = CGRect(x: track.minX, y: track.minY, width: track.width * f, height: 6)
            NightGlass.glow(ctx, filled, radius: 3, color: NightGlass.accent, strength: 0.6)
            NightGlass.fillGradient(ctx, filled, radius: 3, NSColor(srgbRed: 0x5E / 255, green: 0x8E / 255, blue: 0xF0 / 255, alpha: 1),
                                    NSColor(srgbRed: 0x9C / 255, green: 0xC0 / 255, blue: 1, alpha: 1), vertical: false)
        }
        let knob: CGFloat = state == .pressed ? 22 : (state == .hover ? 26 : 22)
        let center = CGPoint(x: track.minX + track.width * f, y: track.midY)
        if state == .pressed {
            NightGlass.fill(ctx, CGRect(x: center.x - 19, y: center.y - 19, width: 38, height: 38), radius: 19, color: NightGlass.accent.withAlphaComponent(0.28))
        }
        let k = CGRect(x: center.x - knob / 2, y: center.y - knob / 2, width: knob, height: knob)
        NightGlass.fill(ctx, k.offsetBy(dx: 0, dy: 2), radius: knob / 2, color: NSColor(white: 0, alpha: 0.30))
        NightGlass.fillGradient(ctx, k, radius: knob / 2, .white, NSColor(srgbRed: 0xE3 / 255, green: 0xE7 / 255, blue: 0xF2 / 255, alpha: 1))
        return track
    }

    /// An on/off switch.
    func toggle(_ ctx: CGContext, _ id: String, _ on: Bool, _ rect: CGRect) {
        control(id, rect.insetBy(dx: -6, dy: -4))
        let state = state(of: id)
        // The knob slides across, and the track's accent follows it in and out.
        let f = eased("toggle:" + id, on ? 1 : 0)
        NightGlass.fill(ctx, rect, radius: rect.height / 2, color: NSColor(white: 1, alpha: state == .rest ? 0.14 : 0.24))
        if f > 0.01 {
            // Lit when on (board 20): the blue's gradient, glowing.
            NightGlass.glow(ctx, rect, radius: rect.height / 2, color: NightGlass.accent, strength: f)
            ctx.saveGState()
            ctx.setAlpha(f)
            NightGlass.fillGradient(ctx, rect, radius: rect.height / 2, NightGlass.litTop, NightGlass.litBottom)
            ctx.restoreGState()
        }
        if on, state != .rest { NightGlass.fill(ctx, rect, radius: rect.height / 2, color: NSColor(white: 1, alpha: 0.18)) }
        let knob = rect.height - (state == .pressed ? 10 : 6), inset = (rect.height - knob) / 2
        let x = rect.minX + inset + (rect.width - knob - 2 * inset) * f
        let k = CGRect(x: x, y: rect.minY + inset, width: knob, height: knob)
        NightGlass.fill(ctx, k.offsetBy(dx: 0, dy: 1.5), radius: knob / 2, color: NSColor(white: 0, alpha: 0.28))
        NightGlass.fillGradient(ctx, k, radius: knob / 2, .white, NSColor(srgbRed: 0xE3 / 255, green: 0xE7 / 255, blue: 0xF2 / 255, alpha: 1))
    }

    /// The ring around what has the keyboard (a text field being typed in).
    func focusRing(_ ctx: CGContext, _ rect: CGRect, color: NSColor = NightGlass.accent) {
        NightGlass.fill(ctx, rect.insetBy(dx: -6, dy: -6), radius: (rect.height + 12) / 2, color: color.withAlphaComponent(0.20))
        NightGlass.fill(ctx, rect.insetBy(dx: -2, dy: -2), radius: (rect.height + 4) / 2, color: color)
    }

    /// A turning arc: something is on its way. The panel keeps redrawing while one is shown.
    func spinner(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor = NightGlass.accent) {
        animates = true
        let turn = CGFloat(CACurrentMediaTime().truncatingRemainder(dividingBy: 0.9) / 0.9) * 2 * .pi
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(max(2, radius * 0.3))
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: turn, endAngle: turn + 1.5 * .pi, clockwise: false)
        ctx.strokePath()
    }

    // --- The moments of a panel besides its content (design board 8) ---

    /// A placeholder bar in the shape of what is coming; it breathes while loading.
    func skeleton(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat = 6, strength: CGFloat = 1) {
        animates = true
        let pulse = 0.5 + 0.5 * sin(CACurrentMediaTime() * 2 * .pi / 1.4)
        NightGlass.fill(ctx, rect, radius: radius, color: NSColor(white: 1, alpha: (0.06 + 0.05 * pulse) * strength))
    }

    /// Loading a list: rows in the shape of what is coming, fading down the list.
    func skeletonRows(_ ctx: CGContext, in area: CGRect, rowHeight: CGFloat, thumbnail: CGSize) {
        var y = area.minY
        var k = 0
        while y + rowHeight <= area.maxY, k < 5 {
            let s = max(0.25, 1 - CGFloat(k) * 0.2)
            skeleton(ctx, CGRect(x: area.minX + 8, y: y + (rowHeight - thumbnail.height) / 2, width: thumbnail.width, height: thumbnail.height), radius: 8, strength: s)
            let x = area.minX + 8 + thumbnail.width + 14
            skeleton(ctx, CGRect(x: x, y: y + rowHeight / 2 - 13, width: [180, 140, 200, 120, 160][k], height: 10), radius: 5, strength: s)
            skeleton(ctx, CGRect(x: x, y: y + rowHeight / 2 + 5, width: [110, 150, 90, 130, 100][k], height: 8), radius: 4, strength: s)
            y += rowHeight
            k += 1
        }
    }

    /// Empty or failed: a symbol, what is (not) here in plain words, what to do about it, and the
    /// one button that does it. `problem`: something went wrong (amber symbol, the button is the
    /// main action).
    func message(_ ctx: CGContext, in area: CGRect, symbol: String, title: String, detail: String? = nil,
                 action: (id: String, title: String)? = nil, problem: Bool = false) {
        let titleSize = NightGlass.textSize(title, style: .body, weight: .medium)
        let lines = detail.map { NightGlass.wrap($0, style: .label, width: min(area.width - 40, 380)) } ?? []
        let lineHeight = NightGlass.textSize("Ag", style: .label).height + 2
        let total = 40 + 14 + titleSize.height + (lines.isEmpty ? 0 : 8 + CGFloat(lines.count) * lineHeight) + (action == nil ? 0 : 20 + 44)
        var y = area.midY - total / 2
        NightGlass.drawSymbol(symbol, in: CGRect(x: area.midX - 24, y: y, width: 48, height: 40), size: 30,
                              color: problem ? NightGlass.warning : NightGlass.secondary)
        y += 40 + 14
        let titleWidth = min(titleSize.width, area.width - 40)
        NightGlass.drawText(title, at: CGPoint(x: area.midX - titleWidth / 2, y: y), style: .body, weight: .medium, width: titleWidth + 1)
        y += titleSize.height
        if !lines.isEmpty {
            y += 8
            for line in lines {
                let w = NightGlass.textSize(line, style: .label).width
                NightGlass.drawText(line, at: CGPoint(x: area.midX - w / 2, y: y), style: .label, color: NightGlass.secondary)
                y += lineHeight
            }
        }
        if let action {
            y += 20
            let w = NightGlass.textSize(action.title, style: .label, weight: .semibold).width + 44
            button(ctx, action.id, action.title, CGRect(x: area.midX - w / 2, y: y, width: w, height: 44), kind: problem ? .main : .plain)
        }
    }
}
