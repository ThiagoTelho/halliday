// Halliday's settings (ROADMAP W11 B.5, D.1), kept in UserDefaults between runs.

import Foundation

@MainActor
final class Settings {
    static let shared = Settings(defaults: .standard)
    private let defaults: UserDefaults
    /// Called after any setting changes.
    var onChange: (() -> Void)?

    /// How the space behaves around the user.
    enum Mode: String, CaseIterable {
        /// Stationary: panels and dock are arranged around where the user is; recentering brings
        /// everything back in front. The default.
        case seated
        /// Panels stay where they are in the room and the user moves among them.
        case roomScale

        var label: String { self == .seated ? "Seated" : "Room-scale" }
    }

    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: "mode"); onChange?() }
    }

    /// Distance of the arc of panels from the user, in meters.
    static let panelDistanceRange: ClosedRange<Float> = 0.8...3.0
    var panelDistance: Float {
        didSet { defaults.set(panelDistance, forKey: "panelDistance"); onChange?() }
    }

    /// How much the environment is dimmed around the panels (0 none … 0.9).
    static let dimmingRange: ClosedRange<Float> = 0...0.9
    var dimming: Float {
        didSet { defaults.set(dimming, forKey: "dimming"); onChange?() }
    }

    /// Mouse pointer speed in VR (1 = as built; 0.4 … 2.5).
    static let pointerSpeedRange: ClosedRange<Float> = 0.4...2.5
    var pointerSpeed: Float {
        didSet { defaults.set(pointerSpeed, forKey: "pointerSpeed"); onChange?() }
    }

    /// Pages see an Apple Vision Pro (WebXR sites offer their VR features) or a plain Mac.
    var visionIdentity: Bool {
        didSet { defaults.set(visionIdentity, forKey: "visionIdentity"); onChange?() }
    }

    /// The browser's home page; empty for Halliday's start page (bookmarks and recent pages).
    var homePage: String {
        didSet { defaults.set(homePage, forKey: "homePage"); onChange?() }
    }

    /// The virtual keyboard opens by itself when a Halliday text field is focused.
    var keyboardAuto: Bool {
        didSet { defaults.set(keyboardAuto, forKey: "keyboardAuto"); onChange?() }
    }

    /// The place the user stands in (see Environments).
    var environment: String {
        didSet { defaults.set(environment, forKey: "environment"); onChange?() }
    }

    /// Reduce motion: panels fade without growing, and nothing glides from place to place.
    var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: "reduceMotion"); onChange?() }
    }

    /// Volume of the interface sounds (0 off … 1).
    var soundVolume: Float {
        didSet { defaults.set(soundVolume, forKey: "soundVolume"); onChange?() }
    }

    /// Halliday's master volume (0 … 1, half until the user sets it): videos, Quest apps and
    /// the interface sounds all play at it. It is Halliday's own, so it also works on outputs
    /// the Mac can't turn down (the headset's sound over DisplayPort plays at full); there the
    /// Mac's volume keys change it.
    var volume: Float {
        didSet { defaults.set(volume, forKey: "volume"); onChange?() }
    }

    /// The headset's panel brightness (0.1 … 1, full until the user sets it): the headset's own
    /// command, as Monado and GAV send it.
    static let brightnessRange: ClosedRange<Float> = 0.1...1
    var brightness: Float {
        didSet { defaults.set(brightness, forKey: "brightness"); onChange?() }
    }

    /// Pixels across one eye for WebXR pages (the render size they are offered; a page may ask
    /// for more or less). Larger is sharper and costs the page more.
    static let vrPageSizes = [1080, 1440, 1800, 2160]
    var vrPageEye: Int {
        didSet { defaults.set(vrPageEye, forKey: "vrPageEye"); onChange?() }
    }

    /// FSR 1 processes game frames before the headset's lens correction.
    var gameFSREnabled: Bool {
        didSet { defaults.set(gameFSREnabled, forKey: "gameFSREnabled"); onChange?() }
    }

    /// RCAS sharpening is independent of FSR upscaling and is off by default.
    var gameSharpeningEnabled: Bool {
        didSet { defaults.set(gameSharpeningEnabled, forKey: "gameSharpeningEnabled"); onChange?() }
    }

    /// Percentage of the full game image rendered by the game, in five-percent steps.
    static let gameRenderPercentRange = 50...100
    var gameRenderPercent: Int {
        didSet {
            gameRenderPercent = Self.validGameRenderPercent(gameRenderPercent)
            defaults.set(gameRenderPercent, forKey: "gameRenderPercent")
            onChange?()
        }
    }

    static let gameSharpnessRange: ClosedRange<Float> = 0...1
    var gameSharpness: Float {
        didSet {
            gameSharpness = Self.validGameSharpness(gameSharpness)
            defaults.set(gameSharpness, forKey: "gameSharpness")
            onChange?()
        }
    }

    static func validGameRenderPercent(_ percent: Int) -> Int {
        let bounded = min(max(percent, gameRenderPercentRange.lowerBound), gameRenderPercentRange.upperBound)
        return Int((Double(bounded) / 5).rounded()) * 5
    }

    static func validGameSharpness(_ sharpness: Float) -> Float {
        sharpness.isFinite ? min(max(sharpness, 0), 1) : 0.3
    }

    /// The Windows panel's layout is remembered for each set of apps open together.
    var rememberLayouts: Bool {
        didSet { defaults.set(rememberLayouts, forKey: "rememberLayouts"); onChange?() }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        gameFSREnabled = defaults.bool(forKey: "gameFSREnabled")
        gameSharpeningEnabled = defaults.bool(forKey: "gameSharpeningEnabled")
        let renderPercent = defaults.object(forKey: "gameRenderPercent")
        gameRenderPercent = Self.validGameRenderPercent((renderPercent as? Int) ?? (renderPercent as? String).flatMap(Int.init) ?? 100)
        let sharpness = defaults.object(forKey: "gameSharpness")
        gameSharpness = Self.validGameSharpness((sharpness as? Float) ?? (sharpness as? String).flatMap(Float.init) ?? 0.3)
        rememberLayouts = defaults.object(forKey: "rememberLayouts") as? Bool ?? true
        vrPageEye = Self.vrPageSizes.contains(defaults.integer(forKey: "vrPageEye")) ? defaults.integer(forKey: "vrPageEye") : 1440
        reduceMotion = defaults.bool(forKey: "reduceMotion")
        brightness = min(max(defaults.object(forKey: "brightness") as? Float ?? 1, Self.brightnessRange.lowerBound), 1)
        volume = min(max(defaults.object(forKey: "volume") as? Float ?? 0.5, 0), 1)
        soundVolume = min(max(defaults.object(forKey: "soundVolume") as? Float ?? 0.5, 0), 1)
        environment = defaults.string(forKey: "environment") ?? "dusk"
        pointerSpeed = min(max(defaults.object(forKey: "pointerSpeed") as? Float ?? 1, Self.pointerSpeedRange.lowerBound), Self.pointerSpeedRange.upperBound)
        visionIdentity = defaults.object(forKey: "visionIdentity") as? Bool ?? !CommandLine.arguments.contains("--desktop-identity")
        homePage = defaults.string(forKey: "homePage") ?? ""
        keyboardAuto = defaults.bool(forKey: "keyboardAuto")
        mode = defaults.string(forKey: "mode").flatMap(Mode.init(rawValue:)) ?? .seated
        let d = defaults.object(forKey: "panelDistance") as? Float ?? 1.4
        panelDistance = min(max(d, Self.panelDistanceRange.lowerBound), Self.panelDistanceRange.upperBound)
        dimming = min(max(defaults.object(forKey: "dimming") as? Float ?? 0, 0), Self.dimmingRange.upperBound)
    }
}
