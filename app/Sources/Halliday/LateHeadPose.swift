import simd

/// A pose predicted for the caller's requested host time. The orientation maps
/// head-local axes into the existing tracking/recentered world. Motion validity
/// is separate: a valid orientation does not prove that the last gyro is fresh.
struct LateHeadPose {
    let orientation: simd_quatf
    /// Radians/second in head-local axes, exactly as supplied by Headset.predict.
    let bodyAngularVelocity: SIMD3<Float>
    /// Bit0: linear motion known. Bit1: angular motion known. No default validity.
    let motionFlags: UInt32
    /// Nonzero generation published coherently with this orientation. Zero
    /// denotes legacy/synthetic sources without a discontinuity contract.
    var trackingGeneration: UInt64 = 0
    var normalizedOrientation: simd_quatf? {
        let q = orientation.vector, n = simd_length_squared(q)
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite,
              n.isFinite, n > 1e-8 else { return nil }
        return orientation.normalized
    }

    /// The existing 12rad/s sanity limit is retained. Invalid/stale motion must
    /// not bend scanlines, but must not discard the independently valid pose.
    var scanAngularVelocity: SIMD3<Float>? {
        guard motionFlags & 2 != 0,
              bodyAngularVelocity.x.isFinite,
              bodyAngularVelocity.y.isFinite,
              bodyAngularVelocity.z.isFinite,
              simd_length(bodyAngularVelocity) < 12 else { return nil }
        return bodyAngularVelocity
    }
}
