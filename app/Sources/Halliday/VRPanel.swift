// A Halliday-drawn panel in VR (ROADMAP W11.B): a QuadLayer whose texture is drawn with
// CoreGraphics in dmm units (see NightGlass.swift), with buttons used through Halliday's own
// pointer: hover, press, and the action on release, like the Night Glass saber states. Nothing here
// goes through the event tap. Subclasses draw themselves and declare their controls while drawing.

import AppKit
import simd

@MainActor
class VRPanel {
    let renderer: Renderer
    let layer: QuadLayer
    /// Panel size in dmm (the texture's whole area, transparent parts included).
    let size: CGSize
    /// The part of the panel that is a surface for the pointer, in dmm (the rest is transparent,
    /// e.g. room above the dock for tooltips).
    let surface: CGRect
    /// More of the panel that takes the pointer for now (a dropdown that is open), in dmm.
    var extraSurface: CGRect? {
        didSet { if extraSurface != oldValue { updateHitRect() } }
    }
    private var hitSurface: CGRect { extraSurface.map { surface.isEmpty ? $0 : surface.union($0) } ?? surface }

    private func updateHitRect() {
        let s = hitSurface
        layer.hitRect = SIMD4(Float(s.minX / size.width), Float(s.minY / size.height),
                              Float(s.width / size.width), Float(s.height / size.height))
    }

    /// Distance from the eyes it was placed at, in meters (its size in meters follows).
    private(set) var distance: Float = 1
    /// Texture pixels per dmm: a little under 2 texture pixels per pixel of the headset's eye buffer
    /// at the panel's design distance, mipmapped.
    static let pixelsPerDmm: CGFloat = 2

    struct Control {
        let id: String
        let rect: CGRect
        let enabled: Bool
    }

    /// Controls as of the last draw (subclasses add them with `control(_:_:enabled:)`).
    private(set) var controls: [Control] = []
    private(set) var hovered: String?
    private(set) var pressed: String?
    /// Called with a control's id when it is clicked (pressed and released on it).
    var onActivate: ((String) -> Void)?
    /// Called with a control's id when the pointer's button goes down on it (e.g. to start a drag).
    var onPress: ((String) -> Void)?
    /// Called while the button is held, with the pressed control's id and where the pointer is on
    /// the panel's plane (dmm; may be outside the control): sliders follow it.
    var onDrag: ((String, CGPoint) -> Void)?
    /// Where the pointer last was on the panel (dmm).
    private(set) var lastPoint: CGPoint?

    init(renderer: Renderer, size: CGSize, surface: CGRect? = nil) {
        self.renderer = renderer
        self.size = size
        self.surface = surface ?? CGRect(origin: .zero, size: size)
        layer = QuadLayer(texture: renderer.placeholderTexture, position: [0, 1, -1], width: Float(size.width) / 1000)
        layer.aspect = Float(size.height / size.width)
        layer.presence = 0 // it fades in when first shown
        updateHitRect()
    }

    /// Whether the panel is meant to be seen. Its layer fades and settles in or out ("standard",
    /// 220 ms); keep the layer in the scene while `isVisible`.
    var isShown: Bool {
        get { layer.shown }
        set {
            guard newValue != layer.shown else { return }
            layer.shown = newValue
            if newValue { setNeedsDisplay() } // up to date (and its caret blinking) as it appears
        }
    }
    /// Shown, or still fading out.
    var isVisible: Bool { layer.shown || layer.presence > 0.001 }

    /// Moves the panel with `move` (a `place` or `attach` call) and lets it glide there from where
    /// it is ("travel", 420 ms), turning around `pivot` (the viewer).
    func glide(around pivot: SIMD3<Float>, _ move: () -> Void) {
        let was = layer.target, drawn = layer.rendered
        move()
        layer.settle(was: was, drawn: drawn, pivot: pivot)
    }

