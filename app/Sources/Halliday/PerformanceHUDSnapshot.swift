import Foundation

/// Software measurements only. Pose→display ends at actual presentation start,
/// not scanout centre, photons, or externally measured motion-to-photon delay.
struct PerformanceHUDSample: Sendable, Equatable {
    let time: Double
    let gameFPS: Double?
    /// Reciprocal of the measured producer-window throughput: average interval, not GPU work.
    let gameFrameTimeMs: Double?
    let poseToDisplayMs: Double?
}

struct PerformanceHUDSnapshot: Sendable, Equatable {
    let gameFPS: Double?
    let displayFPS: Double?
    let poseToDisplayMs: Double?
    let history: [PerformanceHUDSample]
    static let empty = PerformanceHUDSnapshot(gameFPS: nil, displayFPS: nil,
        poseToDisplayMs: nil, history: [])
}
