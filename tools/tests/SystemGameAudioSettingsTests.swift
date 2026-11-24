import Foundation

@main struct SystemGameAudioSettingsTests {
    @MainActor static func main() {
        let suite = "app.halliday.tests.game-audio.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = Settings(defaults: defaults)
        precondition(fresh.gameSystemAudio && fresh.volume == 0.5)
        precondition(defaults.persistentDomain(forName: suite) == nil, "Reading defaults must not persist them")
        defaults.set(Float(0.7), forKey: "volume")
        defaults.set(Float(0.2), forKey: "soundVolume")
        defaults.set("roomScale", forKey: "mode")
        defaults.set(90, forKey: "headsetRefreshHz")
        defaults.set(true, forKey: "gameFSREnabled")
        let before = defaults.persistentDomain(forName: suite)!
        let settings = Settings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.gameSystemAudio = false
        precondition(changes == 1 && defaults.object(forKey: "gameSystemAudio") as? Bool == false)
        precondition(!Settings(defaults: defaults).gameSystemAudio)
        settings.gameSystemAudio = true
        precondition(changes == 2 && Settings(defaults: defaults).gameSystemAudio)
        precondition(settings.volume == 0.7 && settings.soundVolume == 0.2)
        for (key, value) in before {
            precondition(NSDictionary(dictionary: [key: value]).isEqual(to: [key: defaults.object(forKey: key)!]),
                         "Audio toggle changed unrelated preference: \(key)")
        }
        let all = defaults.persistentDomain(forName: suite)!
        precondition(Set(all.keys) == Set(before.keys).union(["gameSystemAudio"]))
        print("PASS: audio default, persisted on/off, one settings notification, original volume/output-independent preferences preserved")
    }
}
