// Rotation-only late reprojection of the newest successful completed stereo scene.
// The physical display clock offers outputs independently of scene rendering.
// A fresh coherent pose is sampled after drawable acquisition; untrusted legacy
// sources retain the conservative large-turn guard. Presentation targets use
// host time and actual presented feedback, not a claimed photon timestamp.

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
    /// Legacy callers without a coherent tracking discontinuity generation
    /// retain the original conservative large-turn guard.
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
    private static let displayRateLock = NSLock()
    nonisolated(unsafe) private static var storedDisplayHz: Float = 120
    static var displayHz: Float {
        get { displayRateLock.lock(); defer { displayRateLock.unlock() }; return storedDisplayHz }
        set { guard newValue.isFinite && newValue > 0 else { return }; displayRateLock.lock(); storedDisplayHz = newValue; displayRateLock.unlock() }
    }
    private static let scanScale: Float = {
        let a = CommandLine.arguments
        if a.contains("--no-scanout") { return 0 }
        return a.firstIndex(of: "--scanout-scale").flatMap { $0 + 1 < a.count ? Float(a[$0 + 1]) : nil } ?? 1
    }()
    static func scanDuration(forDisplayHz hz: Float) -> Float {
        scanScale * Headsets.current.scanFraction / max(hz, 30)
    }
    static var scanDuration: Float { scanDuration(forDisplayHz: displayHz) }
    private static func warp(_ rotation: simd_float3x3) -> LensWarp {
        LensWarp(rotation: rotation, tanLeft: eyeTangents.0, tanRight: eyeTangents.1)
    }

    private let lock = NSLock()
    private var count = 0, early = 0.0, late = 0.0, handler = 0.0, maxHandler = 0.0, waited = 0.0
    private var turned = 0.0, maxTurned: Float = 0, missing = 0, refused = 0

    /// The scene was drawn with `rendered` for `targetNs` (host ns): the late orientation for the
    /// same moment, as the lens pass's turn. Any thread.
    func latch(rendered: simd_quatf, startedNs: Int64, targetNs: Int64, sceneEnd: Double, drawableWait: Double,
               pose: (Int64) -> LateHeadPose?,
               scanDuration: Float? = nil, trackingGeneration: UInt64 = 0) -> LensWarp {
        let now = CACurrentMediaTime()
        let latchedNs = Int64(now * 1e9)
        guard let sample = pose(targetNs) else {
                lock.lock(); missing += 1; lock.unlock()
            return Self.noTurn
        }
        // Valid orientation and valid angular motion are separate contracts.
        guard let late = sample.normalizedOrientation,
              rendered.vector.x.isFinite, rendered.vector.y.isFinite,
              rendered.vector.z.isFinite, rendered.vector.w.isFinite,
              simd_length_squared(rendered.vector).isFinite,
              simd_length_squared(rendered.vector) > 1e-8 else { return Self.noTurn }
        let turn = (rendered.normalized.inverse * late).normalized
        let angle = 2 * acos(min(1, abs(turn.real)))
        let trusted = trackingGeneration != 0 && trackingGeneration == sample.trackingGeneration
        let taken = trusted || angle < Self.maxTurn
        record(early: Double(targetNs - startedNs) / 1e6, late: Double(targetNs - latchedNs) / 1e6,
               handler: sceneEnd > 0 ? (now - sceneEnd) * 1000 : 0, waited: drawableWait * 1000, angle: taken ? angle : nil)
        var warp = taken ? Self.warp(simd_float3x3(turn)) : Self.noTurn
        // Unknown/stale gyro suppresses rolling-scan prediction only. The late
        // orientation above remains usable even when angular motion is unknown.
        if let turning = sample.scanAngularVelocity {
            warp.scan = SIMD4(turning, scanDuration ?? Self.scanDuration)
        }
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
