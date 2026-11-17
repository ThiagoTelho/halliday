// The dock (ROADMAP W11.B, board 19): Halliday's bottom menu, one glance down, in Night Glass.
// Two capsules: the clock (and a running timer), which opens the Clock app; and the apps:
// quick settings, the places (apps, windows, browser, videos), the keyboard and recenter. An
// open place is its app's lit tile with a dot under it; a label shows over the one under the
// pointer. Recentering brings the dock back in front.

import AppKit

@MainActor
final class Dock: VRPanel {
    /// What the dock shows; it redraws only when this changes.
    struct State: Equatable {
        var clock = ""
        /// A running timer, shown under the clock ("" when none).
        var timer = ""
        var windowsInVR = false
        var browserOpen = false
        var appsOpen = false
        var keyboardOpen = false
        var videoOpen = false
        var settingsOpen = false
    }

    var state = State() {
        didSet { if state != oldValue { setNeedsDisplay() } }
    }

    /// Seated distance and angle below eye level (docs: the canvas's System board).
    static let distance: Float = 1.0
    static let below: Float = 27
    /// The band of the view the dock keeps for itself (see `ReservedZone`): half its width, and how
    /// high above its middle (both as angles), with a little air.
    static var zoneHalfYaw: Float { Float(barWidth / 2 / 1000) + 0.06 }
    static var zoneTop: Float { -below * .pi / 180 + Float(barHeight / 2 / 1000) + 0.035 }

    private struct Item {
        let id: String, symbol: String, label: String
    }

    private static let settings = Item(id: "settings", symbol: "gearshape", label: "Quick settings")
    private static let places = [
        Item(id: "apps", symbol: "square.grid.2x2", label: "Apps"),
        Item(id: "windows", symbol: "macwindow.on.rectangle", label: "Windows"),
        Item(id: "browser", symbol: "globe", label: "Browser"),
        Item(id: "videos", symbol: "play.rectangle", label: "Videos"),
    ]
    private static let tools = [Item(id: "keyboard", symbol: "keyboard", label: "Keyboard"), Item(id: "recenter", symbol: "scope", label: "Recenter")]