    /// Draws the panel's glass at `rect` (call from `drawBackground`) and tells the renderer where
    /// it is: there the place behind shows blurred, and a soft shadow falls around it.
    func drawGlass(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, solid: Bool = false) {
        NightGlass.drawGlass(ctx, rect, radius: radius, solid: solid)
        declareGlass(rect, radius: radius)
    }

    /// Two pieces of glass of the same corner radius (the dock: its clock beside its apps).
    func drawGlass(_ ctx: CGContext, _ first: CGRect, _ second: CGRect, radius: CGFloat) {
        NightGlass.drawGlass(ctx, first, radius: radius)
        NightGlass.drawGlass(ctx, second, radius: radius)
        declareGlass(first, radius: min(radius, second.height / 2), second: second)
    }

    /// Tells the renderer where the panel's glass is, for a glass the panel draws itself.
    func declareGlass(_ rect: CGRect?, radius: CGFloat = 0, second: CGRect? = nil) {
        guard let rect else {
            layer.glassRect = nil
            layer.glassRect2 = nil
            return
        }
        func part(_ r: CGRect) -> SIMD4<Float> {
            SIMD4(Float(r.minX / size.width), Float(r.minY / size.height), Float(r.width / size.width), Float(r.height / size.height))
        }
        layer.glassRect = part(rect)
        layer.glassRect2 = second.map(part)
        layer.glassRadius = Float(min(radius, rect.height / 2) / size.width)
    }

    /// Set while drawing by anything that moves by itself (a spinner, a loading placeholder): the
    /// panel is then redrawn about 30 times a second for as long as it is shown.
    var animates = false
    private var lastDisplay = 0.0

    // --- Motion inside panels (design board 9) ---

    private var eased: [String: (value: CGFloat, target: CGFloat)] = [:]
    /// Set while drawing when an eased value is still on its way: the panel redraws every frame.
    private var easing = false
    /// When the panel must redraw next by itself (a caret's blink), if sooner than anything else.
    private var redrawAt: Double?

    /// A value that eases toward `target` ("quick", 120 ms; `time` for others), for things that
    /// slide (a toggle's knob, the selected segment, a list's offset). The first value is the
    /// target. With "reduce motion" it is the target at once.
    func eased(_ key: String, _ target: CGFloat, time: Double = Motion.quick) -> CGFloat {
        guard let e = eased[key], !Motion.reduced else {
            eased[key] = (target, target)
            return target
        }
        let dt = min(0.1, CACurrentMediaTime() - lastEaseTime)
        var v = e.value + (target - e.value) * CGFloat(1 - exp(-dt / (time / 3)))
        if abs(target - v) < 0.002 * max(1, abs(target)) { v = target } else { easing = true }
        eased[key] = (v, target)
        return v
    }
    private var lastEaseTime = CACurrentMediaTime()

    /// The eased value `key` jumps to its next target (new content: no glide from the old one).
    func snap(_ key: String) { eased[key] = nil }

    private var caretText: String?
    private var caretSince = 0.0

    /// Whether a text field's caret shows now: it blinks (on 0.6 s of every 1.06 s) and is solid
    /// again whenever `text` changes. The panel redraws by itself when it blinks.
    func caretOn(for text: String) -> Bool {
        let now = CACurrentMediaTime(), period = 1.06, lit = 0.6
        if text != caretText {
            caretText = text
            caretSince = now
        }
        let t = now - caretSince, phase = t.truncatingRemainder(dividingBy: period)
        let on = phase < lit
        redraw(at: now - phase + (on ? lit : period) + 0.001)
        return on
    }

    /// Asks for a redraw at `time` (`CACurrentMediaTime`), e.g. when a caret blinks.
    func redraw(at time: Double) {
        if redrawAt.map({ time < $0 }) ?? true { redrawAt = time }
        Self.live.add(self)
    }

