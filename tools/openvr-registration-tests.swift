import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message) }
}

private func contents(_ url: URL) throws -> Data? {
    FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
}

private func expectFailure(_ kind: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw CheckFailure("expected \(kind), but the operation succeeded")
    } catch let error as OpenVRRegistration.Failure {
        let actual: String
        switch error {
        case .noUsers: actual = "noUsers"
        case .unavailableZDrive: actual = "unavailableZDrive"
        case .changed: actual = "changed"
        case .invalidJournal: actual = "invalidJournal"
        }
        try check(actual == kind, "expected \(kind), received \(actual)")
    }
}

private final class Fixture {
    let root: URL
    let prefix: URL
    let runtime: URL
    let users: [String]

    init(users: [String] = ["crossover"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-registration-\(UUID().uuidString)")
        prefix = root.appendingPathComponent("Bottle with spaces")
        runtime = root.appendingPathComponent("Halliday OpenVR")
        self.users = users
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        for user in users {
            try FileManager.default.createDirectory(at: file(user).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ user: String = "crossover") -> URL {
        prefix.appendingPathComponent("drive_c/users/\(user)/AppData/Local/openvr/openvrpaths.vrpath")
    }
    func journal(_ user: String = "crossover") -> URL { file(user).appendingPathExtension("halliday-state.json") }
    func legacy(_ user: String = "crossover") -> URL { file(user).appendingPathExtension("before-halliday") }

    func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func install(_ at: URL? = nil) throws { try OpenVRRegistration.install(prefix: prefix, runtime: at ?? runtime) }
    func undo(_ at: URL? = nil) throws { try OpenVRRegistration.uninstall(prefix: prefix, runtime: at ?? runtime) }

    func legacyRegistration() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["runtime": [OpenVRRegistration.windowsPath(runtime)]])
    }
}

@main
private struct RegistrationTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("reads the original provider without replacing registrations or losing its receipt", {
                let f = try Fixture()
                let paths = ["C:\\External VR"]
                let original = try JSONSerialization.data(withJSONObject: ["runtime": paths])
                try f.write(original, f.file())
                try check(try OpenVRRegistration.originalRuntimePaths(prefix: f.prefix, runtime: f.runtime) == paths, "original provider was not read")
                try f.install()
                let before = try contents(f.file()), receipt = try contents(f.journal())
                try check(try OpenVRRegistration.originalRuntimePaths(prefix: f.prefix, runtime: f.runtime) == paths, "setup lost the original provider")
                try check(try contents(f.file()) == before && contents(f.journal()) == receipt, "query changed a registration")
                try f.write(Data("external replacement".utf8), f.file())
                try expectFailure("changed") { _ = try OpenVRRegistration.originalRuntimePaths(prefix: f.prefix, runtime: f.runtime) }
            }),
            ("does not guess one original provider for disagreeing Windows profiles", {
                let f = try Fixture(users: ["a", "b"])
                for user in f.users {
                    try f.write(JSONSerialization.data(withJSONObject: ["runtime": ["C:\\Provider-\(user)"]]), f.file(user))
                }
                try check(try OpenVRRegistration.originalRuntimePaths(prefix: f.prefix, runtime: f.runtime).isEmpty, "an arbitrary user's provider was selected")
                try check(try contents(f.journal("a")) == nil && contents(f.journal("b")) == nil, "query created setup receipts")
            }),
            ("preserves every byte of the previous registration", {
                let f = try Fixture()
                let original = Data([0, 13, 10, 255, 32]) + Data("old settings\r\n".utf8)
                try f.write(original, f.file())
                try f.install()
                let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file())) as? [String: Any]
                try check(installed?["runtime"] as? [String] == [OpenVRRegistration.windowsPath(f.runtime)], "wrong Windows runtime path")
                try f.undo()
                try check(try contents(f.file()) == original, "the previous bytes changed")
                try check(try contents(f.journal()) == nil, "receipt was not removed")
            }),
            ("restores the absence of an original file and supports repeated undo", {
                let f = try Fixture()
                try f.install()
                try check(try contents(f.file()) != nil, "registration was not installed")
                try f.undo()
                try f.undo()
                try check(try contents(f.file()) == nil, "undo created a registration that was originally absent")
                try check(try contents(f.journal()) == nil, "undo left a receipt")
            }),
            ("repeated setup and a runtime update retain the first original", {
                let f = try Fixture()
                let original = Data("original runtime\n".utf8)
                try f.write(original, f.file())
                try f.install()
                try f.install()
                let newer = f.root.appendingPathComponent("New Halliday OpenVR")
                try f.install(newer)
                try f.undo(newer)
                try check(try contents(f.file()) == original, "repeated setup replaced the original backup")
            }),
            ("validates every profile before changing any registration", {
                let f = try Fixture(users: ["a", "b"])
                try f.write(Data("original a".utf8), f.file("a"))
                try f.write(Data("original b".utf8), f.file("b"))
                try f.install()
                let priorA = try contents(f.file("a")), journalA = try contents(f.journal("a"))
                let changed = Data("external runtime b".utf8)
                try f.write(changed, f.file("b"))
                try expectFailure("changed") { try f.install(f.root.appendingPathComponent("updated")) }
                try expectFailure("changed") { try f.undo() }
                try check(try contents(f.file("a")) == priorA, "profile a was partly changed")
                try check(try contents(f.journal("a")) == journalA, "profile a's receipt was partly changed")
                try check(try contents(f.file("b")) == changed, "external changes were overwritten")
            }),
            ("refuses malformed and unsupported receipts before writing", {
                let f = try Fixture(users: ["a", "b"])
                let original = Data("untouched a".utf8)
                try f.write(original, f.file("a"))
                for invalid in [Data("{broken".utf8), Data("{\"version\":2,\"installed\":\"\"}".utf8)] {
                    try f.write(invalid, f.journal("b"))
                    try expectFailure("invalidJournal") { try f.install() }
                    try expectFailure("invalidJournal") { try f.undo() }
                    try check(try contents(f.file("a")) == original, "an invalid receipt caused a partial install")
                    try check(try contents(f.journal("a")) == nil, "an invalid receipt caused a new receipt")
                }
            }),
            ("adopts the legacy backup and restores it byte for byte", {
                let f = try Fixture()
                let legacy = try f.legacyRegistration(), original = Data("legacy original\r\n".utf8)
                try f.write(legacy, f.file())
                try f.write(original, f.legacy())
                try f.install()
                try f.undo()
                try check(try contents(f.file()) == original, "legacy adoption lost the saved settings")
            }),
            ("does not restore a legacy backup over an external runtime", {
                let f = try Fixture()
                let external = Data("current external runtime".utf8)
                try f.write(external, f.file())
                try f.write(Data("obsolete legacy backup".utf8), f.legacy())
                try f.undo()
                try check(try contents(f.file()) == external, "stale backup overwrote the external runtime")
                try f.install()
                try f.undo()
                try f.install()
                try f.undo()
                try check(try contents(f.file()) == external, "fresh setup reused a stale legacy backup")
            }),
            ("refuses external changes after legacy adoption", {
                let f = try Fixture()
                try f.write(try f.legacyRegistration(), f.file())
                try f.write(Data("before legacy".utf8), f.legacy())
                try f.install()
                let external = Data("after legacy adoption: external settings".utf8)
                try f.write(external, f.file())
                try expectFailure("changed") { try f.undo() }
                try expectFailure("changed") { try f.install() }
                try check(try contents(f.file()) == external, "legacy adoption allowed an external overwrite")
            }),
            ("recovers when a receipt was saved before the first registration write", {
                let f = try Fixture()
                let original = Data("original before interruption".utf8)
                try f.write(original, f.file())
                try f.install()
                try f.write(original, f.file())
                try f.undo()
                try check(try contents(f.file()) == original, "could not recover the prepared receipt")
                try check(try contents(f.journal()) == nil, "recovery left a receipt")
            }),
            ("recovers when undo restored the file but had not removed its receipt", {
                let f = try Fixture()
                try f.install()
                try FileManager.default.removeItem(at: f.file())
                try f.undo()
                try check(try contents(f.file()) == nil, "interrupted undo did not retain original absence")
                try check(try contents(f.journal()) == nil, "interrupted undo did not finish receipt removal")
            }),
            ("recovers an update interrupted after its receipt but before its file", {
                let f = try Fixture()
                let original = Data("original before runtime a".utf8)
                try f.write(original, f.file())
                try f.install()
                let registeredA = try Data(contentsOf: f.file())
                let runtimeB = f.root.appendingPathComponent("Halliday B")
                try f.install(runtimeB)
                // The durable B receipt can exist while A is still registered.
                try f.write(registeredA, f.file())
                try f.undo(runtimeB)
                try check(try contents(f.file()) == original, "interrupted update was mistaken for an external change")
            }),
            ("recovers legacy adoption interrupted before rewriting the registration", {
                let f = try Fixture()
                let legacy = try f.legacyRegistration(), original = Data("before legacy install".utf8)
                try f.write(legacy, f.file())
                try f.write(original, f.legacy())
                try f.install()
                try f.write(legacy, f.file())
                try f.undo()
                try check(try contents(f.file()) == original, "interrupted legacy adoption could not recover")
            }),
            ("rolls back earlier profiles if a later receipt cannot be written", {
                let f = try Fixture(users: ["a", "b"])
                let originalA = Data("original a".utf8), originalB = Data("original b".utf8)
                try f.write(originalA, f.file("a"))
                try f.write(originalB, f.file("b"))
                let locked = f.file("b").deletingLastPathComponent()
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
                do {
                    try f.install()
                    throw CheckFailure("the read-only profile unexpectedly accepted setup")
                } catch is CheckFailure { throw CheckFailure("the read-only profile unexpectedly accepted setup") }
                catch { /* Expected I/O failure. */ }
                try check(try contents(f.file("a")) == originalA, "earlier profile was not rolled back")
                try check(try contents(f.journal("a")) == nil, "earlier receipt was not rolled back")
                try check(try contents(f.file("b")) == originalB, "read-only profile was changed")
            }),
            ("rejects a missing or different Z drive without creating a receipt", {
                let f = try Fixture()
                let z = f.prefix.appendingPathComponent("dosdevices/z:")
                try FileManager.default.removeItem(at: z)
                try expectFailure("unavailableZDrive") { try f.install() }
                try FileManager.default.createSymbolicLink(atPath: z.path, withDestinationPath: f.root.path)
                try expectFailure("unavailableZDrive") { try f.install() }
                try check(try contents(f.journal()) == nil, "invalid Z drive created a receipt")
                try check(try contents(f.file()) == nil, "invalid Z drive created a registration")
            }),
            ("ignores shared Windows profiles and refuses bottles without a user", {
                let f = try Fixture(users: ["Public", "All Users", ".hidden"])
                try expectFailure("noUsers") { try f.install() }
            })
        ]
        var failures = 0
        for (name, run) in tests {
            do { try run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) registration tests passed")
        if failures != 0 { exit(1) }
    }
}