    // Layout (dmm, board 19): two capsules side by side, the clock's and the apps', with room
    // above them for tooltips and around them for their shadow.
    private static let button: CGFloat = 64
    private static let barHeight: CGFloat = 96
    private static let gap: CGFloat = 16
    private static let tooltipRoom: CGFloat = 64
    private static let shadowRoom: CGFloat = 24
    /// Wide enough for the time and for a running timer under it, whatever the clock's format.
    private static let clockWidth: CGFloat = 172
    private static var appsWidth: CGFloat {
        16 + button + 12 + 1 + 12 + CGFloat(places.count) * button + CGFloat(places.count - 1) * 8 + 12 + 1 + 12
            + CGFloat(tools.count) * button + CGFloat(tools.count - 1) * 8 + 16
    }
    private static var barWidth: CGFloat { clockWidth + gap + appsWidth }
    private static var clockRect: CGRect { CGRect(x: shadowRoom, y: tooltipRoom, width: clockWidth, height: barHeight) }
    private static var appsRect: CGRect { CGRect(x: shadowRoom + clockWidth + gap, y: tooltipRoom, width: appsWidth, height: barHeight) }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.barWidth + 2 * Self.shadowRoom, height: Self.tooltipRoom + Self.barHeight + Self.shadowRoom + 10)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.shadowRoom, y: Self.tooltipRoom, width: Self.barWidth, height: Self.barHeight))
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, Self.clockRect, Self.appsRect, radius: Self.barHeight / 2)
    }

    override func draw(in ctx: CGContext) {
        let apps = Self.appsRect
        var tooltip: (String, CGFloat)?

        // The clock, a capsule of its own: the time, and a running timer under it. It opens the
        // Clock app.
        let clock = Self.clockRect
        control("clock", clock, enabled: true)
        if hovered == "clock" { NightGlass.fill(ctx, clock.insetBy(dx: 6, dy: 6), radius: (clock.height - 12) / 2, color: NSColor(white: 1, alpha: 0.07)) }
        let time = NightGlass.textSize(state.clock, style: .display, weight: .medium, tabular: true)
        if state.timer.isEmpty {
            NightGlass.drawText(state.clock, at: CGPoint(x: clock.midX - time.width / 2, y: clock.midY - time.height / 2),
                                style: .display, weight: .medium, tabular: true)
        } else {
            let timer = NightGlass.textSize(state.timer, style: .caption, weight: .semibold, tabular: true)
            let top = clock.midY - (time.height + timer.height - 4) / 2
            NightGlass.drawText(state.clock, at: CGPoint(x: clock.midX - time.width / 2, y: top), style: .display, weight: .medium, tabular: true)
            NightGlass.drawText(state.timer, at: CGPoint(x: clock.midX - timer.width / 2, y: top + time.height - 4), style: .caption,
                                color: NightGlass.accent, weight: .semibold, tabular: true)
        }
        if hovered == "clock" { tooltip = ("Clock", clock.midX) }

        // The apps' capsule: quick settings, the places, then the tools.
        var x = apps.minX + 16
        if let tip = drawButton(ctx, Self.settings, x: x, open: state.settingsOpen) { tooltip = (tip, x + Self.button / 2) }
        x += Self.button + 12
        separator(ctx, x: x)
        x += 1 + 12
        for (i, item) in Self.places.enumerated() {
            let open = [state.appsOpen, state.windowsInVR, state.browserOpen, state.videoOpen][i]
            if let tip = drawButton(ctx, item, x: x, open: open) { tooltip = (tip, x + Self.button / 2) }
            x += Self.button + 8
        }
        x += 12 - 8
        separator(ctx, x: x)
        x += 1 + 12
        for item in Self.tools {
            if let tip = drawButton(ctx, item, x: x, open: item.id == "keyboard" && state.keyboardOpen) { tooltip = (tip, x + Self.button / 2) }
            x += Self.button + 8
        }

        if let (label, centerX) = tooltip {
            NightGlass.drawChip(ctx, label, centerX: centerX, bottom: apps.minY - 12)
        }
    }

    private func separator(_ ctx: CGContext, x: CGFloat) {
        let bar = Self.appsRect
        ctx.setFillColor(NightGlass.hairline.cgColor)
        ctx.fill(CGRect(x: x, y: bar.midY - 24, width: 1, height: 48))
    }

    /// Draws a round button; returns its label if it is under the pointer (for the tooltip).
    private func drawButton(_ ctx: CGContext, _ item: Item, x: CGFloat, open: Bool) -> String? {
        let bar = Self.appsRect
        let rect = CGRect(x: x, y: bar.midY - Self.button / 2, width: Self.button, height: Self.button)
        let isHovered = hovered == item.id
        // Open: the app's own lit tile (board 19), a white dot under it.
        let app = ["windows": "halliday:windows", "browser": "halliday:browser", "videos": "halliday:videos"][item.id]
        if open, let colors = app.flatMap(NightGlass.appColors) {
            control(item.id, rect, enabled: true)
            NightGlass.drawAppTile(ctx, rect.insetBy(dx: 5, dy: 5), radius: (Self.button - 10) / 2, colors: colors, symbol: item.symbol, symbolSize: 23)
            NightGlass.fill(ctx, CGRect(x: rect.midX - 3, y: rect.maxY + 4, width: 6, height: 6), radius: 3, color: .white)
        } else {
            iconButton(ctx, item.id, item.symbol, rect, symbolSize: 26)
            if open { NightGlass.fill(ctx, CGRect(x: rect.midX - 3, y: rect.maxY - 9, width: 6, height: 6), radius: 3, color: NightGlass.accent) }
        }
        return isHovered ? item.label : nil
    }
}
