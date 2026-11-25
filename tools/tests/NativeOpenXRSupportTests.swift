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

}

@main private struct NativeOpenXRSupportTests {
    @MainActor static func main() throws {
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
        let staged = Set(try FileManager.default.contentsOfDirectory(atPath: stage.path))
        try check(staged == Set(NativeOpenXRSupport.files + ["halliday_native_openxr.json"]), "staging wrote unlisted runtime files")

        let environment = try NativeOpenXRSupport.launchEnvironment(
            ["KEEP_SETTING": "kept", "HALLIDAY_BRIDGE": "/stale/wrong-host", "XR_RUNTIME_JSON": "/stale/runtime.json"],
            backend: .halliday, root: f.host, displayHz: 60)
        try check(environment["KEEP_SETTING"] == "kept", "launch discarded inherited settings")
        try check(environment["HALLIDAY_BRIDGE"] == f.host.appendingPathComponent("halliday-bridge.shm").path,
                  "launch selected wrong host bridge")
        try check(environment["XR_RUNTIME_JSON"] == stage.appendingPathComponent("halliday_native_openxr.json").path,
                  "launch selected wrong loader manifest")
        try check(environment["HALLIDAY_DISPLAY_HZ"] == "60" && environment["HALLIDAY_DISPLAY_HZ_INITIAL"] == "1",
                  "launch lost its startup rate or disabled live cadence")
        try check(!environment.keys.contains(where: { $0.contains("ALYX") }), "generic launch introduced a game-specific contract")
        try rejects { _ = try NativeOpenXRSupport.launchEnvironment([:], backend: .halliday, root: f.host, displayHz: nil) }
        try rejects { _ = try NativeOpenXRSupport.launchEnvironment([:], backend: .halliday, root: f.host, displayHz: .nan) }
        print("PASS: source-built defaults and preferences, universal-module rejection, isolated staging, generic loader manifest/bridge/rate selection, inherited settings preserved")
    }
}