    /// Places the panel `distance` m from the head, `below` degrees under eye level, facing the
    /// eyes, in the direction the head looks (yaw only). `yawOffset` is radians to the left.
    func place(head: HeadPose, distance: Float, below degrees: Float, yawOffset: Float = 0) {
        self.distance = distance
        layer.glide = nil
        layer.width = NightGlass.meters(size.width, at: distance)
        let fwd = head.orientation.act(SIMD3<Float>(0, 0, -1))
        let yaw = simd_quatf(angle: atan2(-fwd.x, -fwd.z) + yawOffset, axis: [0, 1, 0])
        let pitch = degrees * .pi / 180
        // Tilted back so it faces the eyes from below.
        layer.orientation = yaw * simd_quatf(angle: -pitch, axis: [1, 0, 0])
        layer.position = head.position + yaw.act(SIMD3(0, -sin(pitch) * distance, -cos(pitch) * distance))
    }

    /// Attaches the panel above or below `target` (same orientation, centered), its surface `gap`
    /// dmm from the target's edge. `distance` is how far the target is from the viewer.
    func attach(above target: QuadLayer, distance: Float, gap: CGFloat) { attach(to: target, below: false, distance: distance, gap: gap) }
    func attach(below target: QuadLayer, distance: Float, gap: CGFloat) { attach(to: target, below: true, distance: distance, gap: gap) }

    /// Attaches the panel to the right of `target`, tops aligned, `gap` dmm from its edge.
    func attach(rightOf target: QuadLayer, distance: Float, gap: CGFloat) {
        self.distance = distance
        layer.width = NightGlass.meters(size.width, at: distance)
        layer.travel(with: target) // it travels with what it is attached to
        layer.orientation = target.orientation
        let right = target.width / 2 + NightGlass.meters(gap + size.width / 2 - surface.minX, at: distance)
        let up = target.height / 2 - NightGlass.meters(size.height / 2 - surface.minY, at: distance)
        layer.position = target.position + target.orientation.act(SIMD3(right, up, 0))
    }

    /// Puts the panel's center at `center`, facing as `orientation`, sized for `distance`.
    func place(center: SIMD3<Float>, orientation: simd_quatf, distance: Float) {
        self.distance = distance
        layer.glide = nil
        layer.width = NightGlass.meters(size.width, at: distance)
        layer.orientation = orientation
        layer.position = center
    }

    private func attach(to target: QuadLayer, below: Bool, distance: Float, gap: CGFloat) {
        self.distance = distance
        layer.width = NightGlass.meters(size.width, at: distance)
        layer.travel(with: target)
        layer.orientation = target.orientation
        let up = below
            ? -(target.height / 2 + NightGlass.meters(gap + size.height / 2 - surface.minY, at: distance))
            : target.height / 2 + NightGlass.meters(gap + surface.maxY - size.height / 2, at: distance)
        let right = NightGlass.meters(size.width / 2 - surface.midX, at: distance)
        layer.position = target.position + target.orientation.act(SIMD3(right, up, 0))
    }

    // --- Pointer ---

    /// Where a world ray meets the panel, in dmm (top-left origin), if within the panel's area.
    func point(origin: SIMD3<Float>, direction: SIMD3<Float>) -> CGPoint? {
        let inv = layer.orientation.inverse
        let o = inv.act(origin - layer.position), d = inv.act(direction)
        guard abs(d.z) > 1e-6 else { return nil }
        let t = -o.z / d.z
        guard t > 0 else { return nil }
        let p = o + t * d
        let w = layer.width, h = layer.height
        guard abs(p.x) <= w / 2, abs(p.y) <= h / 2 else { return nil }
        return CGPoint(x: CGFloat(p.x / w + 0.5) * size.width, y: CGFloat(0.5 - p.y / h) * size.height)
    }

