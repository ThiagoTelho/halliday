import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation(); throw CheckFailure("invalid command was accepted") }
    catch is LaunchFailure { }
}

private final class Fixture {
    let root: URL
    let installation: CrossOverInstallation
    let bottle: URL
    let steam: URL
    init(appName: String = "CrossOver Preview.app") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-launcher-\(UUID().uuidString)")
        installation = .init(applicationURL: root.appendingPathComponent(appName))
        bottle = root.appendingPathComponent("Bottle $(never-run) `literal`")
        steam = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try FileManager.default.createDirectory(at: installation.wineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("wrapper fixture, never executed".utf8).write(to: installation.wineURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installation.wineURL.path)
        try Data("PE fixture, never executed".utf8).write(to: steam)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func game(id: String = "2468", executable: URL? = nil, steamExecutable: URL? = nil) -> CrossOverGame {
        .init(appID: id, name: "Fixture", folder: root, bottle: bottle, steamExecutable: steamExecutable ?? steam,
              fullyInstalled: true, manifestVersion: "fixture", executable: executable)
    }
    func command(id: String = "2468", executable: URL? = nil, steamExecutable: URL? = nil) throws -> CrossOverLaunchCommand {
        try .steam(installation: installation, game: game(id: id, executable: executable, steamExecutable: steamExecutable))
    }
    func write(_ text: String, path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
    }

}

@main
private struct LauncherTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("keeps Steam arguments separate and preserves literal path characters", {
                let f = try Fixture(), command = try f.command()
                try check(command.executable == f.installation.wineURL, "wrong CrossOver wrapper")
                try check(command.arguments == ["--bottle", f.bottle.path, "--no-update", "--no-convert", "--start", #"C:\Program Files (x86)\Steam\steam.exe"#, "steam://launch/2468/vr"], "arguments were quoted, split, or rewritten")
                try check(command.workingDirectory == f.steam.deletingLastPathComponent(), "wrong working directory")
            }),
            ("preserves a numeric Steam AppID literally instead of converting it to a game path", {
                let f = try Fixture(), command = try f.command(id: "1196590")
                try check(command.arguments.contains("--no-convert"), "wrapper path conversion is still enabled")
                try check(command.arguments.last == "steam://launch/1196590/vr", "numeric AppID was rewritten")
                try check(command.arguments[5] == #"C:\Program Files (x86)\Steam\steam.exe"#, "Steam target is not a Windows path")
            }),
            ("resolves a custom Steam installation through the bottle's drive mapping", {
                let f = try Fixture(), disk = f.root.appendingPathComponent("External disk")
                let steam = disk.appendingPathComponent("Clients/Steam 測試/steam.exe")
                try f.write("PE fixture", path: steam)
                let mappings = f.bottle.appendingPathComponent("dosdevices")
                try FileManager.default.createDirectory(at: mappings, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: mappings.appendingPathComponent("d:"), withDestinationURL: disk)
                let command = try f.command(steamExecutable: steam)
                try check(command.arguments[5] == #"D:\Clients\Steam 測試\steam.exe"#, "custom Steam mapping was lost")
                try check(Array(command.arguments.suffix(1)) == ["steam://launch/2468/vr"], "custom Steam game arguments changed")
                try check(command.workingDirectory == steam.deletingLastPathComponent(), "custom Steam working directory changed")
            }),
            ("uses the most specific mapped drive and supports an existing Z root mapping", {
                let f = try Fixture(), disk = f.root.appendingPathComponent("Mapped disk")
                let clients = disk.appendingPathComponent("Clients")
                let steam = clients.appendingPathComponent("Steam/steam.exe")
                try f.write("PE fixture", path: steam)
                let mappings = f.bottle.appendingPathComponent("dosdevices")
                try FileManager.default.createDirectory(at: mappings, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: mappings.appendingPathComponent("a:"), withDestinationURL: disk)
                try FileManager.default.createSymbolicLink(at: mappings.appendingPathComponent("d:"), withDestinationURL: clients)
                try FileManager.default.createSymbolicLink(at: mappings.appendingPathComponent("z:"), withDestinationURL: URL(fileURLWithPath: "/"))
                let specific = try f.command(steamExecutable: steam)
                try check(specific.arguments[5] == #"D:\Steam\steam.exe"#, "a broad drive hid a specific mapping")
                let other = f.root.appendingPathComponent("Unmapped/Steam/steam.exe")
                try f.write("PE fixture", path: other)
                let expected = "Z:" + other.resolvingSymlinksInPath().path.replacingOccurrences(of: "/", with: #"\"#)
                let fallback = try f.command(steamExecutable: other)
                try check(fallback.arguments[5] == expected, "existing Z mapping was not used")
            }),
            ("rejects unmapped Steam and does not confuse a drive_c pathname prefix with containment", {
                let f = try Fixture(), steam = f.bottle.appendingPathComponent("drive_c-foreign/Steam/steam.exe")
                try f.write("PE fixture", path: steam)
                try rejects { _ = try f.command(steamExecutable: steam) }
            }),
            ("requests Steam VR selection generically and leaves existing launch options to Steam", {
                let f = try Fixture()
                let options = f.steam.deletingLastPathComponent().appendingPathComponent("userdata/fixture/config/localconfig.vdf")
                let original = Data("existing Steam launch options: custom-setting %command%\n".utf8)
                try f.write(String(decoding: original, as: UTF8.self), path: options)
                for id in ["264710", "1196590", "2468"] {
                    let command = try f.command(id: id)
                    try check(command.arguments.last == "steam://launch/\(id)/vr", "VR selection depends on a game allowlist")
                    try check(!command.arguments.contains("-vrmode") && !command.arguments.contains("none"), "game-specific VR arguments were injected")
                    try check(!command.arguments.contains("--env") && !command.arguments.contains("--dll"), "Steam launch environment or DLL options were replaced")
                }
                let after = try Data(contentsOf: options)
                try check(after == original, "persistent Steam launch settings were rewritten")
            }),
            ("launches a manually selected EXE without Steam arguments", {
                let f = try Fixture()
                let executable = f.root.appendingPathComponent("VR 測試 $(literal).exe")
                try Data("PE fixture".utf8).write(to: executable)
                let command = try f.command(id: "manual", executable: executable)
                try check(command.arguments == ["--bottle", f.bottle.path, "--no-update", "--start", executable.path], "manual game was routed through Steam")
                try check(command.workingDirectory == executable.deletingLastPathComponent(), "manual game has the wrong working directory")
            }),
            ("rejects empty, nonnumeric and Unicode Steam identifiers", {
                let f = try Fixture()
                for id in ["", "-1", "12foo", "١٢٣", "123\n", "1 2"] {
                    try rejects { _ = try f.command(id: id) }
                }
            }),
            ("rejects missing, nonexecutable and directory wrappers", {
                let f = try Fixture()
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.installation.wineURL.path)
                try rejects { _ = try f.command() }
                try FileManager.default.removeItem(at: f.installation.wineURL)
                try rejects { _ = try f.command() }
                try FileManager.default.createDirectory(at: f.installation.wineURL, withIntermediateDirectories: true)
                try rejects { _ = try f.command() }
            }),
            ("rejects missing or directory Steam executables", {
                let f = try Fixture()
                try FileManager.default.removeItem(at: f.steam)
                try rejects { _ = try f.command() }
                try FileManager.default.createDirectory(at: f.steam, withIntermediateDirectories: true)
                try rejects { _ = try f.command() }
            }),
            ("rejects missing or directory manual executables", {
                let f = try Fixture(), missing = f.root.appendingPathComponent("missing.exe")
                try rejects { _ = try f.command(id: "manual", executable: missing) }
                try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
                try rejects { _ = try f.command(id: "manual", executable: missing) }
            }),
            ("rejects a bottle whose drive_c is an ordinary file", {
                let f = try Fixture()
                let drive = f.bottle.appendingPathComponent("drive_c")
                try FileManager.default.removeItem(at: drive)
                try Data("not a directory".utf8).write(to: drive)
                let executable = f.root.appendingPathComponent("manual.exe")
                try Data("PE fixture".utf8).write(to: executable)
                try rejects { _ = try f.command(id: "manual", executable: executable) }
            }),
            ("delegates graphics, version and Auto choices to the native CrossOver launcher", {
                for backend in ["", "auto", "wined3d", "d3dmetal", "dxmt", "dxvk"] {
                    let f = try Fixture()
                    let settings = "[EnvironmentVariables]\n\"CX_GRAPHICS_BACKEND\" = \"\(backend)\"\n\"CX_GRAPHICS_BACKEND_VERSION\" = \"existing-version\"\n\"D3DM_MTL4\" = \"1\"\n"
                    let file = f.bottle.appendingPathComponent("cxbottle.conf")
                    try f.write(settings, path: file)
                    let before = try Data(contentsOf: file)
                    let command = try f.command()
                    try check(command.arguments == ["--bottle", f.bottle.path, "--no-update", "--no-convert", "--start", #"C:\Program Files (x86)\Steam\steam.exe"#, "steam://launch/2468/vr"], "native backend choices were replaced with manual overrides")
                    let after = try Data(contentsOf: file)
                    try check(before == after, "native bottle settings were changed")
                }
            }),
            ("keeps Stable and Preview launch roots independent", {
                for name in ["CrossOver.app", "CrossOver Preview.app"] {
                    let f = try Fixture(appName: name), command = try f.command()
                    try check(command.executable == f.installation.wineURL, "selected application was replaced")
                    try check(command.arguments.contains("--start"), "native compatibility context was bypassed")
                }
            })
        ]
        var failed = 0
        for (name, run) in tests {
            do { try run(); print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failed)/\(tests.count) CrossOver launch-command tests passed")
        if failed != 0 { exit(1) }
    }
}
