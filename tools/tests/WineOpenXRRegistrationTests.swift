import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw CheckFailure(message) }
}
private func rejects(_ expected: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch let error as WineOpenXRRegistration.Failure {
        let actual: String
        switch error {
        case .changed: actual = "changed"
        case .invalidReceipt: actual = "invalidReceipt"
        case .unavailable: actual = "unavailable"
        case .helper: actual = "helper"
        }
        try check(actual == expected, "Wrong error: \(actual), expected \(expected)")
        return
    }
    throw CheckFailure("Expected \(expected), operation succeeded")
}

private final class RegistryFixture {
    typealias Value = WineOpenXRRegistration.Value
    let root: URL
    let prefix: URL
    let first: URL
    let second: URL
    var current: Value?
    var reads = 0
    var writes: [Value?] = []
    var onWrite: ((Value?) throws -> Void)?
    var onRead: (() throws -> Value?)?

    init(original: Value? = .string("C:\\openxr\\moltenvr_openxr.json")) throws {
        current = original
        root = URL(fileURLWithPath: "/private/tmp/halliday-wine-xr-registration-\(UUID().uuidString)")
        prefix = root.appendingPathComponent("Bottle with spaces")
        first = root.appendingPathComponent("Halliday A/runtime.json")
        second = root.appendingPathComponent("Halliday B 測試/runtime.json")
        let fm = FileManager.default
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: prefix.appendingPathComponent("dosdevices/z:"),
                                  withDestinationURL: URL(fileURLWithPath: "/"))
        for file in [first, second] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"file_format_version\":\"1.0.0\"}".utf8).write(to: file)
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    var receipt: URL { WineOpenXRRegistration.receiptURL(prefix: prefix) }
    var access: WineOpenXRRegistration.Access {
        .init(read: {
            self.reads += 1
            if let onRead = self.onRead { return try onRead() }
            return self.current
        }, write: { value in
            self.writes.append(value)
            if let onWrite = self.onWrite { try onWrite(value) }
            else { self.current = value }
        })
    }
    func install(_ manifest: URL? = nil) throws {
        try WineOpenXRRegistration.install(prefix: prefix, manifestURL: manifest ?? first, access: access)
    }
    func undo() throws { try WineOpenXRRegistration.uninstall(prefix: prefix, access: access) }
    func original() throws -> Value? { try WineOpenXRRegistration.originalRuntime(prefix: prefix, access: access) }
    func target(_ file: URL) -> Value { .string(OpenVRRegistration.windowsPath(file)) }
    func receiptBytes() throws -> Data { try Data(contentsOf: receipt) }
    func replaceReceipt(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: receipt, options: .atomic)
    }
}