    /// True if the ray is on the panel's surface (where clicks belong to the panel).
    func isOnSurface(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Bool {
        point(origin: origin, direction: direction).map(hitSurface.contains) ?? false
    }

    /// The control at `p`: the one containing it, else the nearest enabled one within `reach` dmm
    /// (targets are a little "magnetic", so a pointer just off a button still gets it).
    private func control(at p: CGPoint?, reach: CGFloat = VRPanel.magnet) -> Control? {
        guard let p else { return nil }
        if let hit = controls.last(where: { $0.rect.contains(p) }) { return hit }
        var best: (Control, CGFloat)?
        for c in controls where c.enabled {
            let dx = max(c.rect.minX - p.x, 0, p.x - c.rect.maxX), dy = max(c.rect.minY - p.y, 0, p.y - c.rect.maxY)
            let d = hypot(dx, dy)
            if d <= reach, d < (best?.1 ?? .infinity) { best = (c, d) }
        }
        return best?.0
    }

    /// How far outside a control the pointer still counts as on it (dmm).
    static let magnet: CGFloat = 8
    /// How far the pointer may slip between press and release for the click to still count (dmm).
    static let slop: CGFloat = 24
    /// Where the current press began.
    private var pressPoint: CGPoint?
    /// Debug (`--ui-log`): log what became of every press.
    static let logsPresses = CommandLine.arguments.contains("--ui-log")
    /// Debug (`--show-hit-areas`): outline every control's hit area.
    static let showsHitAreas = CommandLine.arguments.contains("--show-hit-areas")

    private var name: String { String(describing: type(of: self)) }

    /// Follows the pointer; redraws when the hovered control changes. Returns true if the pointer
    /// is on the panel's surface.
    @discardableResult
    func hover(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Bool {
        let p = point(origin: origin, direction: direction)
        if let p { lastPoint = p }
        if let pressed, let p { onDrag?(pressed, p) }
        // While a control is held, it stays the hovered one: the pointer slipping onto a neighbour
        // must not light that neighbour up.
        let id = pressed ?? control(at: p).flatMap { $0.enabled ? $0.id : nil }
        if id != hovered {
            let before = hovered
            hovered = id
            hoverChanged(from: before, to: id)
            if id != nil, pressed == nil { Sounds.play(.hover) }
        }
        return p.map(hitSurface.contains) ?? false
    }

    /// The pointer is elsewhere (on a panel in front of this one, or nowhere).
    func clearHover() {
        guard hovered != nil, pressed == nil else { return }
        let before = hovered
        hovered = nil
        hoverChanged(from: before, to: nil)
    }

    /// The panel's surface as a rectangle in space, for the input thread.
    var snapshot: PanelSnapshot {
        let m = layer.width / Float(size.width) // meters per dmm
        let s = hitSurface
        let offset = SIMD3(Float(s.midX - size.width / 2) * m, Float(size.height / 2 - s.midY) * m, 0)
        return PanelSnapshot(position: layer.position + layer.orientation.act(offset), orientation: layer.orientation,
                             width: Float(s.width) * m, height: Float(s.height) * m)
    }

    /// A press of the pointer's button. Returns true if it landed on the panel (consumed).
    func press(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Bool {
        let p = point(origin: origin, direction: direction)
        guard let p, hitSurface.contains(p) else { return false }
        lastPoint = p
        if let c = control(at: p), c.enabled {
            pressed = c.id
            pressPoint = p
            hovered = c.id
            setNeedsDisplay() // at once: a press must be seen the moment it happens
            Sounds.play(.press)
            onPress?(c.id)
        } else if Self.logsPresses {
            log(String(format: "[ui] %@: press at %.0f,%.0f on no control", name, p.x, p.y))
        }
        return true
    }

    /// The release: activates the pressed control if the pointer is still on it, or slipped only a
    /// little since the press (a click is not a test of holding still).
    func release(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        guard let id = pressed else { return }
        let p = point(origin: origin, direction: direction)
        let moved = p.flatMap { p in pressPoint.map { hypot(p.x - $0.x, p.y - $0.y) } }
        let onIt = control(at: p, reach: Self.magnet * 2)?.id == id
        let fires = onIt || (moved ?? .infinity) <= Self.slop
        pressed = nil
        pressPoint = nil
        hovered = control(at: p).flatMap { $0.enabled ? $0.id : nil }
        setNeedsDisplay(fade: true)
        if fires { Sounds.play(.release) }
        if Self.logsPresses {
            log(String(format: "[ui] %@: %@ %@ (moved %.0f dmm)", name, id, fires ? "fired" : "cancelled: released off the control", moved ?? -1))
        }
        if fires { onActivate?(id) }
    }

    /// Drops a press without firing it (the button went up somewhere the release never reached us).
    func cancelPress() {
        guard let id = pressed else { return }
        pressed = nil
        pressPoint = nil
        setNeedsDisplay(fade: true)
        if Self.logsPresses { log("[ui] \(name): \(id) cancelled: no release arrived") }
    }

    // --- Drawing ---

    /// Declares a control drawn at `rect` (call from `draw`).
    func control(_ id: String, _ rect: CGRect, enabled: Bool = true) {
        controls.append(Control(id: id, rect: rect, enabled: enabled))
    }

    /// Draws the panel. Subclasses override; units are dmm, origin top-left.
    func draw(in ctx: CGContext) {}

    /// Draws what never changes (the glass). Drawn once and kept: filling a large translucent shape
    /// on every redraw was most of a redraw's cost.
    func drawBackground(in ctx: CGContext) {}

    // Redrawing is deferred and reuses everything: a panel is marked dirty and drawn at most once
    // per frame (`displayAll`), into a bitmap and a texture it keeps. (Allocating a texture and
    // waiting for its mipmaps on every hover change stalled frames while the pointer moved.)

    private var dirty = false
    nonisolated(unsafe) private var bitmap: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var background: UnsafeMutableRawPointer?
    private var context: CGContext?
    private var texture: MTLTexture?
    /// The texture not in use: a redraw that fades goes into it, and the two swap.
    private var spare: MTLTexture?
    private var fades = false
    private static let live = NSHashTable<VRPanel>.weakObjects()

    /// True for a panel whose hover shows only inside the hovered control (no tooltip, nothing
    /// elsewhere): a change of hover then redraws and uploads just the controls it touched. Home
    /// took 9 to 13 ms to redraw whole, more than a 120 Hz frame, so each control the pointer
    /// crossed while the head turned dropped a frame and the view jumped.
    var hoverIsLocal: Bool { false }
    /// The part to redraw, while every request since the last redraw was a local hover change.
    private var localOnly = false
    private var localRegion = CGRect.null

    private func hoverChanged(from old: String?, to new: String?) {
        let rects = [old, new].compactMap { id in id.flatMap { id in controls.first { $0.id == id }?.rect } }
        guard hoverIsLocal, rects.count == [old, new].compactMap({ $0 }).count, !rects.isEmpty else {
            setNeedsDisplay(fade: true)
            return
        }
        let region = rects.reduce(CGRect.null) { $0.union($1.insetBy(dx: -6, dy: -6)) }
        if !dirty {
            localOnly = true
            localRegion = region
        } else if localOnly {
            localRegion = localRegion.union(region)
        }
        dirty = true
        fades = true
        Self.live.add(self)
    }

    /// Marks the panel for redrawing before the next frame. `fade`: the new picture fades in over
    /// the old one ("quick", 120 ms), for changes of state (hover, release); content that follows
    /// the hand or the clock (sliders, lists, typing) changes at once.
    func setNeedsDisplay(fade: Bool = false) {
        localOnly = false
        dirty = true
        if fade { fades = true }
        Self.live.add(self)
    }

    /// Redraws every panel that changed (call once per frame, before rendering), and the ones
    /// showing something that moves by itself.
    static func displayAll() {
        let now = CACurrentMediaTime()
        for panel in live.allObjects {
            if panel.animates, !panel.dirty, panel.isVisible, now - panel.lastDisplay > 1.0 / 30 { panel.setNeedsDisplay() }
            if panel.easing, panel.isVisible { panel.setNeedsDisplay() }
            if let at = panel.redrawAt, now >= at {
                panel.redrawAt = nil
                if panel.isVisible { panel.setNeedsDisplay() } // a hidden panel's caret stops until it is shown
            }
            if panel.dirty { panel.display() }
        }
    }

    /// Debug (`--ui-bench`): redraws every live panel ten times and logs the average time of each.
    static func benchmark() {
        for panel in live.allObjects {
            let started = CACurrentMediaTime()
            for _ in 0..<10 { panel.display(quiet: true) }
            log(String(format: "[ui] bench: %@ redraw %.1f ms", String(describing: type(of: panel)), (CACurrentMediaTime() - started) * 100))
        }
    }

    private func display(quiet: Bool = false) {
        dirty = false
        animates = false
        easing = false
        let fade = fades
        fades = false
        let started = CACurrentMediaTime()
        lastDisplay = started
        defer {
            // A redraw that eats most of a 120 Hz frame is worth knowing about.
            let ms = (CACurrentMediaTime() - started) * 1000
            if ms > 6, !quiet { log(String(format: "[ui] slow panel redraw: %@ took %.1f ms", String(describing: type(of: self)), ms)) }
        }
        let scale = Self.pixelsPerDmm
        let w = Int(size.width * scale), h = Int(size.height * scale)
        if context == nil {
            bitmap = calloc(w * h, 4)
            context = CGContext(data: bitmap, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.translateBy(x: 0, y: CGFloat(h))
            context?.scaleBy(x: scale, y: -scale) // top-left origin, dmm units
        }
        guard let ctx = context, let bitmap else { return }
        // A local hover change: only its part of the picture, in pixels (rows from the top).
        var part: (x: Int, y: Int, w: Int, h: Int)?
        if localOnly, background != nil, texture != nil, !quiet {
            let r = localRegion.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            if !r.isEmpty { part = (Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)) }
        }
        localOnly = false
        localRegion = .null
        controls = []
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        if background == nil {
            ctx.clear(CGRect(origin: .zero, size: size))
            drawBackground(in: ctx)
            background = malloc(w * h * 4)
            memcpy(background, bitmap, w * h * 4)
        } else if let part, let background {
            for row in part.y..<part.y + part.h {
                let at = (row * w + part.x) * 4
                memcpy(bitmap + at, background + at, part.w * 4)
            }
        } else {
            memcpy(bitmap, background, w * h * 4)
        }
        if let part {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: CGFloat(part.x) / scale, y: CGFloat(part.y) / scale, width: CGFloat(part.w) / scale, height: CGFloat(part.h) / scale))
            draw(in: ctx)
            ctx.restoreGState()
        } else {
            draw(in: ctx)
        }
        lastEaseTime = CACurrentMediaTime()
        if Self.showsHitAreas {
            ctx.setStrokeColor(NSColor.systemPink.cgColor)
            ctx.setLineWidth(1)
            for c in controls { ctx.stroke(c.rect) }
        }
        NSGraphicsContext.restoreGraphicsState()
        let drawn = CACurrentMediaTime()
        defer {
            if Self.logsPresses, !quiet {
                log(String(format: "[ui] %@: draw %.1f ms, upload %.1f ms", name, (drawn - started) * 1000, (CACurrentMediaTime() - drawn) * 1000))
            }
        }
        if let part, let old = texture {
            if fade, layer.presence > 0, let other = spare, other.width == w, other.height == h,
               renderer.updateLayerTexture(other, from: old, width: w, bytes: bitmap, part: part) {
                spare = old
                texture = other
                layer.previousTexture = old
                layer.fade = 0
                layer.texture = other
                return
            } else if !(fade && layer.presence > 0), renderer.updateLayerTexture(old, from: nil, width: w, bytes: bitmap, part: part) {
                return
            }
        }
        if fade, !quiet, let old = texture, layer.presence > 0 {
            // The picture until now fades out under the new one, drawn into the other texture.
            if let t = renderer.updateLayerTexture(spare, width: w, height: h, bytes: bitmap) {
                spare = old
                texture = t
                layer.previousTexture = old
                layer.fade = 0
                layer.texture = t
            }
        } else if let t = renderer.updateLayerTexture(texture, width: w, height: h, bytes: bitmap) {
            texture = t
            layer.texture = t
        }
    }

    deinit {
        free(bitmap)
        free(background)
    }
}
