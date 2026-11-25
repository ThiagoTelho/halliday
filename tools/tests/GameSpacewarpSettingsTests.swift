import Foundation

@main struct GameSpacewarpSettingsTests {
    static func main() {
        let suite = "app.halliday.tests.spacewarp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(80, forKey: "gameRenderPercent")
        defaults.set(true, forKey: "gameFSREnabled")
        defaults.set(true, forKey: "gameSharpeningEnabled")
        defaults.set(Float(0.65), forKey: "gameSharpness")
        defaults.set(Float(0.7), forKey: "volume")
        let settings = Settings(defaults: defaults)
        precondition(!settings.gameSpacewarpEnabled && !settings.effectiveGameHalfFrameRate)
        settings.setGameSpacewarp(true)
        precondition(settings.gameSpacewarpEnabled && settings.gameHalfFrameRate && settings.effectiveGameHalfFrameRate)
        precondition(defaults.bool(forKey: "gameSpacewarpEnabled") && defaults.bool(forKey: "gameHalfFrameRate"))
        let restored = Settings(defaults: defaults)
        precondition(restored.gameSpacewarpEnabled && restored.effectiveGameHalfFrameRate)
        settings.setGameSpacewarp(false)
        precondition(!settings.gameSpacewarpEnabled && settings.gameHalfFrameRate && settings.effectiveGameHalfFrameRate)
        settings.gameHalfFrameRate = false
        precondition(!settings.effectiveGameHalfFrameRate)
        // Explicit Off remains authoritative while prediction is armed externally.
        defaults.set(true, forKey: "gameSpacewarpEnabled")
        defaults.set(false, forKey: "gameHalfFrameRate")
        let saved = defaults.persistentDomain(forName: suite)!
        let external = Settings(defaults: defaults)
        precondition(external.gameSpacewarpEnabled && !external.gameHalfFrameRate && !external.effectiveGameHalfFrameRate)
        precondition(NSDictionary(dictionary: saved).isEqual(to: defaults.persistentDomain(forName: suite)!))
        external.setGameSpacewarp(false)
        precondition(!external.effectiveGameHalfFrameRate)
        for value in [settings, restored, external] {
            precondition(value.gameRenderPercent == 80 && value.gameFSREnabled && value.gameSharpeningEnabled)
            precondition(value.gameSharpness == 0.65 && value.volume == 0.7)
        }
        // Command-line overrides are read without writes to the persistent profile.
        let persisted = defaults.persistentDomain(forName: suite)!
        defaults.setVolatileDomain(["gameSpacewarpEnabled": "YES", "gameHalfFrameRate": "NO"], forName: UserDefaults.argumentDomain)
        let arguments = Settings(defaults: defaults)
        precondition(arguments.gameSpacewarpEnabled && !arguments.gameHalfFrameRate && !arguments.effectiveGameHalfFrameRate)
        precondition(NSDictionary(dictionary: persisted).isEqual(to: defaults.persistentDomain(forName: suite)!))
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        print("PASS: Spacewarp defaults, live cadence dependency, disable behavior, profile reload, external/argument overrides and unrelated image/audio preferences")
    }
}
