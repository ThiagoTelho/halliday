// GameLibrary's provider consent and real OpenVR registration status, without app/Rust linkage.
// --sample-games keeps refreshes entirely inside this fixture; defaults are held only in memory.
import Foundation

final class FixtureDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
}

@MainActor
enum GameBridge {
    nonisolated static let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HALLIDAY_LIBRARY_FIXTURE_ROOT"]!)
        .appendingPathComponent("Runtime/OpenVR")
    nonisolated static func windowsPath(_ url: URL) -> String { OpenVRRegistration.windowsPath(url) }
    static func installRuntime() -> Bool { true }
    static func install(prefix: URL, runtime: URL? = nil) throws -> [URL] { try OpenVRRegistration.install(prefix: prefix, runtime: runtime ?? folder) }
    static func uninstall(prefix: URL) throws { try OpenVRRegistration.uninstall(prefix: prefix, runtime: folder) }
}

enum QuestApps {
    struct App { var package: String; var name: String; var engine: String; var canStart: Bool }
    static func installed() -> [App] { [] }
}

func log(_ message: String) { }

@main
@MainActor
struct GameLibraryTests {
    enum Failure: Error { case check(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.check(message) }
    }

    static func main() throws {
        try require(CommandLine.arguments.contains("--sample-games"), "fixture refresh must not inspect live libraries")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HALLIDAY_LIBRARY_FIXTURE_ROOT"]!)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = root.appendingPathComponent("Bottle")
        let users = prefix.appendingPathComponent("drive_c/users")
        for name in ["crossover", "PUBLIC", "All Users", ".hidden"] {
            try fm.createDirectory(at: users.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("not a profile".utf8).write(to: users.appendingPathComponent("desktop.ini"))
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try Data().write(to: prefix.appendingPathComponent("cxbottle.conf"))
        try Data().write(to: prefix.appendingPathComponent("system.reg"))
        let executable = prefix.appendingPathComponent("drive_c/Game.exe")
        try Data("fixture game".utf8).write(to: executable)

        try require(GameLibrary.status(container: prefix, setUp: []) == .notSetUp, "fresh bottle is not ready")
        let installed = try OpenVRRegistration.install(prefix: prefix, runtime: GameBridge.folder)
        try require(installed.count == 1, "only the real Windows profile is registered")
        try require(GameLibrary.status(container: prefix, setUp: []) == .ready,
                    "shared profiles and ordinary files must not make successful setup look changed")
        try require(GameLibrary.status(container: prefix, setUp: [], requiresOpenXR: true) == .notSetUp,
                    "OpenVR alone cannot claim readiness when Windows OpenXR integration is enabled")
        let automaticRoot = OpenVRRegistration.automaticRuntimeRoot(prefix: prefix, baseRuntime: GameBridge.folder)
        _ = try OpenVRRegistration.install(prefix: prefix, runtime: automaticRoot)
        try require(GameLibrary.status(container: prefix, setUp: []) == .ready,
                    "automatic OpenVR root is recognized as our managed runtime")
        try OpenVRRegistration.uninstall(prefix: prefix, runtime: GameBridge.folder)
        try require(GameLibrary.status(container: prefix, setUp: []) == .notSetUp, "undo returns a fresh bottle to its original status")

        let defaults = FixtureDefaults(suiteName: "HallidayInMemoryFixture")!
        let library = GameLibrary(defaults: defaults)
        let imported = CrossOverLibrary.manualGame(executable: executable, bottle: prefix)!
        let crossOver = GameEntry(appID: "manual", name: "Game", executables: ["Game.exe"], container: prefix,
                                  status: .notSetUp, crossOver: imported)
        try require(library.setUp(crossOver), "explicit CrossOver setup succeeds")
        try require(!library.consented, "CrossOver setup must not authorize automatic GameHub setup")
        let gameHub = GameEntry(appID: "42", name: "GameHub Game", executables: ["Game.exe"], container: prefix, status: .notSetUp)
        try require(library.setUp(gameHub), "explicit GameHub setup succeeds")
        try require(library.consented, "GameHub's existing consent behavior remains intact")
        try require(library.undo(crossOver), "fixture bottle settings restored")
        print("Game library fixtures passed: installer/status profile parity and provider-specific setup consent")
    }
}
