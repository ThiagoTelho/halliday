import Foundation

// The production routing helper takes an explicit root in these tests. No installed support
// folder, app, game, Vulkan loader, Metal device or proprietary library is opened.
enum GameBridge {
    static let folder = URL(fileURLWithPath: "/unused-halliday-test-default")
}
struct LaunchFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation(); throw Failure(message: "invalid route was accepted") }
    catch is LaunchFailure { }
}

private final class Fixture {
    let root: URL
    var resources: URL { root.appendingPathComponent("Candidate.app/Contents/Resources") }
    var host: URL { root.appendingPathComponent("Application Support/Halliday Preview/OpenVR") }
    var source: URL { resources.appendingPathComponent("NativeOpenXR") }
    init(parent: URL) throws {
        root = parent.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func write(_ text: String, _ url: URL) throws { try write(Data(text.utf8), url) }
    static func thin(_ cpu: UInt32) -> Data {
        var data = Data(repeating: 0, count: 32)
        func word(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        word(0xfeedfacf, at: 0); word(cpu, at: 4); word(6, at: 12)
        return data
    }
    static func universal() -> Data {
        var data = Data(repeating: 0, count: 128)
        func word(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> ((3 - i) * 8)) }
        }
        word(0xcafebabe, at: 0); word(2, at: 4)
        for (index, cpu) in [UInt32(0x0100000c), 0x01000007].enumerated() {
            let entry = 8 + index * 20, offset = 64 + index * 32
            word(cpu, at: entry); word(UInt32(offset), at: entry + 8); word(32, at: entry + 12)
            data.replaceSubrange(offset..<(offset + 32), with: thin(cpu))
        }
        return data
    }
    func bundle() throws {
        for name in NativeOpenXRSupport.independentFiles {
            try write(name.hasSuffix(".dylib") ? Self.universal() : Data("#!/bin/bash\nexit 0\n".utf8), source.appendingPathComponent(name))
        }
    }
    func install(_ kind: NativeAlyxKind) throws -> NativeAlyxInstallation {
        let game = root.appendingPathComponent(kind.rawValue + " game ' $(literal)")
        let script: String
        switch kind {
        case .inversa:
            for path in ["Inversa/inversa-native", "Inversa/openvr/bin/linuxarm64/vrclient.so", "alyx/game/bin/linuxsteamrtarm64/hlvr", "moltenvk/libMoltenVK.dylib"] {
                try write("fixture", game.appendingPathComponent(path))
            }
            script = #"""
            #!/bin/bash
            base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            runtime="$base/Inversa"
            export MVR_OPENXR_RUNTIME="$HOME/Library/Application Support/MoltenVR/bin/libmoltenvr_openxr.dylib"
            exec "$runtime/inversa-native" >/dev/null 2>&1

            """#
            try write(Self.environmentProbe, game.appendingPathComponent("Inversa/inversa-native"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: game.appendingPathComponent("Inversa/inversa-native").path)
        case .verantyx:
            for path in ["verantyx/alyx_host", "verantyx/native-game/game/bin/linuxsteamrtarm64/hlvr"] { try write("fixture", game.appendingPathComponent(path)) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: game.appendingPathComponent("verantyx/alyx_host").path)
            try write(Self.environmentProbe, game.appendingPathComponent("verantyx/bridge"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: game.appendingPathComponent("verantyx/bridge").path)
            script = #"""
            #!/bin/bash
            install="$(cd "$(dirname "$0")" && pwd)"
            base="$install/verantyx"
            export VERANTYX_DISPLAY_HZ=72
            export VB_FPS=72
            "$base/bridge" "$@"

            """#
        }
        try write(script, game.appendingPathComponent("start.command"))
        guard let result = NativeAlyxSupport.installation(at: game) else { throw Failure(message: "native fixture not discovered") }
        return result
    }
    static let environmentProbe = #"""
    #!/bin/bash
    printf '%s\0' "$MVR_OPENXR_RUNTIME" "$HALLIDAY_NATIVE_OPENXR_RUNTIME" "$HALLIDAY_BRIDGE" "$HALLIDAY_DISPLAY_HZ" "${HALLIDAY_EYE_SIZE:-unset}" "$KEEP_SETTING" "${VERANTYX_DISPLAY_HZ:-unset}" "${VB_FPS:-unset}" "${HALLIDAY_DISPLAY_HZ_INITIAL:-unset}" > "$TEST_OUTPUT"

    """#
}

@main private struct NativeOpenXRSupportTests {
    @MainActor static func main() throws {
        let raw = try NativeOpenXRSupport.launchEnvironment(["KEEP": "yes"], backend: .halliday, displayHz: 60)
        try check(raw["HALLIDAY_ALYX_TOUCH_RAW_POSE"] == "1" && raw["KEEP"] == "yes",
                  "native raw-device contract defaults on without replacing inherited settings")
        let rollback = try NativeOpenXRSupport.launchEnvironment(
            ["HALLIDAY_ALYX_TOUCH_RAW_POSE": "0"], backend: .halliday, displayHz: 60)
        try check(rollback["HALLIDAY_ALYX_TOUCH_RAW_POSE"] == "0",
                  "explicit native raw-device rollback is preserved")
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "one fixture parent required") }
        let parent = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let f = try Fixture(parent: parent)
        let defaultsName = "app.halliday.tests.native-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        // A separate test suite keeps these assertions away from the user's real app profile.
        // It is removed on completion, including on thrown failure.
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let initial = Settings(defaults: defaults)
        try check(initial.nativeOpenXRBackend == .halliday, "source-built native runtime must be the default")
        defaults.set("existing-place", forKey: "environment")
        let before = defaults.dictionaryRepresentation()
        _ = Settings(defaults: defaults)
        try check(NSDictionary(dictionary: before).isEqual(to: defaults.dictionaryRepresentation()), "settings init rewrote preferences")
        initial.nativeOpenXRBackend = .halliday
        try check(Settings(defaults: defaults).nativeOpenXRBackend == .halliday && defaults.string(forKey: "environment") == "existing-place", "native preference did not persist independently")
        defaults.set("unknown", forKey: "nativeOpenXRBackend")
        try check(Settings(defaults: defaults).nativeOpenXRBackend == .halliday, "unknown backend did not select the source-built default")

        try check(NativeOpenXRSupport.bundledFolder(for: .halliday, resources: f.resources) == nil, "missing module selectable")
        try rejects { try NativeOpenXRSupport.stage(.halliday, resources: f.resources, root: f.host) }
        try check(!FileManager.default.fileExists(atPath: f.host.path), "missing module staging wrote host files")
        try f.bundle()
        try check(NativeOpenXRSupport.bundledFolder(for: .halliday, resources: f.resources) == f.source, "complete independent bundle unavailable")
        try check(NativeOpenXRSupport.architectures(in: Fixture.universal()) == ["arm64", "x86_64"], "universal architecture inspection failed")
        for name in NativeOpenXRSupport.independentFiles where name.hasSuffix(".dylib") {
            try f.write(Fixture.thin(0x0100000c), f.source.appendingPathComponent(name))
            try rejects { try NativeOpenXRSupport.stage(.halliday, resources: f.resources, root: f.host) }
            try check(!FileManager.default.fileExists(atPath: f.host.path), "thin module wrote files before rejection")
            try f.write(Fixture.universal(), f.source.appendingPathComponent(name))
        }
        var malformed = Fixture.universal(); malformed[16] = 0xff
        try check(NativeOpenXRSupport.architectures(in: malformed).isEmpty, "out-of-bounds universal slice accepted")
        let unrelated = f.host.appendingPathComponent("UnrelatedRuntime/sentinel")
        try f.write("unrelated runtime sentinel", unrelated)
        try NativeOpenXRSupport.stage(.halliday, resources: f.resources, root: f.host)
        try check(try String(contentsOf: unrelated, encoding: .utf8) == "unrelated runtime sentinel", "staging changed unrelated runtime files")
        let stage = NativeOpenXRSupport.folder(for: .halliday, root: f.host)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: stage.appendingPathComponent("halliday_native_openxr.json"))) as! [String: Any]
        try check((manifest["runtime"] as? [String: String])?["library_path"] == "./libhalliday_openxr.dylib", "manifest selected wrong runtime")
        try check(FileManager.default.isExecutableFile(atPath: NativeOpenXRSupport.bridge(for: .halliday, root: f.host).path), "private wrapper not executable")
        let staged = Set(try FileManager.default.contentsOfDirectory(atPath: stage.path))
        try check(staged == Set(NativeOpenXRSupport.files + ["halliday_native_openxr.json"]), "staging wrote unlisted runtime files")

        let nativeRuntime = NativeOpenXRSupport.runtime(for: .halliday, root: f.host)
        let wrapper = NativeOpenXRSupport.bridge(for: .halliday, root: f.host)
        try f.write("#!/bin/bash\nexec \"$HALLIDAY_ALYX_ORIGINAL_BRIDGE\" \"$@\"\n", wrapper)
        for kind in [NativeAlyxKind.inversa, .verantyx] {
            let game = try f.install(kind), output = f.root.appendingPathComponent(kind.rawValue + "-environment.bin")
            let original = try Data(contentsOf: game.launcher)
            let inherited = ["PATH": "/usr/bin:/bin", "KEEP_SETTING": "kept", "TEST_OUTPUT": output.path,
                             "HALLIDAY_BRIDGE": "/stale/wrong-host", "HALLIDAY_EYE_SIZE": "64x64"]
            let environment = try NativeOpenXRSupport.launchEnvironment(inherited, backend: .halliday, root: f.host, displayHz: 60)
            try check(environment["HALLIDAY_DISPLAY_HZ_INITIAL"] == "1",
                        "App-generated launch Hz must not disable the runtime's live cadence")
            let command = try NativeAlyxSupport.prepare(installation: game, runtime: nativeRuntime,
                workspace: f.root.appendingPathComponent("launch workspace"), bridgeOverride: wrapper,
                inheritedEnvironment: environment)
            defer { command.removePreparedScript() }
            let child = Process(); child.executableURL = command.executable; child.arguments = command.arguments
            child.currentDirectoryURL = command.workingDirectory; child.environment = command.environment
            try child.run(); child.waitUntilExit()
            try check(child.terminationStatus == 0, "fixture launch failed")
            let values = try Data(contentsOf: output).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            try check(Array(values.prefix(6)) == [nativeRuntime.path, nativeRuntime.path, f.host.appendingPathComponent("halliday-bridge.shm").path, "60", "unset", "kept"], "actual child environment selected wrong module/host/rate")
            try check(values.count == 9 && values[8] == "1", "actual child lost the live-cadence launch hint")
            if kind == .verantyx { try check(Array(values[6..<8]) == ["60", "60"], "VeRantyx game pacing ignored selected rate") }
            try check(try Data(contentsOf: game.launcher) == original, "original fixture launcher changed")
        }
        try rejects { _ = try NativeOpenXRSupport.launchEnvironment([:], backend: .halliday, root: f.host, displayHz: nil) }
        try rejects { _ = try NativeOpenXRSupport.launchEnvironment([:], backend: .halliday, root: f.host, displayHz: .nan) }
        print("PASS: source-built defaults and preferences, universal-module rejection, isolated staging, exact bridge/rate in both fixture launchers, original launchers preserved")
    }
}
