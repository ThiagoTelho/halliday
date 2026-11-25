import Foundation

@main
struct SenseAimDefaultsTests {
    static func main() {
        let suite = "HallidaySenseAimTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let retained: [String: Any] = [
            "gameFSREnabled": true, "gameRenderPercent": 80, "brightness": 0.72,
            "mode": "roomScale", "customFuturePreference": ["keep": "yes"]
        ]
        for (key, value) in retained { defaults.set(value, forKey: key) }
        defaults.set(Float(-0.65), forKey: "senseTilt.left")
        defaults.set(Float(1.2), forKey: "senseTilt.right")
        let reset = SenseAimDefaults.load(from: defaults)
        precondition(abs(reset.left * 180 / .pi - 42) < 0.0001 && reset.left == reset.right,
                     "Legacy aim must reset to the original 42° mount correction for both hands")
        precondition(defaults.object(forKey: "senseTilt.left") == nil && defaults.object(forKey: "senseTilt.right") == nil,
                     "Migration must remove both legacy manual tilts")
        precondition(defaults.integer(forKey: SenseAimDefaults.migrationKey) == SenseAimDefaults.migrationVersion)
        for (key, value) in retained {
            precondition(NSDictionary(dictionary: [key: defaults.object(forKey: key)!]).isEqual(to: [key: value]),
                         "Migration modified unrelated preference \(key)")
        }

        // The marker distinguishes later deliberate panel calibration from old
        // accidental tap calibration: it must survive the next app launch.
        defaults.set(Float(0.35), forKey: "senseTilt.left")
        defaults.set(Float(-0.2), forKey: "senseTilt.right")
        let deliberate = SenseAimDefaults.load(from: defaults)
        precondition(deliberate.left == 0.35 && deliberate.right == -0.2,
                     "The migration ran again and erased intentional calibration")
        defaults.removeObject(forKey: "senseTilt.left")
        let oneHand = SenseAimDefaults.load(from: defaults)
        precondition(oneHand.left == SenseAimDefaults.tilt && oneHand.right == -0.2,
                     "Missing per-hand calibration must use its original default")
        defaults.set(Float.nan, forKey: "senseTilt.left")
        precondition(SenseAimDefaults.load(from: defaults).left == SenseAimDefaults.tilt,
                     "Non-finite saved tilt must not reach pose calculations")

        for released in [false, true] {
            for recentered in [false, true] {
                for presenting in [false, true] {
                    let action = SenseAimDefaults.tapAction(psReleased: released,
                        recenterFired: recentered, gamePresenting: presenting)
                    if released && !recentered && presenting {
                        precondition(action == .toggleGameDashboard, "PS game dashboard toggle was lost")
                    } else {
                        precondition(action == .none, "PS changed aim or opened a dashboard outside a short game tap")
                    }
                }
            }
        }
        print("PASS: original 42° per-hand defaults, one-time legacy tilt reset, unrelated preferences preserved, later deliberate calibration retained, finite-value fallback, PS short/held game-dashboard routing")
    }
}
