// State shared between the main thread (rendering) and the input thread (MouseOwner's event tap).
//
// The input thread must never wait for the main thread: while Halliday owns the mouse, every
// mouse and keyboard event on the Mac passes through it. So the main thread publishes a snapshot
// each frame (head pose, where the VR windows are) and the input thread does plain math on it.

import CoreGraphics
import Foundation
import QuartzCore
import simd

/// Where a VR window is, in the world and on the Mac's displays.
struct WindowSnapshot: @unchecked Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    /// Real window frame in global display coordinates (points, origin top-left).
    let frame: CGRect
    let position: SIMD3<Float>
    let orientation: simd_quatf
    let width: Float
    let height: Float
    /// A menu, popover, tooltip or dialog shown in front of its parent window.
    let isPopup: Bool
    /// A part of the window that must not be clicked in VR (its full-screen button), relative to
    /// the window's top-left corner.
    var blocked: CGRect?
}

/// The surface of one of Halliday's panels, as published to the input thread.
struct PanelSnapshot: @unchecked Sendable {
    let position: SIMD3<Float>
    let orientation: simd_quatf
    let width: Float
    let height: Float

    func distance(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        let inv = orientation.inverse
        let o = inv.act(origin - position), d = inv.act(direction)
        guard abs(d.z) > 1e-6 else { return nil }
        let t = -o.z / d.z
        guard t > 0 else { return nil }
        let p = o + t * d
        return abs(p.x) <= width / 2 && abs(p.y) <= height / 2 ? t : nil
    }
}

/// The window under the pointer and the matching point on the real window.
struct PointerHit: @unchecked Sendable {
    let window: WindowSnapshot
    let screenPoint: CGPoint
    let distance: Float
}

final class InputState: @unchecked Sendable {
    static let shared = InputState()

    private let lock = NSLock()
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var headPosition = SIMD3<Float>(0, 1.65, 1)
    private var headOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var windows: [WindowSnapshot] = []
    /// Halliday's own panels in front of the windows: a pointer on one of them is not on the window
    /// behind it.
    private var blockers: [PanelSnapshot] = []
    private var lastFrame: CFTimeInterval = CACurrentMediaTime()

    /// Radians of pointer movement per point of mouse movement (the pointer speed setting).
    private var sensitivity: Float = 0.0025

    func setPointerSpeed(_ speed: Float) {
        lock.lock(); defer { lock.unlock() }
        sensitivity = 0.0025 * speed
    }

    /// When the mouse last moved the pointer (a Sense controller yields to it for a moment).
    private var lastNudge: CFTimeInterval = 0
    var sinceMouseMoved: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - lastNudge
    }

    /// Points the pointer (a Sense controller's aim, relative to the head). It may leave the view.
    func point(yaw newYaw: Float, pitch newPitch: Float) {
        lock.lock(); defer { lock.unlock() }
        yaw = max(-1.5, min(1.5, newYaw))
        pitch = max(-1.3, min(1.3, newPitch))
    }

    /// Moves the pointer by mouse deltas (points).
    func nudge(dx: Double, dy: Double) {
        lock.lock(); defer { lock.unlock() }
        if dx != 0 || dy != 0 { lastNudge = CACurrentMediaTime() }
        // Back into the mouse's range if a controller had it further out.
        yaw = max(-0.8, min(0.8, yaw)); pitch = max(-0.7, min(0.7, pitch))
        yaw = max(-0.8, min(0.8, yaw - Float(dx) * sensitivity))
        pitch = max(-0.7, min(0.7, pitch - Float(dy) * sensitivity))
    }

    /// Pointer direction in the head's frame.
    var pointerDirection: SIMD3<Float> {
        lock.lock(); defer { lock.unlock() }
        return Self.direction(yaw: yaw, pitch: pitch)
    }

    /// Puts the pointer back in the middle of the view.
    func centerPointer() {
        lock.lock(); defer { lock.unlock() }
        yaw = 0
        pitch = 0
    }

    /// Pointer rotation relative to the head (yaw, then pitch).
    var pointerRotation: simd_quatf {
        lock.lock(); defer { lock.unlock() }
        return simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    }

    /// Called by the main thread once per frame.
    func publish(headPosition: SIMD3<Float>, headOrientation: simd_quatf, windows: [WindowSnapshot], blockers: [PanelSnapshot] = []) {
        lock.lock(); defer { lock.unlock() }
        self.headPosition = headPosition
        self.headOrientation = headOrientation
        self.windows = windows
        self.blockers = blockers
        lastFrame = CACurrentMediaTime()
    }

    /// Seconds since the main thread last published a frame.
    var mainThreadSilence: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - lastFrame
    }

    /// The window under the pointer, if any.
    func hit() -> PointerHit? {
        lock.lock()
        let origin = headPosition
        let direction = headOrientation.act(Self.direction(yaw: yaw, pitch: pitch))
        let windows = self.windows
        let blockers = self.blockers
        lock.unlock()
        guard let hit = Self.hit(origin: origin, direction: direction, windows: windows) else { return nil }
        for b in blockers {
            if let t = b.distance(origin: origin, direction: direction), t < hit.distance { return nil }
        }
        return hit
    }

    /// True if the pointer is on one of Halliday's own panels.
    func isOnPanel() -> Bool {
        lock.lock()
        let origin = headPosition
        let direction = headOrientation.act(Self.direction(yaw: yaw, pitch: pitch))
        let blockers = self.blockers
        lock.unlock()
        return blockers.contains { $0.distance(origin: origin, direction: direction) != nil }
    }

    /// Aims the pointer along `direction` (in the head's frame), e.g. at the spot that was clicked.
    func aim(_ direction: SIMD3<Float>) {
        let d = simd_normalize(direction)
        lock.lock(); defer { lock.unlock() }
        yaw = max(-0.85, min(0.85, atan2(-d.x, -d.z)))
        pitch = max(-0.75, min(0.75, asin(max(-1, min(1, d.y)))))
    }

    /// The window `windowID` as currently published.
    func window(_ windowID: CGWindowID) -> WindowSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return windows.first { $0.windowID == windowID }
    }

    private static func direction(yaw: Float, pitch: Float) -> SIMD3<Float> {
        simd_quatf(angle: yaw, axis: [0, 1, 0]).act(simd_quatf(angle: pitch, axis: [1, 0, 0]).act([0, 0, -1]))
    }

    /// Nearest window rectangle hit by a ray; pure math.
    static func hit(origin: SIMD3<Float>, direction: SIMD3<Float>, windows: [WindowSnapshot]) -> PointerHit? {
        var best: PointerHit?
        for w in windows {
            let inv = w.orientation.inverse
            let o = inv.act(origin - w.position), d = inv.act(direction)
            guard abs(d.z) > 1e-6 else { continue }
            let t = -o.z / d.z
            guard t > 0, t < (best?.distance ?? .infinity) else { continue }
            let p = o + t * d
            guard abs(p.x) <= w.width / 2, abs(p.y) <= w.height / 2 else { continue }
            let u = CGFloat(p.x / w.width + 0.5), v = CGFloat(0.5 - p.y / w.height)
            let point = CGPoint(x: w.frame.minX + u * w.frame.width, y: w.frame.minY + v * w.frame.height)
            best = PointerHit(window: w, screenPoint: point, distance: t)
        }
        return best
    }
}
