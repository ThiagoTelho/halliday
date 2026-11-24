import simd

/// Final game-hand orientation adjustment. This deliberately has no translation
/// or feedback into the optical solver, pointer calibration, or IMU fusion.
enum GameControllerAlignment {
    /// Monado's Sense AIM transform in the same unchanged IMU axes:
    /// inverse Rx(-50.2703°) · inverse Rx(-39°) · Rx(-39.4°).
    /// This replaces Halliday's comfortable 42° menu-pointer default for the
    /// shared aim-derived game pose. It does not import Monado's different grip
    /// frame or translations. See docs/controller-alignment.md for provenance.
    static let senseGameMountDegrees: Float = 50.2703 + 39 - 39.4

    static func senseOrientation(_ pointerOrientation: simd_quatf, pointerMountRadians: Float) -> simd_quatf {
        let pointerMount = pointerMountRadians.isFinite ? pointerMountRadians : 42 * .pi / 180
        return pointerOrientation * simd_quatf(angle: senseGameMountDegrees * .pi / 180 - pointerMount, axis: [1, 0, 0])
    }

}
