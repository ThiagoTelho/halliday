// Compositor skeleton: renders both eyes into a side-by-side texture, then applies the lens
// distortion mesh into the output drawable (the headset panel, or a preview window).

import CHallidayCore
import Foundation
import Metal
import QuartzCore
import simd

/// Must match `SceneUniforms` in Shaders.swift.
struct SceneUniforms {
    var tanLRUD: SIMD4<Float>
    var eyePosition: SIMD4<Float>
    var rotation: simd_float4x4
    var params: SIMD4<Float>
    /// xyz: world direction of the pointer ray from the head; w: 1 to draw the cursor.
    var cursor: SIMD4<Float>
    /// x: hovered layer index or -1.
    var highlight: SIMD4<Float>
    var projFromWorld: simd_float4x4
    var projUV: SIMD4<Float>
    var projTan: SIMD4<Float>
    var projFlags: SIMD4<Float>
    var videoFromWorld: simd_float4x4
    var videoParams: SIMD4<Float>
    var videoTilt: simd_float4x4
    var videoView: SIMD4<Float>
    var videoKey: SIMD4<Float>
    var videoKeyFit: SIMD4<Float>
    /// The saber: xyz start (the hand, or below the chin); w: 1 = draw.
    var saberStart: SIMD4<Float>
    /// xyz: where it ends; w: 1 = it lands on a surface (draw the cursor ring there).
    var saberEnd: SIMD4<Float>
    /// x: brightness (idle .. pressed), y: 1 = pressed, z: 1 = no hand (the beam fades in).
    var saberParams: SIMD4<Float>
    /// x: 1 = draw the reference boxes, y: hold-to-recenter progress (0 = no ring … 1).
    var envParams: SIMD4<Float>
    /// Positional reprojection of an immersive page: xyz how far the head moved since the frame was
    /// rendered (m), w the depth the scene is taken to be at (m; 0 = rotation only).
    var projShift: SIMD4<Float>
    /// Desktop view: the right eye's FOV tangents of the projection layer (zero: none).
    var projTanOther: SIMD4<Float>
    /// A game's fades (premultiplied colors): over its frames, over the place shown instead.
    var gameFade: SIMD4<Float>
    var gameBackgroundFade: SIMD4<Float>
    /// x: Halliday is up over the game (0..1): its frames dimmed and blurred.
    var gameAway: SIMD4<Float>
    /// Passthrough: the cameras' frame at the exposure from world; x: how much is shown,
    /// y: focal length (pixels), z, w: this eye's camera's centre.
    var seeFromWorld: simd_float4x4
    var seeParams: SIMD4<Float>
    var seeFishLeft: simd_float4x4
    var seeFishRight: simd_float4x4
    var seeFish: SIMD4<Float>
    var projFromWorldOther: simd_float4x4
    /// w < 0 retains the common-camera desktop fallback.
    var projShiftOther: SIMD4<Float>
}

/// Halliday's pointer beam (Night Glass "saber"): from `start` to `end`, landing on a surface or
/// fading out in the air.
struct Saber {
    enum Mode { case idle, overTarget, pressed }
    var start: SIMD3<Float>
    var end: SIMD3<Float>
    var landsOnSurface: Bool
    /// No ring where it lands (the app's own cursor is drawn there: a text beam, a hand).
    var hidesRing = false
    var mode: Mode
    /// False while the pointer is the mouse: there is no hand, so the beam fades in toward its end.
    var fromHand = false
}

/// A 360°/180°/fisheye video all around the viewer (replaces the environment).
struct VideoSphere {
    var texture: MTLTexture
    /// 0 equirect 360, 1 equirect 180, 2 fisheye (as HallidayVideoFormat.projection).
    var projection: Int32
    /// 0 mono, 1 side by side, 2 top/bottom.
    var stereo: Int32
    var fisheyeFovDeg: Float
    /// Orientation of the video's center (forward) in the world.
    var orientation: simd_quatf
    /// Where the viewer's "straight ahead" looks in the video (identity: at its center).
    var tilt = simd_quatf(angle: 0, axis: [0, 1, 0])
    /// 1 as filmed; above, the picture is larger around the middle of the view.
    var zoom: Float = 1
    /// A video made for passthrough: rgb the backdrop's colour, w 1 = keyed by it, 2 = by
    /// darkness (0: an ordinary video). The room shows there while passthrough is on.
    var key: SIMD4<Float> = .zero
    /// For a backdrop found in the video itself (`key.w` 6): how near its colour a pixel is the
    /// room's (x), from where it is the video's own (y), how much brightness counts (z).
    var keyFit: SIMD4<Float> = .zero
}

/// An immersive page's stereo image (both eyes side by side), shown over the whole view and
/// reprojected from the head rotation it was rendered with to the current one.
struct ProjectionLayer {
    var texture: MTLTexture
    /// Side-by-side image's region of `texture` (x, y, width, height in 0..1).
    var uvRect: SIMD4<Float>
    /// Head rotation the image was rendered with (Halliday tracking space).
    var renderOrientation: simd_quatf
    /// Head position it was rendered from.
    var renderPosition: SIMD3<Float>
    /// Per-eye FOV tangents it was rendered with (left, right, up, down).
    var tangents: (left: SIMD4<Float>, right: SIMD4<Float>)
    /// Its alpha is meant (premultiplied): with passthrough on, the room shows where it is clear.
    var seeThrough = false
    /// An sRGB view of the same storage, for correct hardware decoding before filtering.
    var srgbTexture: MTLTexture? = nil
    /// 0 legacy, 1 linear, 2 sRGB, separately for the two eyes.
    var colourSpaces: SIMD2<UInt32> = .zero
    /// Game frames share one optional pre-reprojection FSR pass. Other projections
    /// (WebXR, videos and the interface) retain their original sampling.
    var gameImage = false
    var imageSequence: UInt64 = 0
    /// Reception time of this real game image, separate from its predicted head pose.
    var imageTime: Double = 0
    var gameHalfRate = false
    var sourceFrameInterval: Double = 0
    /// Changes when cadence changes even if no new real image has arrived.
    var gameCadenceEpoch: UInt64 = 0
    /// Runtime-submitted quads in declaration order, drawn after game-image processing.
    var composition: OpenXRComposition? = nil
    var eyeViews: ProjectionEyeViews? = nil
    /// Explicit diagnostics only. Immutable source identity survives FSR copies.
    var renderedTangents: (left: SIMD4<Float>, right: SIMD4<Float>) {
        eyeViews.map { ($0.left.tangents, $0.right.tangents) } ?? tangents
    }
}

/// Must match `LayerData` in Shaders.swift.
struct LayerData {
    var layerFromWorld: simd_float4x4
    var size: SIMD4<Float>
    /// Region of the texture shown: x, y, width, height in 0..1 (origin top-left).
    var uvRect: SIMD4<Float>
    /// x: 0 mono, 1 side by side, 2 top/bottom (each eye sees its half).
    var stereo: SIMD4<Float>
    /// x: corner radius in meters, y: 1 = it has a glass surface (`glass`), z: the glass's corner
    /// radius (m), w: 1 = the whole layer casts a shadow.
    var shape: SIMD4<Float>
    /// The glass surface: center x, y (meters from the layer's center) and half width, half height.
    var glass: SIMD4<Float>
    /// A second glass surface of the same corner radius (the dock's clock capsule beside its
    /// apps); zero: none.
    var glass2: SIMD4<Float>
    /// A part of the layer covered with the color just to its right (x, y, width, height in 0..1,
    /// origin top-left; zero: none): macOS's recording badge on a captured window.
    var patch: SIMD4<Float>
}

/// Night Glass motion (docs/ui.md, design board 9): three speeds for everything that changes.
enum Motion {
    /// Hover, press, the saber's ring, a window's glow.
    static let quick = 0.12
    /// Panels opening and closing, notices, tooltips.
    static let standard = 0.22
    /// Things that cross space: windows finding their place, recentering.
    static let travel = 0.42
    /// The "reduce motion" setting: fades only, nothing moves or grows.
    nonisolated(unsafe) static var reduced = false
}

/// Most layers drawn at once (must match MAX_LAYERS in Shaders.swift).
let maxLayers = 24

