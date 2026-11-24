// Where head poses come from: the mouse (simulator), a replayed recording, or the headset.

import Foundation
import QuartzCore
import simd

@MainActor
protocol PoseSource: AnyObject {
    var name: String { get }
    /// Head pose for a host time in ns, or nil without tracking.
    func pose(atHostNs t: Int64) -> HeadPose?
    func recenter()
    /// Lens calibration to use with this source.
    var calibration: [Float] { get }
    /// One-line state for the status display.
    var state: String { get }
}

/// Simulator: drag to look around, W/A/S/D to walk, Q/E down/up.
@MainActor
final class MouseLook: PoseSource {
    let name = "mouse"
    var yaw: Float = 0
    var pitch: Float = 0
    var position = SIMD3<Float>(0, 1.65, 1.0)
    var moveKeys: Set<Character> = []
    private var lastStep = CACurrentMediaTime()

    func look(dx: Float, dy: Float) {
        yaw -= dx * 0.004
        pitch = max(-1.5, min(1.5, pitch - dy * 0.004))
    }

    var orientation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    }

    func pose(atHostNs t: Int64) -> HeadPose? {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastStep, 0.1))
        lastStep = now
        var move = SIMD3<Float>(0, 0, 0)
        if moveKeys.contains("w") { move.z -= 1 }
        if moveKeys.contains("s") { move.z += 1 }
        if moveKeys.contains("a") { move.x -= 1 }
        if moveKeys.contains("d") { move.x += 1 }
        if moveKeys.contains("e") { move.y += 1 }
        if moveKeys.contains("q") { move.y -= 1 }
        var velocity = SIMD3<Float>.zero
        if move != .zero {
            let heading = simd_quatf(angle: yaw, axis: [0, 1, 0])
            velocity = heading.act(simd_normalize(move)) * 1.5
            position += velocity * dt
        }
        return HeadPose(position: position, orientation: orientation, angularVelocity: .zero, slamAgeNs: 0,
                        predicted: false, linearVelocity: velocity, motionFlags: 1)
    }

    func recenter() {
        yaw = 0; pitch = 0
        position = SIMD3(0, 1.65, 1.0)
    }

    let calibration: [Float] = [-0.09919293, 0, 0.09919293, 0, 1, 0, 1, 0]
    var state: String {
        let deg = (yaw * 180 / .pi).truncatingRemainder(dividingBy: 360)
        let wrapped = deg > 180 ? deg - 360 : (deg < -180 ? deg + 360 : deg)
        return String(format: "yaw %.0f° pitch %.0f°", wrapped, pitch * 180 / .pi)
    }
}

/// A real headset over USB, or a replayed recording, through the Rust core.
@MainActor
final class TrackedSource: PoseSource {
    let name: String
    let headset: Headset

    init(name: String, headset: Headset) {
        self.name = name
        self.headset = headset
    }

    /// The headset's own heights are from wherever its tracking began (a desk, a lap): the place's
    /// ground was then at or above the eyes, and the saber and everything else below the horizon
    /// were hidden behind it. The heights are lifted so the
    /// eyes are at a usual height when tracking starts and at each recenter; moving up and down
    /// from there is kept. Until the floor is measured (onboarding), this is the floor.
    private var lift: Float?
    private var wasWorn = false
    private var nominalHeight: Float { Settings.shared.mode == .roomScale ? 1.65 : 1.25 }

    func pose(atHostNs t: Int64) -> HeadPose? {
        guard var pose = headset.predict(atHostNs: t) else { return nil }
        // Put on: the height is taken again (Halliday often starts with the headset on a desk).
        let worn = headset.status?.worn ?? false
        if worn, !wasWorn { lift = nil }
        wasWorn = worn
        if lift == nil {
            lift = nominalHeight - pose.position.y
            log(String(format: "[display] eyes taken to be %.2f m above the floor (the headset said %.2f)", nominalHeight, pose.position.y))
        }
        pose.position.y += lift ?? 0
        return pose
    }

    /// What is added to the headset's own heights (for places worked out from its raw pose).
    var heightLift: Float { lift ?? 0 }

    func recenter() {
        headset.recenter()
        lift = nil
    }
    var calibration: [Float] { headset.calibration }
    var state: String { headset.linkState.description }
}
