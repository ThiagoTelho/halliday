// The bar under every panel in VR (ROADMAP W11.C): buttons that stand in for a Mac window's own
// title-bar buttons (which are small, and whose full-screen button would take the window where
// Halliday can't follow), and a handle to grab and drag the panel around. Night Glass; used with
// Halliday's own pointer.
//
//   ✕  close the window for real (as its red button would)
//   ↩  send it back to the Mac's desktop, still open (Mac windows only)
//   ━  the handle: hold to drag, scroll for distance, two clicks to return to the arc
//
// Resizing is at the window's corners (ResizeHandle).

import AppKit

@MainActor
final class PanelBar: VRPanel {
    /// The handle is being held (the panel follows the saber).
    var grabbed = false {
        didSet { if grabbed != oldValue { setNeedsDisplay() } }
    }
    /// A Mac window can be sent back to the desktop; Halliday's own panels only close.
    private let canSendBack: Bool

    // Layout (dmm): buttons, then the handle with a generous hit area; room below for a tooltip.
    private static let button: CGFloat = 40
    private static let gap: CGFloat = 6
    private static let handleHit = CGSize(width: 180, height: 40)
    private static let handle = CGSize(width: 140, height: 10)
    private static let margin: CGFloat = 8
    private static let tooltipRoom: CGFloat = 44
    private var buttonsWidth: CGFloat { canSendBack ? 2 * Self.button + Self.gap : Self.button }

    init(renderer: Renderer, canSendBack: Bool) {
        self.canSendBack = canSendBack
        let buttons = canSendBack ? 2 * Self.button + Self.gap : Self.button
        // Balanced on both sides of the handle, so the handle is centered under the window.
        let width = 2 * (buttons + 10) + Self.handleHit.width
        let size = CGSize(width: width + 2 * Self.margin, height: Self.button + 2 * Self.margin + Self.tooltipRoom)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: width, height: Self.button))
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        let y = Self.margin
        var x = Self.margin
        var tooltip: (String, CGFloat)?
        var items = [("close", "xmark", "Close window")]
        if canSendBack { items.append(("back", "arrow.uturn.backward", "Send back to the Mac")) }
        for (id, symbol, label) in items {
            let rect = CGRect(x: x, y: y, width: Self.button, height: Self.button)
            NightGlass.fill(ctx, rect.insetBy(dx: 2, dy: 2), radius: Self.button / 2, color: NightGlass.solidGlass)
            iconButton(ctx, id, symbol, rect, symbolSize: 13, quiet: true)
            if hovered == id, pressed == nil { tooltip = (label, rect.midX) }
            x += Self.button + Self.gap
        }

        // Handle: a pill; brighter under the saber, accent while held.
        let hit = CGRect(x: Self.margin + buttonsWidth + 10, y: y, width: Self.handleHit.width, height: Self.handleHit.height)
        control("grab", hit)
        let active = grabbed || pressed == "grab"
        let grow: CGFloat = active || hovered == "grab" ? 2 : 0
        let pill = CGRect(x: hit.midX - Self.handle.width / 2 - grow * 2, y: hit.midY - Self.handle.height / 2 - grow / 2,
                          width: Self.handle.width + grow * 4, height: Self.handle.height + grow)
        NightGlass.fill(ctx, pill, radius: pill.height / 2,
                        color: active ? NightGlass.accent : NSColor(white: 1, alpha: hovered == "grab" ? 0.85 : 0.55))

        if let (label, centerX) = tooltip {
            let half = NightGlass.textSize(label, style: .label, weight: .semibold).width / 2 + 14
            NightGlass.drawChip(ctx, label, centerX: min(size.width - half - 2, max(half + 2, centerX)), bottom: y + Self.button + 6 + 32)
        }
    }
}
