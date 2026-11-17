// The first launch in the headset (design canvas board 16): one panel saying to take the
// headset off and set Halliday up on the Mac's screen, where the companion opens on setup
// (Setup.swift). Nothing else shows meanwhile: no dock, no Home. "Set up later" puts it off;
// when the Mac's setup ends the panel says "You're ready" and goes with its button.

import AppKit

@MainActor
final class SetupPanel: VRPanel {
    /// Setup on the Mac ended: the panel says so.
    var ready = false { didSet { setNeedsDisplay(fade: true) } }
    var onLater: (() -> Void)?
    var onStart: (() -> Void)?

    static let distance: Float = 1.6
    static let below: Float = -2

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 680, height: CGFloat = 456
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in
            switch id {
            case "later": self?.onLater?()
            case "start": self?.onStart?()
            default: break
            }
        }
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let x = g.minX + 40, w = g.width - 80
        // The headset lifted off, toward the Mac's screen.
        let art = CGRect(x: x, y: g.minY + 36, width: 160, height: 96)
        NightGlass.drawSymbol(ready ? "checkmark.circle" : "visionpro", in: CGRect(x: art.minX, y: art.minY + 18, width: 70, height: 60), size: 44,
                              color: ready ? NightGlass.accent : NightGlass.text)
        if !ready {
            NightGlass.drawSymbol("arrow.right", in: CGRect(x: art.minX + 64, y: art.minY + 30, width: 30, height: 36), size: 20, color: NightGlass.accent)
            NightGlass.drawSymbol("laptopcomputer", in: CGRect(x: art.minX + 92, y: art.minY + 18, width: 70, height: 60), size: 44, color: NightGlass.text)
        }
        let tx = art.maxX + 24, tw = g.maxX - 40 - tx
        NightGlass.drawText(ready ? "You're ready" : "Welcome to Halliday", at: CGPoint(x: tx, y: g.minY + 40), style: .title, weight: .semibold, width: tw)
        let lead = ready
            ? "Setup is done. The companion stays on your Mac's screen for settings, apps and help."
            : "Setting up takes about three minutes, and it's easier with the headset off. Halliday is waiting for you on your Mac's screen."
        var ly = g.minY + 82
        for line in NightGlass.wrap(lead, style: .body, width: tw) {
            NightGlass.drawText(line, at: CGPoint(x: tx, y: ly), style: .body, color: NightGlass.secondary)
            ly += 24
        }

        if ready {
            button(ctx, "start", "Start", CGRect(x: g.maxX - 40 - 180, y: g.maxY - 40 - 52, width: 180, height: 52), symbol: "arrow.right", kind: .main)
            return
        }

        // The three steps.
        let box = CGRect(x: x, y: g.minY + 166, width: w, height: 168)
        NightGlass.fill(ctx, box, radius: 20, color: NSColor(white: 1, alpha: 0.05))
        let steps = ["Take off the headset.",
                     "Follow the setup in Halliday's window on your Mac: your headset, permissions, your space.",
                     "Put the headset back on when the Mac says you're ready."]
        var sy = box.minY + 18
        for (i, s) in steps.enumerated() {
            let badge = CGRect(x: box.minX + 18, y: sy, width: 28, height: 28)
            NightGlass.fill(ctx, badge, radius: 14, color: NSColor(white: 1, alpha: 0.10))
            let n = "\(i + 1)", ns = NightGlass.textSize(n, style: .label, weight: .semibold)
            NightGlass.drawText(n, at: CGPoint(x: badge.midX - ns.width / 2, y: badge.midY - ns.height / 2), style: .label, weight: .semibold)
            for line in NightGlass.wrap(s, style: .body, width: box.width - 80) {
                NightGlass.drawText(line, at: CGPoint(x: badge.maxX + 14, y: sy + 3), style: .body)
                sy += 23
            }
            sy += 14
        }

        // Waiting, and the way out.
        let wy = g.maxY - 40 - 48
        NightGlass.drawText("Waiting for the setup on your Mac", at: CGPoint(x: x, y: wy + 14), style: .label, color: NightGlass.secondary)
        button(ctx, "later", "Set up later", CGRect(x: g.maxX - 40 - 170, y: wy, width: 170, height: 48))
    }
}
