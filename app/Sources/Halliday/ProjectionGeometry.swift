import Foundation
import simd

/// The actual view used to render one eye, in Halliday world coordinates.
/// Pixels are canonicalized before transport when an OpenXR FOV requests a mirror.
struct ProjectionEyeView: Equatable {
    var position: SIMD3<Float>
    var orientation: simd_quatf
    var tangents: SIMD4<Float> // left, right, up, down

    var isValid: Bool {
        let q = orientation.vector
        return (0..<3).allSatisfy { position[$0].isFinite }
            && (0..<4).allSatisfy { q[$0].isFinite && tangents[$0].isFinite }
            && (0.98...1.02).contains(simd_length_squared(q))
            && tangents.x < tangents.y && tangents.w < tangents.z
    }
    static func == (a: Self, b: Self) -> Bool {
        a.position == b.position && a.orientation.vector == b.orientation.vector && a.tangents == b.tangents
    }
}

struct ProjectionEyeViews: Equatable {
    var left: ProjectionEyeView
    var right: ProjectionEyeView
    var isValid: Bool { left.isValid && right.isValid }
    func view(_ eye: Int) -> ProjectionEyeView { eye == 0 ? left : right }

    /// Keep the bit-identical legacy path for ordinary calibrated views. These
    /// tolerances cover floating-point composition, not a different camera.
    func matchesLegacy(position: SIMD3<Float>, orientation: simd_quatf,
                       ipd: Float, leftTangents: SIMD4<Float>, rightTangents: SIMD4<Float>) -> Bool {
        guard isValid, ipd.isFinite, simd_length_squared(orientation.vector) > 0.1,
              (0..<4).allSatisfy({ orientation.vector[$0].isFinite }),
              (0..<3).allSatisfy({ position[$0].isFinite }) else { return false }
        let legacyQ = simd_normalize(orientation.vector)
        for eye in 0..<2 {
            let actual = view(eye)
            var actualQ = simd_normalize(actual.orientation.vector)
            if simd_dot(actualQ, legacyQ) < 0 { actualQ = -actualQ }
            let expected = position + orientation.act(SIMD3((eye == 0 ? -0.5 : 0.5) * ipd, 0, 0))
            let fov = eye == 0 ? leftTangents : rightTangents
            if simd_distance(actual.position, expected) > 0.00001
                || (0..<4).contains(where: { abs(actualQ[$0] - legacyQ[$0]) > 0.00001 })
                || (0..<4).contains(where: { abs(actual.tangents[$0] - fov[$0]) > 0.000001 }) {
                return false
            }
        }
        return true
    }
    func jumped(from prior: Self) -> Bool {
        (0..<2).contains { eye in
            let a = view(eye), b = prior.view(eye)
            return simd_distance(a.position, b.position) > 0.25
                || abs(simd_dot(simd_normalize(a.orientation.vector), simd_normalize(b.orientation.vector))) < 0.866
        }
    }
}
