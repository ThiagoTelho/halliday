import Foundation

@main struct GameImageSettingsTests {
    @MainActor static func main() {
        let full = GameImagePlan.renderSize(percent: 100)
        precondition(full.width == 2016 && full.height == 2048)
        let eighty = GameImagePlan.renderSize(percent: 80)
        precondition(eighty.width == 1600 && eighty.height == 1632)
        var previous = (width: 0, height: 0)
        for percent in stride(from: 50, through: 100, by: 5) {
            let size = GameImagePlan.renderSize(percent: percent)
            precondition(size.width % 32 == 0 && size.height % 32 == 0)
            precondition(size.width * 2 <= 4096 && size.height <= 4096)
            precondition(size.width >= previous.width && size.height >= previous.height)
            precondition(abs(Double(size.width) - 2016 * Double(percent) / 100) <= 16)
            precondition(abs(Double(size.height) - 2048 * Double(percent) / 100) <= 16)
            previous = size
        }
        precondition(GameImagePlan.renderSize(percent: Int.min).width == GameImagePlan.renderSize(percent: 50).width)
        precondition(GameImagePlan.renderSize(percent: Int.max).height == full.height)
        let suite = "app.halliday.tests.game-image.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = Settings(defaults: defaults)
        precondition(!initial.gameFSREnabled && !initial.gameSharpeningEnabled && initial.gameRenderPercent == 100 && initial.gameSharpness == 0.3)

        // Invalid stored values cannot request an unsupported resolution or non-finite gain.
        defaults.set(53, forKey: "gameRenderPercent")
        defaults.set(Float(2.5), forKey: "gameSharpness")
        defaults.set(Float(0.7), forKey: "volume")
        defaults.set("roomScale", forKey: "mode")
        defaults.set("custom-place", forKey: "environment")
        defaults.set(true, forKey: "keyboardAuto")
        defaults.set(Float(0.6), forKey: "dimming")
        let existingPreferences = defaults.persistentDomain(forName: suite)!
        let restored = Settings(defaults: defaults)
        precondition(restored.gameRenderPercent == 55 && restored.gameSharpness == 1)
        precondition(!restored.gameSharpeningEnabled && restored.volume == 0.7 && restored.mode == .roomScale)
        precondition(NSDictionary(dictionary: existingPreferences).isEqual(to: defaults.persistentDomain(forName: suite)!))
        var changes = 0
        restored.onChange = { changes += 1 }
        restored.gameRenderPercent = Int.max
        precondition(restored.gameRenderPercent == 100 && defaults.integer(forKey: "gameRenderPercent") == 100 && changes == 1)
        restored.gameRenderPercent = Int.min
        precondition(restored.gameRenderPercent == 50 && changes == 2)
        restored.gameRenderPercent = 78
        precondition(restored.gameRenderPercent == 80 && changes == 3)
        restored.gameSharpness = .nan
        precondition(restored.gameSharpness == 0.3 && changes == 4)
        restored.gameSharpness = -.infinity
        precondition(restored.gameSharpness == 0.3 && changes == 5)
        restored.gameFSREnabled = true
        restored.gameSharpeningEnabled = true
        restored.gameSharpness = 0.65
        let reloaded = Settings(defaults: defaults)
        precondition(reloaded.gameFSREnabled && reloaded.gameSharpeningEnabled && reloaded.gameRenderPercent == 80 && reloaded.gameSharpness == 0.65)
        precondition(reloaded.volume == 0.7 && defaults.float(forKey: "volume") == 0.7)
        // Neither switch forces the other, and a disabled sharpener keeps its chosen strength.
        reloaded.gameFSREnabled = false
        precondition(reloaded.gameSharpeningEnabled)
        reloaded.gameSharpeningEnabled = false
        reloaded.gameFSREnabled = true
        precondition(!reloaded.gameSharpeningEnabled && reloaded.gameSharpness == 0.65)
        let disabledSharpening = Settings(defaults: defaults)
        precondition(disabledSharpening.gameFSREnabled && !disabledSharpening.gameSharpeningEnabled && disabledSharpening.gameSharpness == 0.65)
        for key in ["volume", "mode", "environment", "keyboardAuto", "dimming"] {
            precondition(NSDictionary(dictionary: [key: existingPreferences[key]!]).isEqual(to: [key: defaults.object(forKey: key)!]))
        }
        defaults.set("invalid", forKey: "gameSharpness")
        precondition(Settings(defaults: defaults).gameSharpness == 0.3)
        defaults.set("invalid", forKey: "gameRenderPercent")
        precondition(Settings(defaults: defaults).gameRenderPercent == 100)
        // Command-line UserDefaults overrides are strings and must not require persisted writes.
        let persistedBeforeArguments = defaults.persistentDomain(forName: suite)!
        defaults.setVolatileDomain(["gameRenderPercent": "80", "gameSharpness": "0.6"], forName: UserDefaults.argumentDomain)
        let arguments = Settings(defaults: defaults)
        precondition(arguments.gameRenderPercent == 80 && arguments.gameSharpness == 0.6)
        precondition(NSDictionary(dictionary: persistedBeforeArguments).isEqual(to: defaults.persistentDomain(forName: suite)!))
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        print("PASS: 100% unprocessed defaults, independent FSR/RCAS switches, persisted ranges and five-percent steps, finite sharpness, one notification per change, existing preferences retained")
    }
}
