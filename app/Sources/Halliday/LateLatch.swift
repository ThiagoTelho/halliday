// Late latching: the lens pass re-aims each eye's picture with the head's orientation taken once
// the scene has been drawn, not when the frame started (ROADMAP W11 1.7).
//
// Things fixed in space shook with every small movement of the headset. The log says why: a frame reached the eyes 20 to 37 ms after
// it started, and with the panel's own delay the pose was predicted 35 to 45 ms ahead. No
// prediction follows a tremor that far (on the worn recording, the orientation's error is 0.03°
// predicted 12 ms ahead, 0.10° at 29 ms and 0.17° at 40 ms, p95 0.58°: a centimeter at a meter).
// The scene itself is drawn 6 ms after the frame starts at best, and finished 12 to 15 ms after.
//
// So a frame on the headset is drawn in two parts (`Renderer.renderLatched`). The main thread
// draws the scene with the pose predicted at the frame's start, into one of two eye textures, and
// never waits for a drawable (it waited up to 9 ms a frame for one, and frames were lost). When
// the GPU has drawn the scene, a thread of its own takes a drawable, asks the tracker again for
// the same moment (the frame's time on the panel), now with that much more of the 2000 Hz gyro,
// and encodes the lens pass with the turn between the two orientations (`latch`). The lens pass
// turns every vertex's sampling direction by it (`distort_vs`): what the eye texture shows was
// seen from the rendered orientation, and is shown from the late one. Rotation only, as Oculus's
// timewarp: the position changes far less in that time than a turn shows (0.3 mm against 0.2°
// at a meter).
//
// `--no-late-latch` draws frames as before, in one piece, to compare.

import Foundation
import Metal
import QuartzCore
import simd

/// Must match `LensWarp` in Shaders.swift.
struct LensWarp {
    /// Turns a direction of the view shown (the head's frame at the late pose) into the view the
    /// eye texture was drawn from.
    var rotation: simd_float3x3
    /// tan of each eye's field of view: left, right, up, down (as `SceneUniforms.tanLRUD`).
    var tanLeft: SIMD4<Float>
    var tanRight: SIMD4<Float>
    /// xyz: how the head turns (rad/s, its own axes); w: how long the panel takes from its top
    /// row to its bottom one (s). The lens pass turns each row for the moment it lights.
    var scan: SIMD4<Float> = .zero
}

final class LateLatch: @unchecked Sendable {
    static let enabled = !CommandLine.arguments.contains("--no-late-latch")
    /// A late turn larger than this is not a frame's worth of head motion (a recenter came in
    /// between): the frame is shown as drawn.
    private static let maxTurn: Float = 5 * .pi / 180

    /// The eyes' tangents, as `SceneUniforms.tanLRUD`.
    private static let eyeTangents: (SIMD4<Float>, SIMD4<Float>) = {
        let fov = { (eye: Eye) -> SIMD4<Float> in
            let f = Optics.fov(eye)
            return SIMD4(tan(f.left), tan(f.right), tan(f.up), tan(f.down))
        }
        return (fov(.left), fov(.right))
    }()
    /// No turn: a frame shown as it was drawn.
    static var noTurn: LensWarp { warp(matrix_identity_float3x3) }
    /// The panel lights its rows over part of a refresh, top to bottom (the headset adapter's
    /// `scanFraction`: 2040 of 2200 rows' worth of time on the PS VR2). `--no-scanout` leaves the rows as one moment, `--scanout-scale F`
    /// tries another length (negative: bottom to top).
    nonisolated(unsafe) static var displayHz: Float = 120
    private static let scanScale: Float = {
        let a = CommandLine.arguments
        if a.contains("--no-scanout") { return 0 }
        return a.firstIndex(of: "--scanout-scale").flatMap { $0 + 1 < a.count ? Float(a[$0 + 1]) : nil } ?? 1
    }()
    static var scanDuration: Float { scanScale * Headsets.current.scanFraction / max(displayHz, 30) }
    private static func warp(_ rotation: simd_float3x3) -> LensWarp {
        LensWarp(rotation: rotation, tanLeft: eyeTangents.0, tanRight: eyeTangents.1)
    }

    private let lock = NSLock()
    private var count = 0, early = 0.0, late = 0.0, handler = 0.0, maxHandler = 0.0, waited = 0.0
    private var turned = 0.0, maxTurned: Float = 0, missing = 0, refused = 0

    /// The scene was drawn with `rendered` for `targetNs` (host ns): the late orientation for the
    /// same moment, as the lens pass's turn. Any thread.
    func latch(rendered: simd_quatf, startedNs: Int64, targetNs: Int64, sceneEnd: Double, drawableWait: Double,
               pose: (Int64) -> (orientation: simd_quatf, turning: SIMD3<Float>)?) -> LensWarp {
        let now = CACurrentMediaTime()
        let latchedNs = Int64(now * 1e9)
        guard let (late, turning) = pose(targetNs) else {
            lock.lock(); missing += 1; lock.unlock()
            return Self.noTurn
        }
        let turn = (rendered.inverse * late).normalized
        let angle = 2 * acos(min(1, abs(turn.real)))
        let taken = angle < Self.maxTurn
        record(early: Double(targetNs - startedNs) / 1e6, late: Double(targetNs - latchedNs) / 1e6,
               handler: sceneEnd > 0 ? (now - sceneEnd) * 1000 : 0, waited: drawableWait * 1000, angle: taken ? angle : nil)
        var warp = taken ? Self.warp(simd_float3x3(turn)) : Self.noTurn
        // Not while the head whips round (or the gyro says something absurd): 12 rad/s is 690°/s.
        if simd_length(turning) < 12 { warp.scan = SIMD4(turning, Self.scanDuration) }
        return warp
    }

    private func record(early e: Double, late l: Double, handler h: Double, waited w: Double, angle: Float?) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        early += e; late += l; handler += h; maxHandler = max(maxHandler, h); waited += w
        if let angle {
            turned += Double(angle)
            maxTurned = max(maxTurned, angle)
        } else {
            refused += 1
        }
        guard count == 600 else { return }
        log(String(format: "[display] late latch: the head's orientation taken %.1f ms before a frame is seen (%.1f ms at its start), %.2f ms after the scene was drawn (%.2f at most, %.2f of it waiting for a drawable); turned %.3f° on average, %.2f° at most; %d refused, %d without a pose",
                   late / 600, early / 600, handler / 600, maxHandler, waited / 600, turned / 600 * 180 / .pi, maxTurned * 180 / .pi, refused, missing))
        count = 0; early = 0; late = 0; handler = 0; maxHandler = 0; waited = 0; turned = 0; maxTurned = 0; refused = 0; missing = 0
    }
}
