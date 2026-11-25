import Foundation
import simd

@main struct ProjectionGeometryTests {
    static func main() {
        let fov = SIMD4<Float>(-1, 1, 1, -1), ipd: Float = 0.064
        let q = simd_quatf(angle: 0.57, axis: simd_normalize(SIMD3<Float>(0.3, 1, -0.2)))
        let p = SIMD3<Float>(0.2, 1.7, -0.4)
        let left = ProjectionEyeView(position: p + q.act([-ipd/2, 0, 0]), orientation: q, tangents: fov)
        let right = ProjectionEyeView(position: p + q.act([ipd/2, 0, 0]), orientation: q, tangents: fov)
        let ordinary = ProjectionEyeViews(left: left, right: right)
        func legacy(_ views: ProjectionEyeViews) -> Bool {
            views.matchesLegacy(position: p, orientation: q, ipd: ipd, leftTangents: fov, rightTangents: fov)
        }
        precondition(ordinary.isValid && legacy(ordinary))
        var sign = ordinary; sign.left.orientation = simd_quatf(vector: -q.vector)
        precondition(legacy(sign), "Quaternion sign does not change a view")
        var zoom = ordinary; zoom.right.tangents *= 0.7
        precondition(!legacy(zoom), "A genuine zoom cannot use calibrated FOV")
        var canted = ordinary
        canted.left.orientation = q * simd_quatf(angle: 0.001, axis: [0,1,0])
        precondition(!legacy(canted), "A real small camera rotation is not rounding noise")
        var shifted = ordinary; shifted.right.position.x += 0.008
        precondition(!legacy(shifted), "Eye baseline must be preserved")
        var bad = ordinary; bad.left.tangents.x = .nan; precondition(!bad.isValid)
        bad = ordinary; bad.right.orientation = simd_quatf(vector: .zero); precondition(!bad.isValid)
        bad = ordinary; bad.right.tangents.y = bad.right.tangents.x; precondition(!bad.isValid)
        precondition(!ordinary.jumped(from: sign))
        shifted = ordinary; shifted.right.position.z += 0.4
        precondition(shifted.jumped(from: ordinary))
        // A noncommuting world-origin transform must move both rendered eye
        // cameras together, without introducing a false baseline correction.
        let turn = simd_quatf(angle: -0.82, axis: simd_normalize(SIMD3<Float>(1,0.2,0.4)))
        let translation = SIMD3<Float>(-1,0.3,0.8)
        func transformed(_ v: ProjectionEyeView) -> ProjectionEyeView {
            .init(position: translation + turn.act(v.position), orientation: turn*v.orientation, tangents: v.tangents)
        }
        precondition(ProjectionEyeViews(left: transformed(left), right: transformed(right))
            .matchesLegacy(position: translation+turn.act(p), orientation: turn*q, ipd: ipd,
                           leftTangents: fov, rightTangents: fov))
        print("PASS: calibrated bypass, quaternion sign, actual zoom/cant/baseline, invalid geometry, per-eye jumps and noncommuting origin transforms")
    }
}