/// A textured rectangle in the world: the building block for Mac windows, panels and video.
final class QuadLayer {
    var texture: MTLTexture
    /// World pose of the rectangle's center; it faces its local +z.
    var position: SIMD3<Float>
    var orientation: simd_quatf
    /// Width in meters.
    var width: Float
    /// Height / width. Nil: the texture's aspect ratio.
    var aspect: Float?
    /// Region of the texture this layer shows (x, y, width, height in 0..1). Windows show their
    /// part of the captured virtual display.
    var uvRect = SIMD4<Float>(0, 0, 1, 1)
    /// 0 mono, 1 side by side, 2 top/bottom: stereo content shows each eye its half.
    var stereo: Int32 = 0
    /// Pixels across the shown region, if not the texture's full width × uvRect width (for mip
    /// selection while the texture is still a placeholder).
    var textureWidthOverride: Float?
    /// Part of the layer that is a surface for the pointer (x, y, width, height in 0..1, origin
    /// top-left); nil: all of it. Transparent margins (shadows, tooltip room) are left out.
    var hitRect: SIMD4<Float>?
    /// Meters taken off the layer's distance when layers are ordered far to near: a panel with a
    /// part that overlaps its neighbour in the same plane (a dropdown) is drawn over it.
    var sortBias: Float = 0
    /// Layers of a higher tier are drawn over those of a lower one whatever their distances
    /// (within a tier, far to near): Halliday's panels (2) and notices (3) are never cut or covered
    /// by a window (0) that reaches in front of them.
    var tier = 0
    /// Drawn at the pointer itself (the app's cursor): a ray looking for what the pointer meets
    /// passes through it. Left in, the pointer met its own cursor a hair in front of the window,
    /// the cursor was put a hair in front of that, and so on towards the viewer, growing.
    var isPointerMark = false
    /// 0 hidden … 1 fully shown.
    var opacity: Float = 1
    /// Whether the layer is meant to be seen: the renderer eases `presence` toward it ("standard",
    /// 220 ms), and the layer fades and grows from 96% as it arrives, the reverse as it leaves.
    var shown = true
    /// 0 gone … 1 here (linear in time; eased when drawn).
    var presence: Float = 1
    /// Starts the layer's arrival from nothing.
    func appear() {
        shown = true
        presence = 0
    }
    /// A move in progress ("travel", 420 ms): the layer is drawn on its way from where it was to
    /// `position`/`orientation`, which already hold where it is going (so pointer tests and
    /// whatever is attached to it use the destination).
    struct Glide {
        var pivot: SIMD3<Float>
        var rotation: simd_quatf
        var translation: SIMD3<Float>
        var start: Double
        var duration: Double
        /// Its width when the glide began: the size eases along with the place.
        var fromWidth: Float
    }

    /// Travels with `target` (a window's bar, menus, resize arc): the same glide, its own width
    /// scaled in the same proportion. Call after setting this layer's width.
    func travel(with target: QuadLayer) {
        guard var g = target.glide else {
            glide = nil
            return
        }
        g.fromWidth = width * (g.fromWidth / max(target.width, 1e-6))
        glide = g
    }

    /// True while a glide is under way (attached bars fade out meanwhile).
    var isGliding: Bool { glide.map { CACurrentMediaTime() - $0.start < $0.duration } ?? false }

    /// The width as drawn right now (between its old and new size during a glide).
    var renderedWidth: Float {
        guard let g = glide else { return width }
        let x = Float((CACurrentMediaTime() - g.start) / g.duration)
        guard x < 1 else { return width }
        let e = x < 0 ? 0 : x * x * (3 - 2 * x)
        return g.fromWidth + (width - g.fromWidth) * e
    }
    var glide: Glide?

    /// Where the layer is drawn right now.
    var rendered: (position: SIMD3<Float>, orientation: simd_quatf) {
        guard let g = glide else { return (position, orientation) }
        let x = Float((CACurrentMediaTime() - g.start) / g.duration)
        guard x < 1 else { return (position, orientation) }
        let e = x < 0 ? 0 : x * x * (3 - 2 * x) // ease in-out
        let s = 1 - e
        let q = simd_slerp(simd_quatf(angle: 0, axis: [0, 1, 0]), g.rotation, s)
        return (q.act(position - g.pivot) + g.pivot + g.translation * s, q * orientation)
    }

    /// Where the layer is going (for `settle`).
    var target: (position: SIMD3<Float>, orientation: simd_quatf) { (position, orientation) }

    /// Call after moving the layer, with where it was going (`was`) and where it was drawn
    /// (`drawn`) before: if its destination changed, it glides there from where it was drawn.
    /// Asking again for the same destination leaves a glide in progress alone.
    func settle(was: (position: SIMD3<Float>, orientation: simd_quatf), drawn: (position: SIMD3<Float>, orientation: simd_quatf), pivot: SIMD3<Float>,
                drawnWidth: Float? = nil) {
        let resized = drawnWidth.map { abs($0 - width) > 0.001 } ?? false
        guard resized || simd_distance(was.position, position) > 0.002 || abs(simd_dot(was.orientation.vector, orientation.vector)) < 0.999999 else { return }
        glide(from: drawn, pivot: pivot, fromWidth: drawnWidth)
    }

    /// The layer glides to where it is now from `old` (where it was drawn), turning around `pivot`
    /// (the viewer, so things on an arc stay on it). With "reduce motion" on it is simply there.
    func glide(from old: (position: SIMD3<Float>, orientation: simd_quatf), pivot: SIMD3<Float>, duration: Double = Motion.travel,
               fromWidth: Float? = nil) {
        guard !Motion.reduced, shown, presence > 0.5 else {
            glide = nil
            return
        }
        let q = old.orientation * orientation.inverse
        glide = Glide(pivot: pivot, rotation: q, translation: old.position - pivot - q.act(position - pivot),
                      start: CACurrentMediaTime(), duration: duration, fromWidth: fromWidth ?? width)
    }

    /// How much the layer shows the hover glow (eased by the renderer toward 1 while it is the
    /// highlighted layer).
    var hoverAmount: Float = 0
    /// What the layer showed before its texture last changed, and how far it has faded to the new
    /// one (0 … 1): state changes of a panel (hover, press) cross-fade instead of cutting.
    var previousTexture: MTLTexture?
    var fade: Float = 1
    /// The glass surface of a Night Glass panel, as a part of the layer (x, y, width, height in
    /// 0..1, origin top-left) with its corner radius as a fraction of the layer's width: there the
    /// scene behind is blurred, and a soft shadow falls around it.
    var glassRect: SIMD4<Float>?
    /// A second glass surface, as `glassRect` (same corner radius).
    var glassRect2: SIMD4<Float>?
    var glassRadius: Float = 0
    /// A soft shadow falls around the whole layer (Mac windows; panels get theirs from their glass).
    var castsShadow = false
    /// See `LayerData.patch`.
    var patch: SIMD4<Float> = .zero
    /// Radius of the layer's rounded corners, in pixels of the shown region (0: square). Mac
    /// windows get the corners Mac apps have.
    var cornerPixels: Float = 0

    init(texture: MTLTexture, position: SIMD3<Float>, orientation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]), width: Float) {
        self.texture = texture
        self.position = position
        self.orientation = orientation
        self.width = width
    }

    var height: Float { width * (aspect ?? Float(texture.height) / Float(texture.width)) }

    /// Distance along a world ray to where it meets the layer's surface, or nil.
    func hit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        let inv = orientation.inverse
        let o = inv.act(origin - position), d = inv.act(direction)
        guard abs(d.z) > 1e-6 else { return nil }
        let t = -o.z / d.z
        guard t > 0 else { return nil }
        let p = o + t * d
        let u = p.x / width + 0.5, v = 0.5 - p.y / height
        let r = hitRect ?? SIMD4(0, 0, 1, 1)
        guard u >= r.x, u <= r.x + r.z, v >= r.y, v <= r.y + r.w else { return nil }
        return t
    }

    private var pixelsAcross: Float { textureWidthOverride ?? Float(texture.width) * uvRect.z }

    var data: LayerData {
        let pose = rendered
        let worldFromLayer = simd_float4x4(translation: pose.position) * simd_float4x4(pose.orientation)
        let arrived = 1 - (1 - presence) * (1 - presence) * (1 - presence) // ease out
        let grow: Float = Motion.reduced ? 1 : 0.96 + 0.04 * arrived
        let opacity = opacity * arrived
        let drawnWidth = renderedWidth
        let width = drawnWidth * grow, height = height * (drawnWidth / max(self.width, 1e-6)) * grow
        return LayerData(
            layerFromWorld: worldFromLayer.inverse,
            size: SIMD4(width, height, pixelsAcross, Float(texture.mipmapLevelCount)),
            uvRect: uvRect,
            stereo: SIMD4(Float(stereo), opacity, hoverAmount, previousTexture == nil ? 1 : fade),
            shape: SIMD4(cornerPixels / max(pixelsAcross, 1) * width, glassRect == nil ? 0 : 1, glassRadius * width, castsShadow ? 1 : 0),
            glass: glassRect.map { g in
                SIMD4((g.x + g.z / 2 - 0.5) * width, (0.5 - g.y - g.w / 2) * height, g.z * width / 2, g.w * height / 2)
            } ?? .zero,
            glass2: glassRect.flatMap { _ in glassRect2 }.map { g in
                SIMD4((g.x + g.z / 2 - 0.5) * width, (0.5 - g.y - g.w / 2) * height, g.z * width / 2, g.w * height / 2)
            } ?? .zero,
            patch: patch)
    }
}