@main private struct WineOpenXRRegistrationTests {
    static func main() throws {
        typealias Registration = WineOpenXRRegistration
        typealias Value = Registration.Value
        let tests: [(String, () throws -> Void)] = [
            ("fresh install, repeated install, route updates and Undo preserve the true original", {
                let f = try RegistryFixture(), original = f.current
                try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Missing receipt reported setup")
                try check(try f.original() == original, "Unregistered original was not returned")
                try f.install()
                try check(f.current == f.target(f.first), "Wrong installed manifest")
                try check(Registration.hasSetupReceipt(prefix: f.prefix), "Valid setup receipt missing")
                try check(try f.original() == original, "Installed route became the original")
                let firstReceipt = try f.receiptBytes(), writeCount = f.writes.count, readCount = f.reads
                try f.install()
                try check(f.writes.count == writeCount && f.reads == readCount + 1, "Repeated install rewrote or skipped ownership read")
                try check(try f.receiptBytes() == firstReceipt, "Repeated install changed receipt")
                try f.install(f.second)
                try check(f.current == f.target(f.second), "Updated route was not installed")
                try check(try f.original() == original, "Update lost original runtime")
                try f.install(f.first)
                try check(try f.original() == original, "Switching back lost original runtime")
                try f.undo()
                try check(f.current == original, "Undo did not restore exact original")
                try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Undo retained setup receipt")
                let writes = f.writes.count
                try f.undo()
                try check(f.writes.count == writes, "Repeated Undo wrote to registry")
            }),
            ("absent original remains absent after multiple route updates", {
                let f = try RegistryFixture(original: nil)
                try check(try f.original() == nil, "Absent registry value was invented")
                for manifest in [f.first, f.second, f.first] {
                    try f.install(manifest)
                    try check(try f.original() == nil, "Nil original was replaced by a Halliday route")
                }
                try f.undo()
                try check(f.current == nil && f.writes.last! == nil, "Undo failed to delete originally absent value")
                try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Nil Undo left readiness set")
            }),
            ("non-string original is restored byte-for-byte", {
                let original = Value(type: 3, data: Data([0, 0xff, 0x80, 0, 1]))
                let f = try RegistryFixture(original: original)
                try f.install(); try f.install(f.second)
                try check(try f.original() == original, "Non-string original was reinterpreted")
                try f.undo()
                try check(f.current == original, "Original registry type/bytes changed")
            }),
            ("foreign changes block lookup, install and Undo without mutations", {
                let f = try RegistryFixture()
                try f.install()
                let receipt = try f.receiptBytes(), writes = f.writes.count
                let foreign = Value.string("C:\\Other Runtime\\runtime.json")
                f.current = foreign
                try rejects("changed") { _ = try f.original() }
                try rejects("changed") { try f.install(f.second) }
                try rejects("changed") { try f.undo() }
                try check(f.current == foreign && f.writes.count == writes, "External runtime was overwritten")
                try check(try f.receiptBytes() == receipt, "Foreign change modified journal")
                // A setup receipt is only a hint: mutation APIs must still check ownership.
                try check(Registration.hasSetupReceipt(prefix: f.prefix), "Readiness unexpectedly queries live registry")
            }),
            ("restored original and previous installed state remain recoverable", {
                let f = try RegistryFixture(), original = f.current
                try f.install(); try f.install(f.second)
                f.current = f.target(f.first) // interrupted update's previous registration
                try check(try f.original() == original, "Previous installed route rejected")
                try f.install(f.second)
                f.current = original // interrupted Undo after successful registry restore
                try check(try f.original() == original, "Restored original not recognized")
                let writes = f.writes.count
                try f.undo()
                try check(f.writes.count == writes, "Recovery rewrote already restored original")
                try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Recovery did not remove receipt")
            }),
            ("failed initial write rolls back registry and removes prepared receipt", {
                let f = try RegistryFixture(), original = f.current
                defer { f.onWrite = nil }
                var fail = true
                f.onWrite = { value in
                    f.current = value
                    if fail { fail = false; throw Registration.Failure.helper("injected interrupted write") }
                }
                try rejects("helper") { try f.install() }
                try check(f.current == original, "Interrupted write did not restore original")
                try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Failed initial setup retained readiness")
            }),
            ("failed update restores previous route and exact old receipt", {
                let f = try RegistryFixture(), original = f.current
                defer { f.onWrite = nil }
                try f.install()
                let receipt = try f.receiptBytes(), previous = f.current
                var fail = true
                f.onWrite = { value in
                    f.current = value
                    if fail { fail = false; throw Registration.Failure.helper("injected update failure") }
                }
                try rejects("helper") { try f.install(f.second) }
                try check(f.current == previous, "Failed update did not restore previous route")
                try check(try f.receiptBytes() == receipt, "Failed update changed durable original")
                try check(try f.original() == original, "Failed update lost original lookup")
            }),
            ("concurrent foreign replacement during failed write is preserved", {
                let f = try RegistryFixture()
                defer { f.onWrite = nil }
                let foreign = Value.string("C:\\Concurrent\\runtime.json")
                f.onWrite = { _ in f.current = foreign; throw Registration.Failure.helper("injected concurrent write") }
                try rejects("helper") { try f.install() }
                try check(f.current == foreign && f.writes.count == 1, "Rollback overwrote concurrent runtime")
                try check(Registration.hasSetupReceipt(prefix: f.prefix), "Interrupted setup lost its recovery receipt")
                try rejects("changed") { try f.undo() }
            }),
            ("readback mismatch rolls back safely", {
                let f = try RegistryFixture(), original = f.current
                defer { f.onRead = nil }
                var calls = 0
                f.onRead = {
                    calls += 1
                    return calls == 2 ? Value.string("C:\\Wrong readback\\runtime.json") : f.current
                }
                try rejects("helper") { try f.install() }
                try check(f.current == original, "Bad readback did not restore original")
                try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Bad readback left setup ready")
            }),
            ("failed Undo preserves receipt for a successful retry", {
                let f = try RegistryFixture(), original = f.current
                defer { f.onWrite = nil }
                try f.install()
                f.onWrite = { _ in throw Registration.Failure.helper("injected Undo write failure") }
                try rejects("helper") { try f.undo() }
                try check(Registration.hasSetupReceipt(prefix: f.prefix), "Failed Undo discarded recovery receipt")
                f.onWrite = nil
                try f.undo()
                try check(f.current == original && !Registration.hasSetupReceipt(prefix: f.prefix), "Undo retry did not recover")
            }),
            ("invalid receipts are never adopted", {
                let f = try RegistryFixture()
                for text in ["", "{broken", "{}", "{\"version\":2}", "null"] {
                    try Data(text.utf8).write(to: f.receipt, options: .atomic)
                    try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Invalid receipt reported setup")
                    try rejects("invalidReceipt") { _ = try f.original() }
                    try rejects("invalidReceipt") { try f.install() }
                    try rejects("invalidReceipt") { try f.undo() }
                    try check(f.writes.isEmpty, "Invalid receipt caused registry mutation")
                }
            }),
            ("readiness requires version1 and a nonempty strict REG_SZ installed path", {
                let f = try RegistryFixture()
                try f.install()
                let valid = try JSONSerialization.jsonObject(with: f.receiptBytes()) as! [String: Any]
                for value in [Value(type: 2, data: Value.string("C:\\R.json").data), Value.string(""),
                              Value(type: 1, data: Data([0x41, 0])), Value(type: 1, data: Data([0, 0xd8, 0, 0]))] {
                    var modified = valid
                    modified["installed"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                    try f.replaceReceipt(modified)
                    try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Malformed installed registry path accepted")
                }
                try f.replaceReceipt(valid)
                try check(Registration.hasSetupReceipt(prefix: f.prefix), "Valid receipt rejected")
                var wrongVersion = valid; wrongVersion["version"] = 2
                try f.replaceReceipt(wrongVersion)
                try check(!Registration.hasSetupReceipt(prefix: f.prefix), "Wrong receipt version accepted")
            }),
            ("strict REG_SZ parsing preserves Unicode and rejects malformed UTF16", {
                for text in ["C:\\openxr\\runtime.json", "Z:\\VR 測試\\🚀\\runtime.json", "A"] {
                    try check(Registration.registryString(.string(text)) == text, "Valid UTF16 failed")
                }
                func units(_ u: [UInt16], type: UInt32 = 1) -> Value {
                    .init(type: type, data: Data(u.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }))
                }
                let invalid: [Value?] = [nil, .init(type: 1, data: Data()), .init(type: 1, data: Data([0x41])),
                    units([0]), units([0x41]), units([0x41, 0, 0]), units([0x41, 0, 0x42, 0]),
                    units([0xd800, 0]), units([0xdc00, 0]), units([0xdc00, 0xd800, 0]),
                    units([0xd800, 0x41, 0]), units([0xd800, 0xd800, 0]),
                    units([0x41, 0], type: 2), units([0x41, 0], type: 3), units([0x41, 0], type: 7)]
                for value in invalid { try check(Registration.registryString(value) == nil, "Malformed/non-REG_SZ string accepted") }
                try check(Registration.registryString(units([0xd83d, 0xde80, 0])) == "🚀", "Valid surrogate pair rejected")
            }),
            ("missing manifest and wrong Z mapping cause no registry mutation", {
                let f = try RegistryFixture()
                try rejects("unavailable") { try f.install(f.root.appendingPathComponent("missing.json")) }
                try FileManager.default.removeItem(at: f.prefix.appendingPathComponent("dosdevices/z:"))
                try FileManager.default.createSymbolicLink(at: f.prefix.appendingPathComponent("dosdevices/z:"), withDestinationURL: f.root)
                try rejects("unavailable") { try f.install() }
                try check(f.writes.isEmpty && f.reads == 0, "Invalid prerequisites touched registry")
            })
        ]
        var failed = 0
        for (name, run) in tests {
            do { try run(); print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failed)/\(tests.count) Wine OpenXR registration tests passed (injected access only)")
        if failed != 0 { exit(1) }
    }
}
