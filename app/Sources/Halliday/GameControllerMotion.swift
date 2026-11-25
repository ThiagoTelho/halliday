import simd

/// Motion is separate from the hand's render pose: fixed aim calibration never
/// changes the body's gyro axes, and recenter translations are not movement.
struct GameControllerMotion {
    let linearWorld: SIMD3<Float>
    let angularWorld: SIMD3<Float>
    let sampledAt: Double
    private let linearExpiresAt: Double
    private let angularExpiresAt: Double

    static let freshness = 0.25 // Same horizon as a Sense report-gap filter reset.
    // Reject corrupt estimates; these bounds are far beyond normal hand motion.
    // No deadzone, smoothing or clamping is added to the measured velocities.
    private static let maximumLinearSpeed: Float = 100
    private static let maximumAngularSpeed: Float = 100
    static let stationary = Self(linearWorld: .zero, angularWorld: .zero, sampledAt: 0,
                                 linearExpiresAt: 0, angularExpiresAt: 0)

    /// HeadPose's gyro stays body-local for rolling-shutter correction. Only
    /// the public game pose uses world angular velocity (the OpenXR/OpenVR basis).
    static func angularInGame(body: SIMD3<Float>, bodyOrientation: simd_quatf,
                              originTurn: simd_quatf) -> SIMD3<Float> {
        let a = bodyOrientation.vector, b = originTurn.vector
        guard [a.x,a.y,a.z,a.w,b.x,b.y,b.z,b.w].allSatisfy(\.isFinite),
              simd_length_squared(a) > 1e-8, simd_length_squared(b) > 1e-8 else { return .zero }
        return simd_normalize(originTurn).inverse.act(simd_normalize(bodyOrientation).act(
            sane(body, limit: maximumAngularSpeed)))
    }

    static func sample(linearWorld: SIMD3<Float>?, bodyAngular: SIMD3<Float>,
                       sensorInRoom: simd_quatf, reportAge: Float,
                       opticalAge: Double?, now: Double) -> Self {
        guard now.isFinite, now > 0, reportAge.isFinite, reportAge >= 0,
              Double(reportAge) <= freshness else { return .stationary }
        let q = sensorInRoom.vector
        let norm = simd_length_squared(q)
        let quaternionValid = q.x.isFinite && q.y.isFinite && q.z.isFinite && q.w.isFinite &&
            norm.isFinite && norm > 1e-8
        let angular = quaternionValid
            ? sane(simd_normalize(sensorInRoom).act(bodyAngular), limit: maximumAngularSpeed) : .zero
        let linear: SIMD3<Float>
        let reportExpiresAt = now + freshness - Double(reportAge)
        let angularExpiresAt = quaternionValid && isSane(bodyAngular, limit: maximumAngularSpeed)
            ? reportExpiresAt : 0
        let linearExpiresAt: Double
        // A camera timestamp may be a little ahead of the host (the optical
        // worker already permits at most 20 ms). Missing tracking publishes no
        // invented motion for the fallback hand position.
        if let opticalAge, opticalAge.isFinite, opticalAge >= -0.020,
           opticalAge <= freshness, let linearWorld, isSane(linearWorld, limit: maximumLinearSpeed) {
            linear = sane(linearWorld, limit: maximumLinearSpeed)
            linearExpiresAt = min(reportExpiresAt, now + freshness - max(0, opticalAge))
        } else { linear = .zero; linearExpiresAt = 0 }
        return Self(linearWorld: linear, angularWorld: angular, sampledAt: now,
                    linearExpiresAt: linearExpiresAt, angularExpiresAt: angularExpiresAt)
    }

    func inGame(originTurn: simd_quatf, now: Double) -> (linear: SIMD3<Float>, angular: SIMD3<Float>) {
        let age = now - sampledAt
        let q = originTurn.vector
        let norm = simd_length_squared(q)
        guard sampledAt > 0, age.isFinite, age >= 0, age <= Self.freshness,
              q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite,
              norm.isFinite, norm > 1e-8 else { return (.zero, .zero) }
        let toGame = simd_normalize(originTurn).inverse
        return (now <= linearExpiresAt ? toGame.act(Self.sane(linearWorld, limit: Self.maximumLinearSpeed)) : .zero,
                now <= angularExpiresAt ? toGame.act(Self.sane(angularWorld, limit: Self.maximumAngularSpeed)) : .zero)
    }

    func validity(originTurn: simd_quatf, now: Double) -> UInt32 {
        let age = now - sampledAt, q = originTurn.vector
        let norm = simd_length_squared(q)
        guard sampledAt > 0, age.isFinite, age >= 0, age <= Self.freshness,
              [q.x,q.y,q.z,q.w].allSatisfy(\.isFinite), norm.isFinite, norm > 1e-8 else { return 0 }
        return (now <= linearExpiresAt ? 1 : 0) | (now <= angularExpiresAt ? 2 : 0)
    }

    private static func isSane(_ v: SIMD3<Float>, limit: Float) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite && simd_length_squared(v) <= limit * limit
    }

    private static func sane(_ v: SIMD3<Float>, limit: Float) -> SIMD3<Float> {
        guard v.x.isFinite, v.y.isFinite, v.z.isFinite,
              simd_length_squared(v) <= limit * limit else { return .zero }
        return v
    }
}