/// Frame timing statistics, written from GPU completion handlers.
final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, gpuTotal = 0.0, gpuMax = 0.0, cpuTotal = 0.0, cpuMax = 0.0
    private var start = CACurrentMediaTime()

    func gpu(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        gpuTotal += seconds; gpuMax = max(gpuMax, seconds)
    }

    func cpu(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        frames += 1; cpuTotal += seconds; cpuMax = max(cpuMax, seconds)
    }

    /// A summary line every `interval` seconds, else nil.
    func report(every interval: Double = 2) -> String? {
        lock.lock(); defer { lock.unlock() }
        let elapsed = CACurrentMediaTime() - start
        guard elapsed >= interval, frames > 0 else { return nil }
        let n = Double(frames)
        let line = String(format: "fps=%.1f cpu=%.2f/%.2fms gpu=%.2f/%.2fms",
                          n / elapsed, cpuTotal / n * 1e3, cpuMax * 1e3, gpuTotal / n * 1e3, gpuMax * 1e3)
        frames = 0; gpuTotal = 0; gpuMax = 0; cpuTotal = 0; cpuMax = 0; start = CACurrentMediaTime()
        return line
    }
}

@MainActor
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    /// For work that must run in order with the frames (the game bridge's copies).
    var commandQueue: MTLCommandQueue { queue }
    private let scenePipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let meshDepthState: MTLDepthStencilState?
    /// The 3D place's geometry (nil: the environment alone).
    var scene3D: Scene3D?
    private var meshTargets: (color: MTLTexture, distance: MTLTexture, depth: MTLTexture)?
    private let distortPipeline: MTLRenderPipelineState
    private let passthroughPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let library: MTLLibrary
    private var gameUpscaler: GameUpscaler?
    private var gameUpscalerFailed = false
    private let spacewarpPreparation = GameSpacewarpPreparation()
    private var spacewarpCadence = GameSpacewarpCadence()
    private var spacewarpEligible = false
    private var spacewarpFailureReported = false
    private struct SpacewarpGeometry: Equatable {
        var size: SIMD2<Int>
        var format: UInt
        var uv: SIMD4<Float>
        var colours: SIMD2<UInt32>
        var left: SIMD4<Float>
        var right: SIMD4<Float>
        var sourceInterval: Double
        var cadenceEpoch: UInt64
    }
    private var spacewarpGeometry: SpacewarpGeometry?
    private var spacewarpSourcePose: (sequence: UInt64, orientation: SIMD4<Float>, position: SIMD3<Float>, eyes: ProjectionEyeViews?)?
    private var spacewarpPredictionKey: SIMD2<UInt64>?
    private(set) var spacewarpSourceFrames: UInt64 = 0
    private(set) var spacewarpGeneratedFrames: UInt64 = 0
    var spacewarpPrepared: Bool { spacewarpPreparation.ready != nil }
    var spacewarpFailure: String? { spacewarpPreparation.failure }

    func prepareSpacewarpIfEnabled() {
        if Settings.shared.gameSpacewarpEnabled { spacewarpPreparation.start(device: device) }
    }

    private func resetSpacewarp() {
        if spacewarpEligible {
            spacewarpPreparation.ready?.reset()
            processedGameKey = nil
        }
        spacewarpEligible = false
        spacewarpCadence.reset()
        spacewarpGeometry = nil
        spacewarpSourcePose = nil
        spacewarpPredictionKey = nil
    }

    /// Predict only opaque game images whose producer actually negotiated half rate.
    /// Game pose/FOV remain those of the latest real frame; fresh-head reprojection follows.
    private func spacewarpProjection(_ original: ProjectionLayer, cb: MTLCommandBuffer) -> ProjectionLayer {
        guard Settings.shared.gameSpacewarpEnabled, original.gameImage, original.gameHalfRate,
              !original.seeThrough, original.imageSequence > 0,
              original.sourceFrameInterval.isFinite,
              (1.0 / 120...1.0 / 20).contains(original.sourceFrameInterval),
              original.uvRect.x == 0, original.uvRect.z == 1,
              abs(original.uvRect.w) == 1,
              min(original.uvRect.y, original.uvRect.y + original.uvRect.w) == 0 else {
            resetSpacewarp(); return original
        }
        prepareSpacewarpIfEnabled()
        guard let processor = spacewarpPreparation.ready else {
            if let problem = spacewarpPreparation.failure, !spacewarpFailureReported {
                spacewarpFailureReported = true
                log("[spacewarp] AMD Optical Flow unavailable: \(problem); keeping real frames")
            }
            return original
        }
        spacewarpEligible = true
        let geometry = SpacewarpGeometry(size: SIMD2(original.texture.width, original.texture.height),
            format: original.texture.pixelFormat.rawValue, uv: original.uvRect,
            colours: original.colourSpaces, left: original.renderedTangents.left, right: original.renderedTangents.right,
            sourceInterval: original.sourceFrameInterval, cadenceEpoch: original.gameCadenceEpoch)
        var discontinuity = spacewarpGeometry != geometry
        if let prior = spacewarpSourcePose {
            let sameFrameChangedPose = prior.sequence == original.imageSequence &&
                (prior.orientation != original.renderOrientation.vector || prior.position != original.renderPosition || prior.eyes != original.eyeViews)
            let jumped = simd_distance(prior.position, original.renderPosition) > 0.25 ||
                abs(simd_dot(prior.orientation, original.renderOrientation.vector)) < 0.866
            let eyesJumped = original.eyeViews.flatMap { now in prior.eyes.map { now.jumped(from: $0) } } ?? false
            discontinuity = discontinuity || sameFrameChangedPose || jumped || eyesJumped || ((prior.eyes == nil) != (original.eyeViews == nil))
        }
        if discontinuity {
            processor.reset(); spacewarpCadence.reset(); spacewarpPredictionKey = nil
            processedGameKey = nil
        }
        spacewarpGeometry = geometry
        spacewarpSourcePose = (original.imageSequence, original.renderOrientation.vector, original.renderPosition, original.eyeViews)
        let now = CACurrentMediaTime()
        let lateTarget = Double(lateTargetNs) * 1e-9
        let target = lateTarget > 0 && abs(lateTarget - now) < 0.25 ? lateTarget : now
        switch spacewarpCadence.update(sequence: original.imageSequence, sourceTime: original.imageTime,
                                       target: target, sourceInterval: original.sourceFrameInterval) {
        case .source(let reset):
            if reset { processor.reset() }
            let descriptor = GameSpacewarp.Descriptor(orientation: original.renderOrientation.vector,
                position: original.renderPosition, tangentsLeft: original.renderedTangents.left,
                tangentsRight: original.renderedTangents.right, flipped: original.uvRect.w < 0,
                colourSpaces: original.colourSpaces, reprojectionDepth: Self.reprojectionDepth,
                eyeViews: original.eyeViews)
            if processor.prepare(source: original.texture, sequence: original.imageSequence,
                                 descriptor: descriptor, commandBuffer: cb) { spacewarpSourceFrames &+= 1 }
            else { spacewarpCadence.reset(); processor.reset() }
            return original
        case .predict(let phase):
            guard let generated = processor.synthesize(alpha: phase, commandBuffer: cb),
                  let srgb = generated.makeTextureView(pixelFormat: .rgba8Unorm_srgb) else { return original }
            var result = original
            result.texture = generated
            result.srgbTexture = srgb
            result.uvRect = SIMD4(0, 0, 1, 1)
            result.colourSpaces = SIMD2(original.colourSpaces.x == 0 ? 0 : 2,
                                       original.colourSpaces.y == 0 ? 0 : 2)
            let predictionKey = SIMD2(original.imageSequence, UInt64(phase.bitPattern))
            if spacewarpPredictionKey != predictionKey {
                // The same real sequence may be forecast at a different phase.
                // Its output texture is reused; invalidate downstream FSR's cache.
                processedGameKey = nil
                spacewarpPredictionKey = predictionKey
            }
            spacewarpGeneratedFrames &+= 1
            return result
        case .original:
            return original
        }
    }
    private struct GameImageKey: Equatable {
        let source: ObjectIdentifier
        let sequence: UInt64
        let upscale: Bool
        let sharpness: Float
        let colourSpaces: SIMD2<UInt32>
    }
    private var processedGameKey: GameImageKey?
    private var processedGameTexture: MTLTexture?
    private var processedGameSRGB: MTLTexture?

    private func gameProjection(_ original: ProjectionLayer, cb: MTLCommandBuffer) -> ProjectionLayer {
        let settings = Settings.shared
        let sharpness = settings.gameSharpeningEnabled ? settings.gameSharpness : 0
        guard original.gameImage, settings.gameFSREnabled || sharpness > 0, !original.seeThrough,
              original.uvRect.x == 0, original.uvRect.z == 1,
              abs(original.uvRect.w) == 1,
              min(original.uvRect.y, original.uvRect.y + original.uvRect.w) == 0 else { return original }
        let key = GameImageKey(source: ObjectIdentifier(original.texture), sequence: original.imageSequence,
                               upscale: settings.gameFSREnabled, sharpness: sharpness, colourSpaces: original.colourSpaces)
        if processedGameKey != key {
            if gameUpscaler == nil, !gameUpscalerFailed {
                do { gameUpscaler = try GameUpscaler(device: device) }
                catch {
                    gameUpscalerFailed = true
                    log("[game image] FSR unavailable: \(error.localizedDescription)")
                }
            }
            guard let texture = gameUpscaler?.encode(source: original.texture,
                targetWidth: key.upscale ? max(GameImagePlan.targetWidth, original.texture.width / 2) : original.texture.width / 2,
                targetHeight: key.upscale ? max(GameImagePlan.targetHeight, original.texture.height) : original.texture.height,
                sharpness: key.sharpness, colourSpaces: original.colourSpaces, commandBuffer: cb) else { return original }
            // Same-size/no-sharpen and unsupported downscales preserve the original.
            guard texture !== original.texture else { return original }
            processedGameTexture = texture
            processedGameSRGB = texture.makeTextureView(pixelFormat: .rgba8Unorm_srgb)
            processedGameKey = key
        }
        guard let texture = processedGameTexture else { return original }
        if original.colourSpaces != .zero, processedGameSRGB == nil { return original }
        var result = original
        result.texture = texture
        result.srgbTexture = processedGameSRGB
        result.colourSpaces = SIMD2(original.colourSpaces.x == 0 ? 0 : 2,
                                    original.colourSpaces.y == 0 ? 0 : 2)
        return result
    }

    /// A pipeline drawing a fullscreen triangle with fragment function `fragment` (e.g. the video's
    /// YUV conversion).
    func makeFullscreenPipeline(fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreen_vs")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: d)
    }

    var linearSampler: MTLSamplerState { sampler }
    /// Called once with the time the GPU finished the next frame rendered (the headset's pacing).
    var gpuDone: (@Sendable (Double) -> Void)?
    private let placeholder: MTLTexture
    var placeholderTexture: MTLTexture { placeholder }
    private var eyeTexture: MTLTexture
    /// Desktop view (the simulator on a monitor): one undistorted view filling the output, instead
    /// of the headset's two lens-warped eyes squeezed into a window. Much sharper on a monitor.
    var desktopView = false
    /// Half of the desktop view's horizontal field of view, as a tangent (1.1 ≈ 95° across).
    var desktopTanHalfWidth: Float = 1.1
    private var desktopTexture: MTLTexture?
    private var meshes: [(vertices: MTLBuffer, indices: MTLBuffer, count: Int)] = []
    private var meshCalibration: [Float] = []

    var layers: [QuadLayer] = []
    /// Called at the start of each frame's command buffer (e.g. to copy in a captured frame).
    var beforeFrame: [(MTLCommandBuffer) -> Void] = []
    /// When set, a video surrounds the viewer instead of the environment.
    var videoSphere: VideoSphere?
    /// Halliday's interface is up over the video: a 3D one is shown flat (the left eye's
    /// picture to both eyes) and dimmed meanwhile, so its depth doesn't fight the panels.
    var videoUnderInterface = false
    /// A game's skybox (shown while it loads), when no video is around the viewer.
    var gameSkybox: VideoSphere?
    /// What surrounds the viewer: a video, else a game's skybox.
    var sphere: VideoSphere? { videoSphere ?? gameSkybox }
    /// While a game runs: its overlays, drawn over its frames, instead of `layers` (Halliday's own
    /// panels and windows don't show over a game).
    var gameLayers: [QuadLayer]?
    /// A game's fades (premultiplied colors): over its frames, and over the place (or skybox)
    /// shown when it sends none. Its overlays aren't faded.
    var gameFade = SIMD4<Float>.zero
    var gameBackgroundFade = SIMD4<Float>.zero
    /// Halliday is up over a game (0..1, eased by the caller): its frames dim and blur, and
    /// Halliday's own layers are drawn over them instead of the game's overlays.
    var gameAway: Float = 0
    /// Darkens the environment (0 none .. 1 black), e.g. around a movie screen.
    var environmentDimming: Float = 0
    /// The user's own dimming of the environment (Settings); the stronger of the two applies.
    var baseDimming: Float = 0
    var distortionEnabled = true
    /// The depth an immersive page's scene is taken to be at when the head moved after a frame was
    /// rendered (positional reprojection without the page's depth): near enough for the objects
    /// people look at in VR pages, far enough that a distant background barely swims.
    /// `--reprojection-depth M` tries another (a scene nearer or farther than it slides as the
    /// head moves sideways, the more the older its frame).
    static let reprojectionDepth: Float = {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--reprojection-depth").flatMap { $0 + 1 < a.count ? Float(a[$0 + 1]) : nil }.map { max(0.2, $0) } ?? 2
    }()

    /// Pointer ray direction in world space (from the head), drawn as a cursor when set.
    var cursorDirection: SIMD3<Float>?
    /// Index into `layers` of the layer under the pointer.
    var highlightedLayer: Int?
    /// The place the user stands in: 0 grid, 1 dusk, 2 terrace, 3 focus, 4 a 360° image
    /// (`environmentTexture`, turned by `environmentYaw`). See Environments.swift.
    var environment: Int32 = 0
    var environmentTexture: MTLTexture?
    var environmentYaw: Float = 0
    // Dusk and Terrace are baked into a 360° picture (see env_bake_fs): all of it when the place is
    // chosen, then a strip per frame, starting over every few seconds.
    private var bakePipeline: MTLRenderPipelineState?
    private var bakedEnvironment: MTLTexture?
    private var bakedPlace: Int32 = -1
    private var bakeStrip = 0
    private var bakeTime: Float = 0
    private var lastBakeFinished = 0.0
    private static let bakeSize = (width: 4096, height: 2048), bakeStrips = 64
    /// Encoded work, for the offscreen compositor oracle (no timing/recording).
    private(set) var environmentBakePasses: UInt64 = 0
    private(set) var environmentGeometryPasses: UInt64 = 0

    /// The Forest's fireflies this frame (xyz in meters, w brightness), worked out once here rather
    /// than per pixel; `firefly_count` in the shader must match.
    static let fireflyCount = 12
    static func fireflies(time: Float) -> [SIMD4<Float>] {
        (0..<fireflyCount).map { i in
            let f = Float(i)
            let blink = 0.5 + 0.5 * sin(time * (0.7 + 0.13 * f) + f * 5)
            return SIMD4(sin(f * 2.4 + time * (0.05 + 0.02 * f)) * (4 + fmod(f * 3.7, 6)),
                         0.6 + 0.8 * (f * 0.37 - floor(f * 0.37)) + 0.3 * sin(time * 0.3 + f),
                         -2 - cos(f * 1.7 + time * 0.04) * (4 + fmod(f * 2.3, 5)),
                         blink * blink * 1.2)
        }
    }

    /// Places painted into the 360° picture by `env_bake_fs`: Dusk, Terrace and those of round 4
    /// (5 sea, 6 dunes, 7 forest, 8 snow, 9 deep space) and the lounge's far view (10).
    static func isBaked(_ place: Int32) -> Bool { place == 1 || place == 2 || (place >= 5 && place <= 10) }

    private func bakeEnvironment(_ cb: MTLCommandBuffer) {
        guard Self.isBaked(environment) else { return }
        if bakePipeline == nil { bakePipeline = try? makeFullscreenPipeline(fragment: "env_bake_fs", format: .rgb10a2Unorm) }
        if bakedEnvironment == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgb10a2Unorm, width: Self.bakeSize.width, height: Self.bakeSize.height, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            d.mipmapLevelCount = 8 // the coarse levels are the blurred place seen through glass
            bakedEnvironment = device.makeTexture(descriptor: d)
        }
        guard let pipeline = bakePipeline, let target = bakedEnvironment else { return }
        let now = CACurrentMediaTime()
        let whole = bakedPlace != environment // a new place: paint all of it now
        if whole {
            bakedPlace = environment
            bakeStrip = 0
            bakeTime = Float(now - startTime)
        } else if bakeStrip >= Self.bakeStrips {
            // Finished: rest, then start over with the time as it is by then.
            // Places whose picture only twinkles rest longer than those with moving clouds, swell
            // or aurora.
            let rest: Double = [6, 7, 9].contains(environment) ? 12 : 2
            guard now - lastBakeFinished > rest else { return }
            bakeStrip = 0
            bakeTime = Float(now - startTime)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = whole ? .dontCare : .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        environmentBakePasses &+= 1
        enc.setRenderPipelineState(pipeline)
        var uniforms = SIMD4<Float>(Float(environment), bakeTime, 1.65, 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        if !whole {
            let h = Self.bakeSize.height / Self.bakeStrips
            enc.setScissorRect(MTLScissorRect(x: 0, y: bakeStrip * h, width: Self.bakeSize.width, height: h))
            bakeStrip += 1
        } else {
            bakeStrip = Self.bakeStrips
        }
        let finished = bakeStrip >= Self.bakeStrips
        if finished { lastBakeFinished = now }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        if finished, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }
    }

    private var lastFrameTime = CACurrentMediaTime()
    private var saberEnergy: Float = 0
    private var saberPress: Float = 0
    /// The environment's brightness while changing place (it dips to black and comes back).
    private var environmentFade: Float = 1
    /// A change of scene (into or out of a video around the viewer, a picture, a VR page, or one
    /// that the owner announces with `fadeScene`) cuts to black and fades back up (design board 9:
    /// scenes cross-fade; the old one can't be kept, so it comes up from black).
    private var sceneFadeStart = -10.0
    private var lastSceneKey = ""
    private var sceneBrightness: Float = 1
    func fadeScene() { sceneFadeStart = CACurrentMediaTime() }

    private var pendingEnvironment: (index: Int32, texture: MTLTexture?, scene: Scene3D?)?
    private var hasRendered = false
    private var shownDimming: Float = 0

    /// Changes the place: the current one fades to black, then the new one fades in.
    /// `scene`: a 3D place's geometry, drawn in front of the environment (nil: none).
    func setEnvironment(_ index: Int32, texture: MTLTexture?, scene: Scene3D? = nil) {
        guard index != environment || texture !== environmentTexture || scene !== scene3D || pendingEnvironment != nil else { return }
        pendingEnvironment = (index, texture, scene)
    }
    /// Hold-to-recenter: how full the timer ring in the middle of the view is (0 hides it).
    var recenterProgress: Float = 0
    /// The pointer beam; nil hides it (the cursor ring alone is drawn, as before).
    var saber: Saber?

    /// An immersive game owns its pointer. Halliday's menu beam and independent
    /// head-direction ring must both disappear, including while the game loads.
    /// Only an explicit mouse-enabled game overlay can supply a host beam there.
    func setInterfacePointer(_ menu: Saber?, direction: SIMD3<Float>, gameActive: Bool, gameOverlay: Saber?) {
        cursorDirection = gameActive ? nil : direction
        saber = gameActive ? gameOverlay : menu
    }
    /// The colored boxes around the origin (front red, left green, right blue, behind yellow), for
    /// checking tracking and orientation. Off by default (`--reference-boxes`).
    var showReferenceBoxes = false
    /// When set, an immersive page covers the whole view (environment and layers are hidden).
    var projection: ProjectionLayer?
    /// Distance between the eyes in meters.
    var ipd: Float = 0.064
    let stats = FrameStats()
    private let startTime = CACurrentMediaTime()

    /// Per-eye render size. The lenses magnify the center, so render above panel resolution.
    init(device: MTLDevice, eyeSize: Int) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.metal("command queue") }
        self.queue = queue
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        self.library = library

        func pipeline(_ vs: String, _ fs: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        scenePipeline = try pipeline("fullscreen_vs", "scene_fs", format: .rgba8Unorm)
        // The geometry pass of 3D places: color and distance per pixel, with a depth buffer.
        let md = MTLRenderPipelineDescriptor()
        md.vertexFunction = library.makeFunction(name: "mesh_vs")
        md.fragmentFunction = library.makeFunction(name: "mesh_fs")
        md.colorAttachments[0].pixelFormat = .rgba16Float
        md.colorAttachments[1].pixelFormat = .r32Float
        md.depthAttachmentPixelFormat = .depth32Float
        meshPipeline = try device.makeRenderPipelineState(descriptor: md)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        meshDepthState = device.makeDepthStencilState(descriptor: ds)
        distortPipeline = try pipeline("distort_vs", "distort_fs", format: .bgra8Unorm)
        passthroughPipeline = try pipeline("fullscreen_vs", "passthrough_fs", format: .bgra8Unorm)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sd.maxAnisotropy = 4
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw RendererError.metal("sampler") }
        self.sampler = sampler

        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let placeholder = device.makeTexture(descriptor: pd) else { throw RendererError.metal("texture") }
        self.placeholder = placeholder
        eyeTexture = try Renderer.makeEyeTexture(device: device, eyeSize: eyeSize)
    }

    /// The eyes' texture for another size (a headset connected after launch: 2304 an eye instead
    /// of the Mac screen's 1280). Frames in flight keep the textures they hold.
    func setEyeSize(_ eyeSize: Int) {
        guard eyeTexture.height != eyeSize, let t = try? Renderer.makeEyeTexture(device: device, eyeSize: eyeSize) else { return }
        eyeTexture = t
        spareEyeTexture = nil
    }

    private static func makeEyeTexture(device: MTLDevice, eyeSize: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: eyeSize * 2, height: eyeSize, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.metal("eye texture") }
        return t
    }

    /// Rebuilds the distortion meshes when the lens calibration changes.
    private func updateMeshes(calibration: [Float]) {
        guard calibration != meshCalibration else { return }
        meshCalibration = calibration
        meshes = [Eye.left, .right].compactMap { eye in
            guard let m = Optics.distortionMesh(calibration: calibration, eye: eye),
                  let vb = device.makeBuffer(bytes: m.vertices, length: m.vertices.count * MemoryLayout<HallidayMeshVertex>.stride),
                  let ib = device.makeBuffer(bytes: m.indices, length: m.indices.count * 4)
            else { return nil }
            return (vb, ib, m.indices.count)
        }
    }

    /// Distance along a world ray to the nearest layer surface, or nil.
    func nearestHit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        layers.prefix(maxLayers).compactMap { $0.isPointerMark ? nil : $0.hit(origin: origin, direction: direction) }.min()
    }

    /// `desktop`: the size in pixels of the desktop view's output; nil for a headset eye.
    private func uniforms(eye: Eye, head: HeadPose, layerCount: Int, highlight: Int?, desktop: (width: Int, height: Int)? = nil) -> SceneUniforms {
        let fov = Optics.fov(eye)
        let rotation = simd_float4x4(head.orientation)
        let side: Float = desktop != nil ? 0 : (eye == .left ? -0.5 : 0.5)
        let eyePos = head.position + head.orientation.act(SIMD3(side * ipd, 0, 0))
        var tangents = SIMD4(tan(fov.left), tan(fov.right), tan(fov.up), tan(fov.down))
        if let desktop {
            let t = desktopTanHalfWidth, v = t * Float(desktop.height) / Float(desktop.width)
            tangents = SIMD4(-t, t, v, -v)
        }
        let submittedEye = projection?.eyeViews?.view(eye == .left ? 0 : 1)
        let submittedOther = desktop != nil ? projection?.eyeViews?.right : nil
        let projectionOrigin = desktop != nil ? head.position : eyePos
        return SceneUniforms(
            tanLRUD: tangents,
            eyePosition: SIMD4(eyePos, 1),
            rotation: rotation,
            params: SIMD4(Float(layerCount), Float(desktop?.width ?? eyeTexture.height), Float(CACurrentMediaTime() - startTime), shownDimming),
            cursor: cursorDirection.map { SIMD4($0, 1) } ?? .zero,
            highlight: SIMD4(Float(highlight ?? -1), sceneBrightness, 0, 0),
            projFromWorld: submittedEye.map { simd_float4x4($0.orientation.inverse) }
                ?? projection.map { simd_float4x4($0.renderOrientation.inverse) } ?? matrix_identity_float4x4,
            projUV: projection?.uvRect ?? .zero,
            projTan: projection.map { eye == .left ? $0.renderedTangents.left : $0.renderedTangents.right } ?? .zero,
            projFlags: SIMD4(projection == nil ? 0 : 1, eye == .left ? 0 : 1, scene3D == nil ? 0 : 1, gameLayers == nil && gameAway == 0 ? 0 : 1),
            videoFromWorld: sphere.map { simd_float4x4($0.orientation.inverse) } ?? matrix_identity_float4x4,
            videoParams: sphere.map { SIMD4(Float($0.projection + 1), Float($0.stereo), $0.fisheyeFovDeg * .pi / 180, $0.zoom) } ?? .zero,
            videoTilt: sphere.map { simd_float4x4($0.tilt) } ?? matrix_identity_float4x4,
            videoView: videoUnderInterface && (videoSphere?.stereo ?? 0) != 0 ? SIMD4(1, 0.7, 0, 0) : SIMD4(0, 1, 0, 0),
            videoKey: sphere?.key ?? .zero,
            videoKeyFit: sphere?.keyFit ?? .zero,
            saberStart: saber.map { SIMD4($0.start, $0.hidesRing ? 2 : 1) } ?? .zero,
            saberEnd: saber.map { SIMD4($0.end, $0.landsOnSurface ? 1 : 0) } ?? .zero,
            saberParams: SIMD4(saberEnergy, saberPress, saber?.fromHand == false ? 1 : 0, environmentFade),
            envParams: SIMD4(showReferenceBoxes ? 1 : 0, recenterProgress,
                             Float(environment == 4 && environmentTexture == nil ? 0 : environment), environmentYaw),
            projShift: submittedEye.map { SIMD4(projectionOrigin - $0.position, Self.reprojectionDepth) }
                ?? projection.map { SIMD4(head.position - $0.renderPosition, Self.reprojectionDepth) } ?? .zero,
            projTanOther: desktop != nil ? (projection?.renderedTangents.right ?? .zero) : .zero,
            gameFade: gameFade, gameBackgroundFade: gameBackgroundFade,
            gameAway: SIMD4(gameAway, projection?.seeThrough == true || projection?.composition != nil ? 1 : 0,
                Float(projection?.colourSpaces.x ?? 0), Float(projection?.colourSpaces.y ?? 0)),
            seeFromWorld: simd_float4x4(SIMD4(seeFromWorld.columns.0, 0), SIMD4(seeFromWorld.columns.1, 0),
                                        SIMD4(seeFromWorld.columns.2, 0), SIMD4(0, 0, 0, 1)),
            seeParams: SIMD4(cameraPicture == nil ? 0 : seeThrough, Self.cameraFocal,
                             eye == .left ? Self.cameraCentre.left : Self.cameraCentre.right, Self.cameraCentre.y),
            seeFishLeft: Self.fisheyeMatrix(0), seeFishRight: Self.fisheyeMatrix(1),
            seeFish: SIMD4(cameraFisheyes && Self.fisheyes.count > 1 ? 1 : 0, Self.fisheyes.first?.k2 ?? 0, Self.fisheyes.dropFirst().first?.k2 ?? 0, 0),
            projFromWorldOther: submittedOther.map { simd_float4x4($0.orientation.inverse) } ?? matrix_identity_float4x4,
            projShiftOther: submittedOther.map { SIMD4(projectionOrigin - $0.position, Self.reprojectionDepth) } ?? SIMD4(0, 0, 0, -1))
    }

    // --- Passthrough (ROADMAP W11 E.4) ---

    /// How much of the room shows behind the panels (0: none; eased by the app).
    var seeThrough: Float = 0
    /// The bottom cameras' frame (x right, y down, z forward) at the picture's exposure, from world.
    var seeFromWorld = matrix_identity_float3x3
    /// The headset's passthrough cameras (its adapter's numbers: HeadsetAdapter.swift); none
    /// for a headset without them (passthrough is then never on).
    private static var cameras: PassthroughCameras {
        Headsets.current.cameras ?? PassthroughCameras(focal: 1, centre: (0, 0, 0), pitch: 0, fisheyes: [])
    }
    /// The rectified pair: focal length and centres in pixels of its picture.
    static var cameraFocal: Float { cameras.focal }
    static var cameraCentre: (left: Float, right: Float, y: Float) { cameras.centre }
    /// The cameras look this far below the head's forward (radians).
    static var cameraPitch: Float { cameras.pitch }
    private var cameraPictures: [MTLTexture] = []
    private var cameraPicture: MTLTexture?
    /// The picture is camera mode 0x10's: the two raw fisheyes, one above the other.
    private var cameraFisheyes = false

    /// The cameras' raw fisheyes (the wider mode), from the adapter.
    static var fisheyes: [(rows: [SIMD3<Float>], lens: SIMD4<Float>, k2: Float)] { cameras.fisheyes }
    /// A fisheye as the shader takes it: the turn in the upper 3 × 3, the lens in column 3.
    private static func fisheyeMatrix(_ i: Int) -> simd_float4x4 {
        guard fisheyes.indices.contains(i) else { return matrix_identity_float4x4 }
        let m = simd_float3x3(rows: fisheyes[i].rows)
        return simd_float4x4(SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0), fisheyes[i].lens)
    }

    /// The newest picture of the bottom pair (8 bits a pixel, left camera then right; or, `bc4`,
    /// mode 0x10's two raw fisheyes one above the other, as BC4 blocks, which the GPU reads as
    /// they are), or nil when passthrough goes off: the textures are dropped with it. Two
    /// textures in turn, so a frame being drawn never reads one that is being written.
    func setCameraPicture(_ pixels: UnsafeRawPointer?, width: Int, height: Int, bc4: Bool = false) {
        guard let pixels, width > 0, height > 0 else {
            cameraPictures = []
            cameraPicture = nil
            return
        }
        let format: MTLPixelFormat = bc4 ? .bc4_rUnorm : .r8Unorm
        if cameraPictures.first.map({ $0.width != width || $0.height != height || $0.pixelFormat != format }) ?? true {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            cameraPictures = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
            cameraPicture = nil
        }
        guard cameraPictures.count == 2 else { return }
        let next = cameraPicture === cameraPictures[0] ? cameraPictures[1] : cameraPictures[0]
        // A BC4 row of blocks is 8 bytes for every 4 pixels across.
        next.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bc4 ? width / 4 * 8 : width)
        cameraPicture = next
        cameraFisheyes = bc4
    }

    /// Renders one frame for `head` into `drawable` and presents it.
    func render(head: HeadPose, calibration: [Float], to drawable: CAMetalDrawable) {
        render(head: head, calibration: calibration, into: drawable.texture, present: drawable)
    }

    /// Renders one frame into `target` (bgra8Unorm); presents `drawable` if given, otherwise waits
    /// for the GPU to finish (for snapshots).
    func render(head: HeadPose, calibration: [Float], into target: MTLTexture, present drawable: CAMetalDrawable?) {
        let cpuStart = CACurrentMediaTime()
        guard let cb = queue.makeCommandBuffer() else { return }
        let (sceneTexture, desktop) = drawScene(head: head, calibration: calibration, cb: cb, output: (target.width, target.height))

        // 2. Distortion into the output.
        let lens = Lens(queue: queue, pipeline: distortPipeline, passthrough: passthroughPipeline, sampler: sampler,
                        meshes: desktop == nil && distortionEnabled && meshes.count == 2 ? meshes : nil)
        lens.encode(into: cb, target: target, scene: sceneTexture, warp: LateLatch.noTurn)
        let stats = self.stats
        let done = gpuDone
        gpuDone = nil
        cb.addCompletedHandler { cb in
            if cb.gpuEndTime > cb.gpuStartTime { stats.gpu(cb.gpuEndTime - cb.gpuStartTime) }
            done?(cb.gpuEndTime)
        }
        if let drawable { cb.present(drawable) }
        cb.commit()
        if drawable == nil { cb.waitUntilCompleted() }
        stats.cpu(CACurrentMediaTime() - cpuStart)
    }

    /// The scene (both eyes, or the desktop view) into its texture, encoded into `cb`.
    private func drawScene(head: HeadPose, calibration: [Float], cb: MTLCommandBuffer, output target: (width: Int, height: Int))
        -> (MTLTexture, (width: Int, height: Int)?) {
        updateMeshes(calibration: calibration)
        for hook in beforeFrame { hook(cb) }
        // Runs on the same GPU queue before reprojection and lens correction;
        // a repeated game frame reuses its already processed texture.
        let sourceProjection = projection
        if let sourceProjection {
            if let composition = sourceProjection.composition, composition.projectionIndex == nil {
                // Quad-only carriers must not seed optical flow or upscale submitted UI.
                resetSpacewarp()
            } else {
                projection = gameProjection(spacewarpProjection(sourceProjection, cb: cb), cb: cb)
            }
        } else { resetSpacewarp() }
        defer { projection = sourceProjection }
        // scene_fs never reads the place or its geometry while a projection or
        // surrounding video is active (its `surround` branch, including glass).
        // Keep the bake/cache clock intact; a visible place resumes normally.
        let surroundingsVisible = projection == nil && videoSphere == nil
        if surroundingsVisible { bakeEnvironment(cb) }
        // Eased values (design board 9, "quick": 120 ms): the hover glow of the highlighted layer,
        // the cross-fade of panels whose texture changed, the saber between its states.
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, max(0, now - lastFrameTime)))
        lastFrameTime = now
        let quick = 1 - exp(-dt / 0.045)
        let step = dt / Float(Motion.standard)
        let shownLayers = gameAway > 0 ? layers : (gameLayers ?? layers)
        let highlighted = gameLayers == nil || gameAway > 0 ? highlightedLayer : nil
        for (i, layer) in shownLayers.enumerated() {
            layer.presence = layer.shown ? min(1, layer.presence + step) : max(0, layer.presence - step)
            layer.hoverAmount += ((i == highlighted ? 1 : 0) - layer.hoverAmount) * quick
            if layer.previousTexture != nil {
                layer.fade = min(1, layer.fade + dt / 0.12)
                if layer.fade >= 1 { layer.previousTexture = nil }
            }
        }
        let energy: Float = saber.map { $0.mode == .pressed ? 1 : ($0.mode == .overTarget ? 0.85 : 0.6) } ?? 0
        saberEnergy += (energy - saberEnergy) * quick
        saberPress += ((saber?.mode == .pressed ? 1 : 0) - saberPress) * (1 - exp(-dt / 0.03))
        // A change of place: the old one dips to black, the new one comes up.
        if let next = pendingEnvironment {
            if environmentFade < 0.03 || !hasRendered {
                environment = next.index
                environmentTexture = next.texture
                scene3D = next.scene
                pendingEnvironment = nil
            }
        }
        hasRendered = true
        let sceneKey = "\(projection != nil)|\(sphere != nil)"
        if sceneKey != lastSceneKey {
            if !lastSceneKey.isEmpty { sceneFadeStart = now }
            lastSceneKey = sceneKey
        }
        let x = Float((now - sceneFadeStart) / 0.4)
        sceneBrightness = x >= 1 ? 1 : max(0, x) * max(0, x) * (3 - 2 * max(0, x))
        environmentFade += ((pendingEnvironment == nil ? 1 : 0) - environmentFade) * (1 - exp(-dt / 0.09))
        // Dimming (theater mode, the setting) eases too.
        let dimming = max(environmentDimming, baseDimming)
        shownDimming = abs(dimming - shownDimming) < 0.002 ? dimming : shownDimming + (dimming - shownDimming) * (1 - exp(-dt / 0.12))

        // 1. Scene, per eye, into the side-by-side eye texture (desktop view: one view, output size).
        var sceneTexture = eyeTexture
        if desktopView {
            if desktopTexture?.width != target.width || desktopTexture?.height != target.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: target.width, height: target.height, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                desktopTexture = device.makeTexture(descriptor: d)
            }
            if let t = desktopTexture { sceneTexture = t }
        }
        let desktop = desktopView && sceneTexture !== eyeTexture ? (width: sceneTexture.width, height: sceneTexture.height) : nil
        // 1a. The 3D place's geometry, per eye, into color and distance targets the scene pass reads.
        if surroundingsVisible, let scene = scene3D { drawGeometry(scene, cb: cb, head: head, target: sceneTexture, desktop: desktop) }
        let sp = MTLRenderPassDescriptor()
        sp.colorAttachments[0].texture = sceneTexture
        sp.colorAttachments[0].loadAction = .dontCare
        sp.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: sp) {
            enc.setRenderPipelineState(scenePipeline)
            enc.setFragmentSamplerState(sampler, index: 0)
            // Far to near, so see-through layers (Night Glass panels) blend over what is behind them.
            let drawn = Array(shownLayers.prefix(maxLayers))
            let depth = drawn.map { simd_distance($0.rendered.position, head.position) - $0.sortBias }
            let order = drawn.indices.sorted { drawn[$0].tier != drawn[$1].tier ? drawn[$0].tier < drawn[$1].tier : depth[$0] > depth[$1] }
            var layerData = order.map { drawn[$0].data }
            if layerData.isEmpty { layerData = [LayerData(layerFromWorld: matrix_identity_float4x4, size: .zero, uvRect: .zero, stereo: .zero, shape: .zero, glass: .zero, glass2: .zero, patch: .zero)] }
            enc.setFragmentBytes(&layerData, length: layerData.count * MemoryLayout<LayerData>.stride, index: 1)
            let textures: [MTLTexture?] = (0..<maxLayers).map { $0 < order.count ? drawn[order[$0]].texture : placeholder }
            let previous: [MTLTexture?] = (0..<maxLayers).map { $0 < order.count ? (drawn[order[$0]].previousTexture ?? placeholder) : placeholder }
            enc.setFragmentTextures(previous, range: (maxLayers + 3)..<(2 * maxLayers + 3))
            let highlight = highlighted.flatMap { h in order.firstIndex(of: h) }
            enc.setFragmentTextures(textures, range: 0..<maxLayers)
            enc.setFragmentTexture(projection?.texture ?? placeholder, index: maxLayers)
            enc.setFragmentTexture(sphere?.texture ?? placeholder, index: maxLayers + 1)
            enc.setFragmentTexture((Self.isBaked(environment) ? bakedEnvironment : environmentTexture) ?? placeholder, index: maxLayers + 2)
            enc.setFragmentTexture(scene3D != nil ? meshTargets?.color ?? placeholder : placeholder, index: 2 * maxLayers + 3)
            enc.setFragmentTexture(scene3D != nil ? meshTargets?.distance ?? placeholder : placeholder, index: 2 * maxLayers + 4)
            enc.setFragmentTexture(cameraPicture ?? placeholder, index: 2 * maxLayers + 5)
            enc.setFragmentTexture(projection?.srgbTexture ?? projection?.texture ?? placeholder, index: 2 * maxLayers + 6)
            OpenXRComposition.bind(projection?.composition, to: enc, headPosition: head.position,
                                   headOrientation: head.orientation, placeholder: placeholder)
            let size = Double(eyeTexture.height)
            var lights = Self.fireflies(time: Float(CACurrentMediaTime() - startTime))
            enc.setFragmentBytes(&lights, length: lights.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
            for eye in desktop != nil ? [Eye.left] : [Eye.left, .right] {
                if let desktop {
                    enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(desktop.width), height: Double(desktop.height), znear: 0, zfar: 1))
                } else {
                    enc.setViewport(MTLViewport(originX: eye == .left ? 0 : size, originY: 0, width: size, height: size, znear: 0, zfar: 1))
                }
                var u = uniforms(eye: eye, head: head, layerCount: order.count, highlight: highlight, desktop: desktop)
                enc.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }

        return (sceneTexture, desktop)
    }

    // --- Late latching (LateLatch.swift) ---

    /// Set by the headset's view while the head comes from the headset: the tracker's orientation
    /// for a host time in ns, callable from any thread.
    var latePose: (@Sendable (Int64) -> (orientation: simd_quatf, turning: SIMD3<Float>)?)?
    /// The host time (ns) the frame being drawn is seen at: what the late pose is asked for.
    var lateTargetNs: Int64 = 0
    private lazy var lateLatch = LateLatch()
    /// The other eye texture: a latched frame's scene is drawn into one while the lens thread may
    /// still have the frame before in the other.
    private var spareEyeTexture: MTLTexture?
    /// Frames whose scene was committed and whose lens pass has not finished yet.
    private let lensPending = LensPending()
    private let lensQueue = DispatchQueue(label: "halliday.lens", qos: .userInteractive)
    /// The display's refresh period, seconds (the headset's view sets it).
    var refreshPeriod: Double {
        get { displayPhase.period }
        set { displayPhase.period = newValue }
    }
    private let displayPhase = DisplayPhase()

    /// When frames reach the display against when their lens pass was committed, and at what
    /// phase of the refresh it was committed (logged every 600 frames). Measured on the headset
    /// (frames sent straight to the display, the Metal HUD says "Direct"): a frame is
    /// shown two refreshes after the refresh before its commit, 12 to 14 ms after it, whether it
    /// was committed 3 or 5 ms into a refresh; holding the lens pass later (up to 7 ms) gained at
    /// most 2 ms and lost frames now and then. That is the floor of this display path.
    private final class DisplayPhase: @unchecked Sendable {
        private let lock = NSLock()
        var period = 1.0 / 120
        private var frames = 0, waited = 0.0, phase = 0.0
        func shown(at time: Double, committed: Double) {
            lock.lock(); defer { lock.unlock() }
            frames += 1
            waited += time - committed
            var p = (committed - time).truncatingRemainder(dividingBy: period)
            if p < 0 { p += period }
            phase += p
            if frames == 600 {
                log(String(format: "[display] 600 frames shown %.2f ms after their lens pass, committed %.2f ms after a refresh",
                           waited / 600 * 1000, phase / 600 * 1000))
                frames = 0; waited = 0; phase = 0
            }
        }
    }

    /// The lens pass's own GPU queue: on the scene's, it waited behind the next frame's scene
    /// (6 ms) and missed its refresh.
    private lazy var lensCommandQueue: MTLCommandQueue? = device.makeCommandQueue()

    /// True when a frame can be drawn the latched way: the headset's two warped eyes, with a late
    /// pose to be had.
    var canLatch: Bool { LateLatch.enabled && latePose != nil && !desktopView && distortionEnabled && meshes.count == 2 }

    /// One frame for the headset in two parts (LateLatch.swift): the scene now, with `head`; then,
    /// on the lens queue once the GPU has drawn it, a drawable from `layer`, the orientation for
    /// the same moment asked for again, and the lens pass turned by the difference. The main
    /// thread never waits for a drawable (it waited up to 9 ms a frame, and frames were lost).
    /// `presenting` is handed the drawable before it is presented. False when the frame is left
    /// out: the lens pass of the frame before last hasn't finished yet (the display is behind;
    /// leaving one out lets its queue drain).
    @discardableResult
    func renderLatched(head: HeadPose, calibration: [Float], layer: CAMetalLayer,
                       presenting: (@Sendable (CAMetalDrawable) -> Void)? = nil) -> Bool {
        guard let pose = latePose, lensPending.begin() else { return false }
        let cpuStart = CACurrentMediaTime()
        guard let cb = queue.makeCommandBuffer() else { lensPending.end(); return false }
        if spareEyeTexture == nil { spareEyeTexture = try? Renderer.makeEyeTexture(device: device, eyeSize: eyeTexture.height) }
        if let spare = spareEyeTexture { spareEyeTexture = eyeTexture; eyeTexture = spare }
        let size = CGSize(width: layer.drawableSize.width, height: layer.drawableSize.height)
        let (sceneTexture, _) = drawScene(head: head, calibration: calibration, cb: cb, output: (Int(size.width), Int(size.height)))
        let lens = Lens(queue: lensCommandQueue ?? queue, pipeline: distortPipeline, passthrough: passthroughPipeline, sampler: sampler, meshes: meshes)
        // Used on the lens queue: a layer's nextDrawable may be called from any thread, and the
        // scene texture is only read there.
        let shared = LensFrame(layer: layer, scene: sceneTexture)
        let latch = lateLatch, pending = lensPending, stats = self.stats, lensQueue = self.lensQueue, phase = displayPhase
        let rendered = head.orientation, target = lateTargetNs, started = Int64(cpuStart * 1e9)
        let done = gpuDone
        gpuDone = nil
        cb.addCompletedHandler { cb in
            let sceneEnd = cb.gpuEndTime, sceneTime = cb.gpuEndTime > cb.gpuStartTime ? cb.gpuEndTime - cb.gpuStartTime : 0
            lensQueue.async {
                let asked = CACurrentMediaTime()
                guard let drawable = shared.layer.nextDrawable(), let lensCB = lens.queue.makeCommandBuffer() else {
                    pending.end()
                    return
                }
                let warp = latch.latch(rendered: rendered, startedNs: started, targetNs: target, sceneEnd: sceneEnd,
                                       drawableWait: CACurrentMediaTime() - asked, pose: pose)
                lens.encode(into: lensCB, target: drawable.texture, scene: shared.scene, warp: warp)
                lensCB.addCompletedHandler { cb in
                    // Its eye texture may be drawn into again (two queues: nothing else orders them).
                    pending.end()
                    if cb.gpuEndTime > cb.gpuStartTime { stats.gpu(cb.gpuEndTime - cb.gpuStartTime + sceneTime) }
                    done?(cb.gpuEndTime)
                }
                presenting?(drawable)
                let committed = CACurrentMediaTime()
                drawable.addPresentedHandler { d in
                    if d.presentedTime > 0 { phase.shown(at: d.presentedTime, committed: committed) }
                }
                lensCB.present(drawable)
                lensCB.commit()
            }
        }
        cb.commit()
        stats.cpu(CACurrentMediaTime() - cpuStart)
        return true
    }

    private struct LensFrame: @unchecked Sendable {
        let layer: CAMetalLayer
        let scene: MTLTexture
    }

    /// At most two frames between their scene's commit and their lens pass's end: the two eye
    /// textures.
    private final class LensPending: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard count < 2 else { return false }
            count += 1
            return true
        }
        func end() { lock.lock(); count -= 1; lock.unlock() }
        func snapshotCount() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// The lens pass: what it needs, so it can be encoded on any thread.
    struct Lens: @unchecked Sendable {
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let passthrough: MTLRenderPipelineState
        let sampler: MTLSamplerState
        /// Each eye's distortion mesh; nil: the scene texture stretched over the output.
        let meshes: [(vertices: MTLBuffer, indices: MTLBuffer, count: Int)]?

        func encode(into cb: MTLCommandBuffer, target: MTLTexture, scene: MTLTexture, warp: LensWarp) {
            let dp = MTLRenderPassDescriptor()
            dp.colorAttachments[0].texture = target
            dp.colorAttachments[0].loadAction = .clear
            dp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            dp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: dp) else { return }
            enc.setFragmentTexture(scene, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            if let meshes {
                enc.setRenderPipelineState(pipeline)
                var w = warp
                enc.setVertexBytes(&w, length: MemoryLayout<LensWarp>.stride, index: 2)
                for (i, mesh) in meshes.enumerated() {
                    var eye = Float(i)
                    enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
                    enc.setVertexBytes(&eye, length: 4, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
                }
            } else {
                enc.setRenderPipelineState(passthrough)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }
    }

    /// Must match `MeshUniforms` in Shaders.swift.
    private struct MeshUniforms {
        var viewProjection: simd_float4x4
        var model: simd_float4x4
        var eye: SIMD4<Float>
        var baseColor: SIMD4<Float>
        var emission: SIMD4<Float>
    }

    /// Draws a 3D place for each eye (or the desktop view) into the geometry targets, sized as the
    /// scene's target, with the same views the scene pass casts its rays through.
    private func drawGeometry(_ scene: Scene3D, cb: MTLCommandBuffer, head: HeadPose, target: MTLTexture, desktop: (width: Int, height: Int)?) {
        if meshTargets?.color.width != target.width || meshTargets?.color.height != target.height {
            func make(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: target.width, height: target.height, mipmapped: false)
                d.usage = usage
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            guard let c = make(.rgba16Float, [.renderTarget, .shaderRead]), let dist = make(.r32Float, [.renderTarget, .shaderRead]),
                  let depth = make(.depth32Float, [.renderTarget]) else { return }
            meshTargets = (c, dist, depth)
        }
        guard let t = meshTargets else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t.color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = t.distance
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) // 0: nothing here
        pass.colorAttachments[1].storeAction = .store
        pass.depthAttachment.texture = t.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        environmentGeometryPasses &+= 1
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(meshDepthState)
        enc.setFragmentSamplerState(sampler, index: 0)
        let size = Double(eyeTexture.height)
        for eye in desktop != nil ? [Eye.left] : [Eye.left, .right] {
            if let desktop {
                enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(desktop.width), height: Double(desktop.height), znear: 0, zfar: 1))
            } else {
                enc.setViewport(MTLViewport(originX: eye == .left ? 0 : size, originY: 0, width: size, height: size, znear: 0, zfar: 1))
            }
            // The same view as the scene pass: its tangents, eye position and head rotation.
            let su = uniforms(eye: eye, head: head, layerCount: 0, highlight: nil, desktop: desktop)
            let (l, r, up, down) = (su.tanLRUD.x, su.tanLRUD.y, su.tanLRUD.z, su.tanLRUD.w)
            let near: Float = 0.05, far: Float = 1000
            let projection = simd_float4x4(columns: (SIMD4(2 / (r - l), 0, 0, 0), SIMD4(0, 2 / (up - down), 0, 0),
                                                     SIMD4((r + l) / (r - l), (up + down) / (up - down), far / (near - far), -1),
                                                     SIMD4(0, 0, near * far / (near - far), 0)))
            let eyeFromWorld = (simd_float4x4(translation: SIMD3(su.eyePosition.x, su.eyePosition.y, su.eyePosition.z)) * su.rotation).inverse
            let viewProjection = projection * eyeFromWorld
            for part in scene.parts {
                var mu = MeshUniforms(viewProjection: viewProjection, model: part.transform, eye: su.eyePosition,
                                      baseColor: part.baseColor, emission: SIMD4(part.emission, part.texture == nil ? 0 : 1))
                enc.setVertexBuffer(part.vertices, offset: part.vertexOffset, index: 0)
                enc.setVertexBytes(&mu, length: MemoryLayout<MeshUniforms>.stride, index: 1)
                enc.setFragmentBytes(&mu, length: MemoryLayout<MeshUniforms>.stride, index: 1)
                enc.setFragmentTexture(part.texture ?? placeholder, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: part.indexType,
                                          indexBuffer: part.indices, indexBufferOffset: part.indexOffset)
            }
        }
        enc.endEncoding()
    }

    /// Puts an RGBA8 image (top-left origin) into `texture`, or into a new mipmapped texture if there
    /// is none of that size yet. The copy and the mipmaps run on the GPU queue without waiting, so this
    /// is cheap enough to call while frames are being drawn.
    func updateLayerTexture(_ texture: MTLTexture?, width: Int, height: Int, bytes: UnsafeMutableRawPointer) -> MTLTexture? {
        updateLayerTexture(texture, width: width, height: height, bytes: UnsafeRawPointer(bytes))
    }

    func updateLayerTexture(_ texture: MTLTexture?, width: Int, height: Int, bytes: UnsafeRawPointer) -> MTLTexture? {
        var t = texture
        if t == nil || t?.width != width || t?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
            d.usage = [.shaderRead]
            t = device.makeTexture(descriptor: d)
        }
        guard let t else { return nil }
        // The picture goes in through the queue, not `replace`: a CPU write landed at once, while a
        // frame in flight was still reading the texture and before its mipmaps were rebuilt, so a
        // panel redrawn on hover flickered for a frame or two on the headset.
        // Queued, the copy and the mipmaps come after the frames already committed
        // and before the next one.
        guard let staging = device.makeBuffer(bytes: bytes, length: width * height * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: width * 4, sourceBytesPerImage: width * height * 4,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: t, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: t)
        blit.endEncoding()
        cb.commit()
        return t
    }

    /// The same for a part of the picture (pixels, rows from the top; `bytes` is the whole picture,
    /// `width` across): `texture` first takes `base`'s picture when given (a fade's other texture
    /// holds an older one), then the part. False when it couldn't be queued.
    func updateLayerTexture(_ texture: MTLTexture, from base: MTLTexture?, width: Int, bytes: UnsafeRawPointer,
                            part: (x: Int, y: Int, w: Int, h: Int)) -> Bool {
        guard let staging = device.makeBuffer(bytes: bytes + part.y * width * 4, length: part.h * width * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return false }
        if let base {
            blit.copy(from: base, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.copy(from: staging, sourceOffset: part.x * 4, sourceBytesPerRow: width * 4, sourceBytesPerImage: part.h * width * 4,
                  sourceSize: MTLSize(width: part.w, height: part.h, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: part.x, y: part.y, z: 0))
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        cb.commit()
        return true
    }

    /// Uploads an RGBA8 image (top-left origin) as a mipmapped texture for a layer.
    func makeLayerTexture(width: Int, height: Int, rgba: [UInt8]) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        rgba.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return t
    }
}

enum RendererError: Error { case metal(String) }

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
}
