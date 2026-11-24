import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation(); throw TestFailure("unsafe launch preparation was accepted") }
    catch is NativeAlyxFailure { }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-native-alyx-\(UUID().uuidString)")
    var home: URL { root.appendingPathComponent("Home ' $(literal) Ω") }
    var workspace: URL { root.appendingPathComponent("Private launch ' $(literal)") }
    var runtime: URL { root.appendingPathComponent("Runtime ' Ω/libhalliday_openxr.dylib") }
    var bridge: URL { root.appendingPathComponent("Runtime ' Ω/halliday-native-alyx-bridge") }
    var output: URL { root.appendingPathComponent("output") }
    init() throws {
        try write("native runtime fixture, never loaded", to: runtime)
        try write("#!/bin/bash\nexec \"$HALLIDAY_ALYX_ORIGINAL_BRIDGE\" \"$@\"\n", to: bridge, executable: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }
    func install(_ kind: NativeAlyxKind, at folder: URL? = nil, legacy: Bool = false) throws -> NativeAlyxInstallation {
        let folder = folder ?? home.appendingPathComponent(kind == .inversa ? "Games/Inversa-Alyx" : "Verantyx_VR_Drive/alyx_linux")
        switch kind {
        case .inversa:
            for path in ["Inversa/inversa-native", "Inversa/openvr/bin/linuxarm64/vrclient.so", "alyx/game/bin/linuxsteamrtarm64/hlvr", "moltenvk/libMoltenVK.dylib"] {
                try write("fixture, never executed", to: folder.appendingPathComponent(path), executable: true)
            }
            try write("#!/bin/bash\nprintf 'fixture output\\n'\nprintf 'fixture error\\n' >&2\n",
                      to: folder.appendingPathComponent("Inversa/inversa-native"), executable: true)
            let script = #"""
            #!/bin/bash
            set -euo pipefail
            base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            runtime="$base/Inversa"
            export KL_MVK_DIR="$base/moltenvk"
            export MVR_OPENXR_RUNTIME="$HOME/Library/Application Support/MoltenVR/bin/libmoltenvr_openxr.dylib"
            printf '%s\0' "$base" "$MVR_OPENXR_RUNTIME" "$KL_MVK_DIR" "$KEEP_SETTING" "$@" > "$HALLIDAY_TEST_OUTPUT"
            exec "$runtime/inversa-native" >/dev/null 2>&1

            """#
            try write(script, to: folder.appendingPathComponent("start.command"))
        case .verantyx:
            let gamePath = legacy ? "game/bin/linuxsteamrtarm64/hlvr" : "verantyx/native-game/game/bin/linuxsteamrtarm64/hlvr"
            for path in ["verantyx/alyx_host", gamePath] {
                try write("fixture, never executed", to: folder.appendingPathComponent(path), executable: true)
            }
            try write(#"""
            #!/bin/bash
            printf '%s\0' "$HALLIDAY_NATIVE_ALYX_ROOT" "$MVR_OPENXR_RUNTIME" "$VERANTYX_ARCHIVE" "$KEEP_SETTING" "$VERANTYX_DISPLAY_HZ" "$VB_FPS" "$@" > "$HALLIDAY_TEST_OUTPUT"

            """#, to: folder.appendingPathComponent("verantyx/bridge"), executable: true)
            try write(#"""
            import os,subprocess,sys
            env={**os.environ,'ALYX_SESSION_LOCKED':'1'}
            raise SystemExit(subprocess.call(['/bin/bash',*sys.argv[1:]],env=env))

            """#, to: folder.appendingPathComponent("verantyx/preparation/session_runner.py"))
            let rootLine = legacy ? #"game="$(cd "$(dirname "$0")" && pwd)""# : #"install="$(cd "$(dirname "$0")" && pwd)""#
            let baseLine = legacy ? #"base="$game/verantyx""# : #"base="$install/verantyx""#
            let script = "#!/bin/bash\nset -euo pipefail\n" + rootLine + "\n" + baseLine + "\n" + #"""
            test="$base/preparation"
            if [[ "${ALYX_SESSION_LOCKED:-0}" != 1 ]]; then
             exec /usr/bin/python3 "$test/session_runner.py" "$0" "$@"
            fi
            export VERANTYX_ARCHIVE="$test/cache/native.bin"
            export VERANTYX_DISPLAY_HZ=72
            export VB_FPS=72
            "$base/bridge" "$@"

            """#
            try write(script, to: folder.appendingPathComponent("start.command"))
        }
        guard let result = NativeAlyxSupport.installation(at: folder) else { throw TestFailure("fixture not recognized") }
        return result
    }
    func prepare(_ installation: NativeAlyxInstallation, arguments: [String] = []) throws -> NativeAlyxLaunchCommand {
        try NativeAlyxSupport.prepare(installation: installation, runtime: runtime, workspace: workspace,
                                     bridgeOverride: bridge, arguments: arguments,
                                     inheritedEnvironment: ["PATH": "/usr/bin:/bin", "KEEP_SETTING": "original user setting",
                                                            "HALLIDAY_TEST_OUTPUT": output.path])
    }
    func run(_ command: NativeAlyxLaunchCommand, requiringQuiet: Bool = false) throws -> [String] {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.workingDirectory
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run(); process.waitUntilExit()
        let outputBytes = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorBytes = stderr.fileHandleForReading.readDataToEndOfFile()
        try check(process.terminationStatus == 0, "safe fixture launcher failed: \(process.terminationStatus): \(String(decoding: errorBytes, as: UTF8.self))")
        if requiringQuiet {
            try check(outputBytes.isEmpty && errorBytes.isEmpty, "quiet fixture leaked stdout/stderr")
        }
        return try Data(contentsOf: output).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}

@main private struct NativeAlyxTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("discovers two engines and deduplicates canonical aliases", {
                let f = try Fixture(), a = try f.install(.inversa), b = try f.install(.verantyx)
                let alias = f.root.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a.root)
                let found = NativeAlyxSupport.discover(home: f.home, additionalRoots: [alias, b.root])
                try check(Set(found.map(\.id)) == Set([a.id, b.id]), "missing or duplicated native install")
            }),
            ("uses external Steam VDF library and suppresses only its explicit old depot", {
                let f = try Fixture(), old = try f.install(.verantyx), _ = try f.install(.inversa)
                let library = f.root.appendingPathComponent("External library")
                let upgraded = try f.install(.verantyx, at: library.appendingPathComponent("steamapps/common/Alyx custom"))
                try f.write("\"libraryfolders\" { \"1\" { \"path\" \"\(library.path)\" } }", to: f.home.appendingPathComponent("Library/Application Support/Steam/steamapps/libraryfolders.vdf"))
                try f.write("\"AppState\" { \"installdir\" \"Alyx custom\" }", to: library.appendingPathComponent("steamapps/appmanifest_546560.acf"))
                let data = try JSONSerialization.data(withJSONObject: ["depot": old.root.path])
                try data.write(to: upgraded.root.appendingPathComponent("verantyx/moltenvr-install.json"))
                let found = NativeAlyxSupport.discover(home: f.home)
                try check(found.count == 2 && found.contains(upgraded) && !found.contains(old), "upgraded receipt did not suppress only the legacy duplicate")
            }),
            ("Inversa preserves root, settings and literal arguments while selecting only runtime", {
                let f = try Fixture(), game = try f.install(.inversa)
                let before = try Data(contentsOf: game.launcher)
                let arguments = ["+map", "save ' Ω $(never-run) `literal`", "line\nargument"]
                let command = try f.prepare(game, arguments: arguments)
                defer { command.removePreparedScript() }
                let values = try f.run(command, requiringQuiet: true)
                try check(values == [game.root.path, f.runtime.path, game.root.appendingPathComponent("moltenvk").path, "original user setting"] + arguments, "settings/arguments changed or shell evaluated")
                try check(try Data(contentsOf: game.launcher) == before, "original launcher modified")
                try check(try String(contentsOf: command.scriptURL, encoding: .utf8).contains(#">"${HALLIDAY_NATIVE_ALYX_LOG:-/dev/null}" 2>&1"#), "default quiet redirect was not retained")
            }),
            ("Inversa optional log preserves literal quoted paths and captures both output streams", {
                let f = try Fixture(), game = try f.install(.inversa)
                let log = f.root.appendingPathComponent("launch ' Ω $(literal) `never-run`.log")
                let command = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: f.workspace,
                    inheritedEnvironment: ["PATH": "/usr/bin:/bin", "KEEP_SETTING": "setting",
                        "HALLIDAY_TEST_OUTPUT": f.output.path, "HALLIDAY_NATIVE_ALYX_LOG": log.path])
                defer { command.removePreparedScript() }
                _ = try f.run(command, requiringQuiet: true)
                try check(try String(contentsOf: log, encoding: .utf8) == "fixture output\nfixture error\n", "optional log did not capture stdout/stderr literally")
                try check(try String(contentsOf: game.launcher, encoding: .utf8).contains(" >/dev/null 2>&1\n"), "original log redirection changed")
            }),
            ("VeRantyx locked reentry preserves original roots, shader settings and bridge", {
                for legacy in [false, true] {
                    let f = try Fixture(), game = try f.install(.verantyx, legacy: legacy)
                    let before = try Data(contentsOf: game.launcher)
                    let originalBridge = game.root.appendingPathComponent("verantyx/bridge")
                    let bridgeBefore = try Data(contentsOf: originalBridge)
                    let args = ["+vr_fidelity_level", "3", "save ' $(literal)"]
                    let command = try f.prepare(game, arguments: args)
                    defer { command.removePreparedScript() }
                    let values = try f.run(command)
                    try check(values == [game.root.path, f.runtime.path, game.root.appendingPathComponent("verantyx/preparation/cache/native.bin").path, "original user setting", "72", "72"] + args, "lock reentry changed install/cache/root/arguments")
                    try check(command.environment["HALLIDAY_ALYX_ORIGINAL_BRIDGE"] == originalBridge.path, "original bridge not supplied to wrapper")
                    try check(try Data(contentsOf: game.launcher) == before, "original launcher modified")
                    try check(try Data(contentsOf: originalBridge) == bridgeBefore, "original bridge modified")
                }
            }),
            ("VeRantyx uses selected host refresh without changing original launcher", {
                let f = try Fixture(), game = try f.install(.verantyx)
                let command = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: f.workspace,
                    bridgeOverride: f.bridge, inheritedEnvironment: ["PATH": "/usr/bin:/bin", "KEEP_SETTING": "setting",
                        "HALLIDAY_DISPLAY_HZ": "120", "HALLIDAY_TEST_OUTPUT": f.output.path])
                defer { command.removePreparedScript() }
                let values = try f.run(command)
                try check(Array(values.suffix(2)) == ["120", "120"], "selected host refresh was ignored")
                try check(try String(contentsOf: game.launcher, encoding: .utf8).contains("export VERANTYX_DISPLAY_HZ=72\n"), "original refresh changed")
            }),
            ("VeRantyx gates its locked bridge before launch and fixes only its Steam app context", {
                let f = try Fixture(), game = try f.install(.verantyx)
                let before = try Data(contentsOf: game.launcher)
                let helper = f.root.appendingPathComponent("Probe ' $(literal)/ready helper")
                let observed = f.root.appendingPathComponent("Steam gate result")
                try f.write(#"""
                #!/bin/sh
                printf '%s\n' "$SteamAppId" "$SteamGameId" "$@" >> "$HALLIDAY_TEST_STEAM_RESULT"
                """#, to: helper, executable: true)
                let command = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: f.workspace,
                    bridgeOverride: f.bridge, steamReadinessProbe: helper,
                    inheritedEnvironment: ["PATH": "/usr/bin:/bin", "HOME": f.home.path, "KEEP_SETTING": "setting",
                        "SteamAppId": "999", "SteamGameId": "888", "HALLIDAY_TEST_OUTPUT": f.output.path,
                        "HALLIDAY_TEST_STEAM_RESULT": observed.path, "HALLIDAY_NATIVE_ALYX_OWNER_PID": "123"])
                defer { command.removePreparedScript() }
                _ = try f.run(command)
                let observations = try String(contentsOf: observed, encoding: .utf8).components(separatedBy: "\n")
                try check(observations == ["546560", "546560", "--library",
                    f.home.path + "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib",
                    "--owner-pid", "123", ""], "Steam gate ran more than once or changed literal paths/app context")
                try check(try Data(contentsOf: game.launcher) == before, "Steam gate modified the user's original launcher")
            }),
            ("VeRantyx readiness failure prevents all bridge and game entry points", {
                let f = try Fixture(), game = try f.install(.verantyx)
                let helper = f.root.appendingPathComponent("unready helper")
                try f.write("#!/bin/sh\nexit 70\n", to: helper, executable: true)
                let command = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: f.workspace,
                    bridgeOverride: f.bridge, steamReadinessProbe: helper,
                    inheritedEnvironment: ["PATH": "/usr/bin:/bin", "HALLIDAY_TEST_OUTPUT": f.output.path])
                defer { command.removePreparedScript() }
                let child = Process(); child.executableURL = command.executable; child.arguments = command.arguments
                child.environment = command.environment; child.currentDirectoryURL = command.workingDirectory
                child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                try child.run(); child.waitUntilExit()
                try check(child.terminationStatus == 70 && !FileManager.default.fileExists(atPath: f.output.path),
                    "bridge/game started despite unavailable Steam")
            }),
            ("VeRantyx rejects missing probe and invalid readiness owner before creating a runnable script", {
                let f = try Fixture(), game = try f.install(.verantyx)
                try rejects { _ = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: f.workspace,
                    bridgeOverride: f.bridge, steamReadinessProbe: f.root.appendingPathComponent("missing")) }
                let helper=f.root.appendingPathComponent("ready helper")
                try f.write("#!/bin/sh\nexit 0\n",to:helper,executable:true)
                try rejects { _ = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: f.workspace,
                    bridgeOverride: f.bridge, steamReadinessProbe: helper,
                    inheritedEnvironment: ["HALLIDAY_NATIVE_ALYX_OWNER_PID": "123;literal"]) }
            }),
            ("VeRantyx keeps bounded raw bridge errors in private workspace", {
                let f = try Fixture(), game = try f.install(.verantyx)
                let loggerInvocation = #"/usr/bin/python3 "$test/bridge_log.py" "$test/bridge-startup.log""#
                let text = try String(contentsOf: game.launcher, encoding: .utf8)
                try f.write(text.replacingOccurrences(of: #""$base/bridge" "$@""#,
                    with: #""$base/bridge" "$@" > >( "# + loggerInvocation + " ) 2>&1"), to: game.launcher)
                let before = try Data(contentsOf: game.launcher)
                let originalLogger = game.root.appendingPathComponent("verantyx/preparation/bridge_log.py")
                try f.write("original keyword filter, never executed", to: originalLogger)
                let command = try f.prepare(game)
                defer { command.removePreparedScript() }
                let helper = command.scriptURL.deletingLastPathComponent().appendingPathComponent("bridge-log.py")
                let output = f.workspace.appendingPathComponent("bridge-startup.log")
                try check(command.environment["HALLIDAY_NATIVE_ALYX_BRIDGE_LOG"] == output.path, "private error log missing")
                try check(!String(contentsOf: command.scriptURL, encoding: .utf8).contains(loggerInvocation), "lossy port logger still selected")
                _ = try f.run(command, requiringQuiet: true)
                let process = Process(), input = Pipe(), printed = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [helper.path, output.path]
                process.standardInput = input; process.standardOutput = printed
                try process.run()
                let noise = String(repeating: "initialization context\n", count: 1000)
                let failure = "create Vulkan instance via runtime: -2\ncreate Vulkan device: VkResult -9\n"
                try input.fileHandleForWriting.write(contentsOf: Data((noise + failure).utf8))
                try input.fileHandleForWriting.close()
                process.waitUntilExit()
                try check(process.terminationStatus == 0, "private bridge logger failed")
                let raw = try Data(contentsOf: output)
                try check(raw.count <= 16384 && String(decoding: raw, as: UTF8.self).hasSuffix(failure), "raw numeric API errors lost or log unbounded")
                let forwarded = String(decoding: printed.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                try check(forwarded.contains("Native bridge: create Vulkan instance via runtime: -2") &&
                          forwarded.contains("Native bridge: create Vulkan device: VkResult -9"), "launch log did not receive exact API failures")
                try check(try Data(contentsOf: game.launcher) == before, "user launcher changed")
                try check(try String(contentsOf: originalLogger, encoding: .utf8) == "original keyword filter, never executed", "user logger changed")
            }),
            ("rejects changed and ambiguous launcher forms before writing private scripts", {
                let f = try Fixture(), game = try f.install(.inversa)
                try f.write("#!/bin/bash\nunknown launch form\n", to: game.launcher)
                try rejects { _ = try f.prepare(game) }
                try check(!FileManager.default.fileExists(atPath: f.workspace.path), "failed adaptation wrote files")
                _ = try f.install(.inversa)
                let text = try String(contentsOf: game.launcher, encoding: .utf8)
                try f.write(text + #"base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)""# + "\n", to: game.launcher)
                try rejects { _ = try f.prepare(game) }
            }),
            ("rejects missing runtimes, unsafe workspace and missing/original bridge override", {
                let f = try Fixture(), game = try f.install(.verantyx)
                try rejects { _ = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: game.root, bridgeOverride: f.bridge) }
                try rejects { _ = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: f.workspace) }
                try rejects { _ = try NativeAlyxSupport.prepare(installation: game, runtime: f.runtime, workspace: f.workspace, bridgeOverride: game.root.appendingPathComponent("verantyx/bridge")) }
                try FileManager.default.removeItem(at: f.runtime)
                try rejects { _ = try f.prepare(game) }
            }),
            ("incomplete Windows-only Alyx is not reported as a native installation", {
                let f = try Fixture(), folder = f.root.appendingPathComponent("Windows Alyx")
                try f.write("PE placeholder", to: folder.appendingPathComponent("game/bin/win64/hlvr.exe"))
                try f.write("#!/bin/bash\n", to: folder.appendingPathComponent("start.command"))
                try check(NativeAlyxSupport.installation(at: folder) == nil, "Windows Alyx incorrectly marked native")
            })
        ]
        var failures = 0
        for (name, run) in tests {
            do { try run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) native Alyx launcher tests passed")
        if failures != 0 { exit(1) }
    }
}
