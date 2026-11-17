// The resize handle (ROADMAP W11 C.3): a small arc that appears at a window's corner when the
// pointer comes near it. Hold it and drag to resize the real window. One handle exists; it goes to
// whichever corner is pointed at.

import AppKit

@MainActor
final class ResizeHandle: VRPanel {
    /// Corners of a window, as seen by the viewer.
    enum Corner: Int, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var isRight: Bool { self == .topRight || self == .bottomRight }
        var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    }

    var corner = Corner.bottomRight {
        didSet { if corner != oldValue { setNeedsDisplay() } }
    }
    /// The handle is being held.
    var active = false {
        didSet { if active != oldValue { setNeedsDisplay() } }
    }

    /// Side of the panel (dmm); the arc hugs the corner at its center.
    static let side: CGFloat = 72

    init(renderer: Renderer) {
        let size = CGSize(width: Self.side, height: Self.side)
        super.init(renderer: renderer, size: size, surface: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        control("resize", surface)
        // A quarter ring around the window's corner (the panel's center), on the outside.
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let lit = active || pressed == "resize"
        let hot = lit || hovered == "resize"
        // Angles in the flipped context: 0 = right, π/2 = down.
        let start: CGFloat = switch corner {
        case .bottomRight: 0
        case .bottomLeft: .pi / 2
        case .topLeft: .pi
        case .topRight: 3 * .pi / 2
        }
        ctx.setLineCap(.round)
        ctx.setLineWidth(hot ? 6 : 5)
        ctx.setStrokeColor((lit ? NightGlass.accent : NSColor(white: 1, alpha: hot ? 0.95 : 0.7)).cgColor)
        ctx.addArc(center: center, radius: 20, startAngle: start + 0.12, endAngle: start + .pi / 2 - 0.12, clockwise: false)
        ctx.strokePath()
    }
}
