import simd

@main struct GameControllerMotionTests {
    static func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String) {
        precondition(simd_distance(a, b) < 2e-5, "\(message): \(a) != \(b)")
    }
    static func main() {
        let identity = simd_quatf(angle: 0, axis: [0, 1, 0])
        let origin = simd_quatf(angle: 1.2, axis: [0, 1, 0])
        let headTurn = simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3<Float>(1,2,3)))
        let headGyro = SIMD3<Float>(0.3,-0.5,0.8)
        let worldGyro = headTurn.act(headGyro)
        let headInGame = GameControllerMotion.angularInGame(body: headGyro, bodyOrientation: headTurn, originTurn: origin)
        near(headInGame, origin.inverse.act(worldGyro), "Head body gyro must become game-world angular velocity")
        let sameMotionHand = GameControllerMotion.sample(linearWorld: .zero, bodyAngular: worldGyro,
            sensorInRoom: identity, reportAge: 0, opticalAge: 0, now: 10).inGame(originTurn: origin, now: 10)
        near(sameMotionHand.angular - headInGame, .zero, "Equal head/hand world rotation must have zero relative angular velocity")
        for hand: Float in [-1, 1] {
            let linear = SIMD3<Float>(hand * 1.3, 0.4, -2.1)
            let gyro = SIMD3<Float>(0.3, hand * 2.0, -0.8)
            let sensor = simd_quatf(angle: hand * 0.8, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
            let lean = simd_quatf(angle: 0.2, axis: [0, 0, 1])
            let heading = simd_quatf(angle: hand * 0.6, axis: [0, 1, 0])
            let room = lean * heading * sensor
            for tilt: Float in [-0.5, 0, 0.733, 1.1] {
                let mount = simd_quatf(angle: tilt, axis: [1, 0, 0])
                let aim = room * mount
                let motion = GameControllerMotion.sample(linearWorld: linear, bodyAngular: gyro,
                    sensorInRoom: aim * mount.inverse, reportAge: 0.015, opticalAge: 0.035, now: 10)
                let plain = motion.inGame(originTurn: identity, now: 10.01)
                near(plain.linear, linear, "Measured room linear velocity must pass unchanged")
                near(plain.angular, room.act(gyro), "Mount tilt must not rotate the sensor gyro twice")
                let recentered = motion.inGame(originTurn: origin, now: 10.01)
                near(recentered.linear, origin.inverse.act(linear), "Recenter must rotate linear velocity")
                near(recentered.angular, origin.inverse.act(room.act(gyro)), "Recenter must rotate angular velocity")
            }
        }

        func sample(linear: SIMD3<Float>? = [1, 2, 3], gyro: SIMD3<Float> = [0, 2, 0],
                    orientation: simd_quatf? = nil, age: Float = 0.01,
                    optical: Double? = 0.04, now: Double = 10) -> GameControllerMotion {
            .sample(linearWorld: linear, bodyAngular: gyro, sensorInRoom: orientation ?? identity,
                    reportAge: age, opticalAge: optical, now: now)
        }
        for age: Float in [.nan, .infinity, -0.01, 0.251, 100] {
            let v = sample(age: age).inGame(originTurn: identity, now: 10)
            near(v.linear, .zero, "Stale/invalid report must not keep throwing")
            near(v.angular, .zero, "Stale/invalid report must not keep spinning")
        }
        for age: Double? in [nil, .nan, .infinity, -0.021, 0.251, 3] {
            let v = sample(optical: age).inGame(originTurn: identity, now: 10)
            near(v.linear, .zero, "Missing/stale optical tracking must not move the fallback hand")
            near(v.angular, [0, 2, 0], "Fresh measured rotation remains available during optical loss")
        }
        let fresh = sample()
        precondition(fresh.validity(originTurn: identity, now: 10) == 3)
        precondition(sample(linear: nil).validity(originTurn: identity, now: 10) == 2,
                     "missing optical translation must not invent linear validity")
        precondition(sample(gyro: [.nan,0,0]).validity(originTurn: identity, now: 10) == 1,
                     "invalid gyro must not discard independently measured linear velocity")
        precondition(sample(linear: [.nan,0,0]).validity(originTurn: identity, now: 10) == 2,
                     "invalid translation must not discard measured gyro")
        precondition(sample(optical: 0.24).validity(originTurn: identity, now: 10.02) == 2)
        precondition(sample(age: 0.24).validity(originTurn: identity, now: 10.02) == 0)
        let oldReport = sample(age: 0.24).inGame(originTurn: identity, now: 10.02)
        near(oldReport.linear, .zero, "Queueing a packet must not renew its old report's expiry")
        near(oldReport.angular, .zero, "Queueing a packet must not renew its old gyro's expiry")
        let oldFix = sample(optical: 0.24).inGame(originTurn: identity, now: 10.02)
        near(oldFix.linear, .zero, "Queueing a packet must not renew an old optical fix")
        near(oldFix.angular, [0, 2, 0], "Optical expiry must not suppress a still-fresh gyro")
        for time in [Double.nan, .infinity, 9.999, 10.251] {
            let v = fresh.inGame(originTurn: identity, now: time)
            near(v.linear, .zero, "Expired/out-of-order host packet must not replay motion")
            near(v.angular, .zero, "Expired/out-of-order host packet must not replay motion")
        }
        for bad: SIMD3<Float> in [[.nan, 0, 0], [0, .infinity, 0], [10_000, 0, 0]] {
            let v = sample(linear: bad, gyro: bad).inGame(originTurn: identity, now: 10)
            near(v.linear, .zero, "Reject corrupt finite or nonfinite linear estimate")
            near(v.angular, .zero, "Reject corrupt finite or nonfinite gyro estimate")
        }
        let badQuaternion = simd_quatf(vector: SIMD4<Float>(repeating: .nan))
        precondition(sample(orientation: badQuaternion).validity(originTurn: identity, now: 10) == 1)
        precondition(fresh.validity(originTurn: badQuaternion, now: 10) == 0)
        near(sample(orientation: badQuaternion).inGame(originTurn: identity, now: 10).angular, .zero, "Invalid sensor basis")
        near(fresh.inGame(originTurn: badQuaternion, now: 10).linear, .zero, "Invalid recenter basis")
        let tiny = sample(linear: [0.0001, 0, 0], gyro: [0, 0.0001, 0]).inGame(originTurn: identity, now: 10)
        near(tiny.linear, [0.0001, 0, 0], "No introduced linear deadzone")
        near(tiny.angular, [0, 0.0001, 0], "No introduced angular deadzone")
        print("PASS: both hands, sensor/body-to-world gyro basis, calibrated mount independence, recenter rotation, no deadzone, tracking/report gaps, expired packets and corrupt values")
    }
}
