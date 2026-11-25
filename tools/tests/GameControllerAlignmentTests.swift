import Foundation
import simd

@main struct GameControllerAlignmentTests {
    static func main() {
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String) {
            precondition(simd_distance(a, b) < 0.00001, message)
        }
        let forward = SIMD3<Float>(0, 0, -1)
        let up = SIMD3<Float>(0, 1, 0)
        precondition(abs(GameControllerAlignment.senseGameMountDegrees - 49.8703) < 0.0001)
        let identity = simd_quatf(angle: 0, axis: [1, 0, 0])
        let lifted = GameControllerAlignment.senseOrientation(identity, pointerMountRadians: 42 * .pi / 180)
        precondition(lifted.act(forward).y > 0, "The derived correction must lift rather than lower the wrists")

        // Cover both handed attitudes, palms up/down, and prior pointer calibration.
        for yaw in [-140, -45, 0, 45, 140] {
            for roll in [-180, -90, 0, 90, 180] {
                for pitch in [-65, 0, 65] {
                    let sensor = simd_quatf(angle: Float(yaw) * .pi / 180, axis: [0, 1, 0])
                        * simd_quatf(angle: Float(pitch) * .pi / 180, axis: [1, 0, 0])
                        * simd_quatf(angle: Float(roll) * .pi / 180, axis: [0, 0, 1])
                    // Independently compose the pinned Monado AIM chain.
                    let expected = sensor
                        * simd_quatf(angle: 50.2703 * .pi / 180, axis: [1, 0, 0])
                        * simd_quatf(angle: 39 * .pi / 180, axis: [1, 0, 0])
                        * simd_quatf(angle: -39.4 * .pi / 180, axis: [1, 0, 0])
                    for pointerMount: Float in [-18, 42, 70] {
                        let mount = pointerMount * .pi / 180
                        let pointer = sensor * simd_quatf(angle: mount, axis: [1, 0, 0])
                        let game = GameControllerAlignment.senseOrientation(pointer, pointerMountRadians: mount)
                        near(game.act(forward), expected.act(forward), "Replace pointer mount once with fixed Sense aim frame")
                        near(game.act(up), expected.act(up), "No extra roll or hand-dependent tilt")
                        let step = simd_quatf(angle: 0.01, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
                        let next = GameControllerAlignment.senseOrientation(step * pointer, pointerMountRadians: mount)
                        near((next * game.inverse).act(forward), step.act(forward), "Preserve measured room angular velocity")
                        precondition(abs(simd_length(game.vector) - 1) < 0.00001)
                    }
                }
            }
        }
        for invalid in [Float.nan, .infinity, -.infinity] {
            near(GameControllerAlignment.senseOrientation(identity, pointerMountRadians: invalid).act(forward),
                 lifted.act(forward), "Non-finite saved pointer mount uses original default")
        }
        print("PASS: pinned Sense AIM transform, +7.8703° lift, both hand attitudes, pointer calibration independence, normalized rotations and unchanged room angular velocity")
    }
}
