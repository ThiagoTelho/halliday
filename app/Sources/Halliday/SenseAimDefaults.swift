import Foundation

/// Manual pointing adjustments are intentional panel actions. Controller button
/// taps must never change the sensor-to-pointer alignment.
enum SenseAimDefaults {
    /// Halliday's original sensor mount correction, not raw IMU orientation.
    static let tilt: Float = 42 * .pi / 180
    static let migrationKey = "senseAim.noTapCalibrationVersion"
    static let migrationVersion = 1

    struct Tilts {
        let left: Float
        let right: Float
    }

    static func load(from defaults: UserDefaults) -> Tilts {
        // Older versions could save a new tilt accidentally on PS/Create/Options.
        // Reset only these two values once; later deliberate panel calibration
        // remains saved. Heading offsets are session-local and start empty.
        if defaults.integer(forKey: migrationKey) < migrationVersion {
            defaults.removeObject(forKey: "senseTilt.left")
            defaults.removeObject(forKey: "senseTilt.right")
            defaults.set(migrationVersion, forKey: migrationKey)
        }
        func saved(_ hand: String) -> Float {
            guard let value = defaults.object(forKey: "senseTilt.\(hand)") as? NSNumber,
                  value.floatValue.isFinite else { return tilt }
            return value.floatValue
        }
        return Tilts(left: saved("left"), right: saved("right"))
    }

    enum TapAction: Equatable { case none, toggleGameDashboard }

    static func tapAction(psReleased: Bool, recenterFired: Bool, gamePresenting: Bool) -> TapAction {
        // A long hold has already recentered. A short PS release is reserved for
        // the game dashboard; outside games all system/menu taps leave aim alone.
        psReleased && !recenterFired && gamePresenting ? .toggleGameDashboard : .none
    }
}
