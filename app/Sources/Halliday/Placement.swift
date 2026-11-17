// Placement (ROADMAP W12.E): the geometry behind where windows and panels go. Everything is seen
// from the viewer as a rectangle on a sphere: a direction (yaw, pitch), angular half-extents and a
// distance. `WindowManager.arrange` lays the arc out with it (rows, room around hand-placed
// windows, the band kept free for the dock), and dragging uses it to keep a window and its bar out
// of that band and off other windows.
//
// Yaw is in radians, positive to the left (as `atan2(-x, -z)`); pitch positive up.

import AppKit
import simd

/// A rectangle as seen from a point.
struct ViewRect {
    var yaw: Float
    var pitch: Float
    var halfYaw: Float
    var halfPitch: Float
    var distance: Float

    init(yaw: Float, pitch: Float, halfYaw: Float, halfPitch: Float, distance: Float) {
        self.yaw = yaw; self.pitch = pitch; self.halfYaw = halfYaw; self.halfPitch = halfPitch; self.distance = distance
    }

    /// A rectangle `width` × `height` meters centered at `position`, facing `eye`.
    init(position: SIMD3<Float>, width: Float, height: Float, from eye: SIMD3<Float>) {
        let v = position - eye
        distance = max(simd_length(v), 0.05)
        yaw = atan2(-v.x, -v.z)
        pitch = asin(max(-1, min(1, v.y / distance)))
        halfYaw = atan(width / 2 / distance)
        halfPitch = atan(height / 2 / distance)
    }

    /// True if the two cover a common part of the view (`margin` radians apart counts too).
    func overlaps(_ o: ViewRect, margin: Float = 0) -> Bool {
        abs(ViewGeometry.wrap(yaw - o.yaw)) < halfYaw + o.halfYaw + margin && abs(pitch - o.pitch) < halfPitch + o.halfPitch + margin
    }
}

/// A part of the view kept free of windows: everything below `top` within `halfYaw` of `yaw`
/// (the dock's band).
struct ReservedZone {
    var yaw: Float
    var halfYaw: Float
    var top: Float
}

enum ViewGeometry {
    /// An angle brought into −π…π.
    static func wrap(_ a: Float) -> Float {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi } else if x < -.pi { x += 2 * .pi }
        return x
    }

    static func yaw(of v: SIMD3<Float>) -> Float { atan2(-v.x, -v.z) }

    /// Room under a window for its bar (gap, buttons, a little air), in dmm at the window's
    /// nominal distance.
    static let barRoom: CGFloat = 66

    /// The lowest a rectangle spanning `halfYaw` around `yaw` may reach (pitch of its bottom edge):
    /// the top of the reserved zones it is above, or nil if it is above none.
    static func floor(yaw: Float, halfYaw: Float, zones: [ReservedZone]) -> Float? {
        zones.filter { abs(wrap(yaw - $0.yaw)) < halfYaw + $0.halfYaw }.map(\.top).max()
    }
}

/// One free place for a dragged window (design board 11): a dashed outline the size of the window,
/// lit when the window is over it. Drawn at a third of the usual density (it is only a line).
@MainActor
final class SlotPanel: VRPanel {
    static let density: Float = 3
    var lit = false {
        didSet { if lit != oldValue { setNeedsDisplay(fade: true) } }
    }

    init(renderer: Renderer, width: Float, height: Float, distance: Float) {
        let d = distance * Self.density
        super.init(renderer: renderer, size: CGSize(width: CGFloat(width / d * 1000), height: CGFloat(height / d * 1000)), surface: .zero)
        layer.tier = 2
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        let r = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
        let path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
        if lit {
            ctx.addPath(path)
            ctx.setFillColor(NightGlass.accent.withAlphaComponent(0.18).cgColor)
            ctx.fillPath()
        }
        ctx.addPath(path)
        ctx.setStrokeColor((lit ? NightGlass.accent : NSColor(white: 1, alpha: 0.32)).cgColor)
        ctx.setLineWidth(lit ? 1.2 : 0.8)
        if !lit { ctx.setLineDash(phase: 0, lengths: [5, 3.5]) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }
}
