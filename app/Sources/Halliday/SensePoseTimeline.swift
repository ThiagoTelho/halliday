import simd

/// Resolve one sensor pose before applying menu/aim/grip mounts or a local lever.
/// Orientation and optical place must use this same returned host target.
enum SensePoseTimeline {
    // The orientation's former 80 ms safety cap remains an upper bound. The
    // common pose uses PlaceFilter's existing 60 ms support beyond newest IMU.
    static let maximumOrientationAhead = 0.080
    static let maximumPlaceAhead = 0.060
    static let maximumHistory = 0.050
    struct Sample {
        let orientation: simd_quatf
        let targetHostNs: Int64
        var targetSeconds: Double { Double(targetHostNs) * 1e-9 }
    }

    static func sample(orientation: simd_quatf, bodyAngular: SIMD3<Float>, sampleHostNs: Int64,
                       reportAge: Float, now: Double, frameTarget: Double, fallbackLead: Double,
                       historical: (Int64) -> simd_quatf?) -> Sample? {
        let q = orientation.vector
        let qNorm = simd_length_squared(q), rateNorm = simd_length_squared(bodyAngular)
        guard now.isFinite, now > 0, reportAge.isFinite, reportAge >= 0,
              q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite,
              qNorm.isFinite, qNorm > 1e-8, rateNorm.isFinite,
              bodyAngular.x.isFinite, bodyAngular.y.isFinite, bodyAngular.z.isFinite else { return nil }
        let source = sampleHostNs > 0 ? Double(sampleHostNs) * 1e-9 : now - Double(reportAge)
        guard source.isFinite, source > 0 else { return nil }
        let lead = fallbackLead.isFinite ? max(0, min(maximumOrientationAhead, fallbackLead)) : 0
        let wanted = frameTarget.isFinite && frameTarget > 0 ? frameTarget : now + lead
        let target = max(source - maximumHistory, min(source + min(maximumOrientationAhead, maximumPlaceAhead), wanted))
        guard target > 0, target < Double(Int64.max) * 1e-9 else { return nil }
        let targetNs = Int64((target * 1e9).rounded())
        let base = simd_normalize(orientation)
        if target < source {
            if let old = historical(targetNs) { return Sample(orientation: old, targetHostNs: targetNs) }
            // A new calibration/connection may not yet have a bracket. Keep
            // both components at the measured sample, never extrapolate back.
            return Sample(orientation: base, targetHostNs: Int64((source * 1e9).rounded()))
        }
        let turn = bodyAngular * Float(target - source)
        let angle = simd_length(turn)
        let predicted = angle > 1e-8 ? base * simd_quatf(angle: angle, axis: turn / angle) : base
        return Sample(orientation: simd_normalize(predicted), targetHostNs: targetNs)
    }

    /// A local offset is rotated with the predicted sensor orientation, once.
    /// Halliday's current optical output already is the IMU origin, so no Sony
    /// driver/root translations are imported here.
    static func mounted(position: SIMD3<Float>, sensor: simd_quatf, localPosition: SIMD3<Float>,
                        localOrientation: simd_quatf) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        (position + sensor.act(localPosition), sensor * localOrientation)
    }
}
