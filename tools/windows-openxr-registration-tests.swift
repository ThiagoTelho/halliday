import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
private struct SimulatedIOFailure: Error {}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message) }
}

private func expectFailure(_ kind: String, _ run: () throws -> Void) throws {
    do { try run(); throw CheckFailure("expected \(kind), but succeeded") }
    catch let failure as WineOpenXRRegistration.Failure {
        let actual: String
        switch failure {
        case .changed: actual = "changed"
        case .unavailable: actual = "unavailable"
        case .invalidReceipt: actual = "invalidReceipt"
        case .helper: actual = "helper"
        }
        try check(actual == kind, "expected \(kind), received \(actual)")
    }
}

private final class Registry {
    typealias Value = WineOpenXRRegistration.Value
    enum Fault { case beforeWrite, afterWrite, externalChange }
    var value: Value?
    var reads = 0
    var writes = 0
    var faults: [Fault] = []
    let external = Value(type: 3, data: Data("external runtime bytes".utf8))

    init(_ value: Value? = nil) { self.value = value }
    var access: WineOpenXRRegistration.Access {
        .init(read: { self.reads += 1; return self.value }, write: { value in
            self.writes += 1
            let fault = self.faults.isEmpty ? nil : self.faults.removeFirst()
            if case .beforeWrite = fault { throw SimulatedIOFailure() }
            self.value = value
            if case .afterWrite = fault { throw SimulatedIOFailure() }
            if case .externalChange = fault {
                self.value = self.external
                throw SimulatedIOFailure()
            }
        })
    }
}

private final class Fixture {
    let root: URL
    let prefix: URL
    let manifest: URL
    var receipt: URL { WineOpenXRRegistration.receiptURL(prefix: prefix) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-openxr-\(UUID().uuidString)")
        prefix = root.appendingPathComponent("Bottle with spaces")
        manifest = root.appendingPathComponent("Halliday 測試/halliday_openxr.json")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manifest)
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func install(_ registry: Registry, manifest: URL? = nil) throws {
        try WineOpenXRRegistration.install(prefix: prefix, manifestURL: manifest ?? self.manifest, access: registry.access)
    }
    func undo(_ registry: Registry) throws {
        try WineOpenXRRegistration.uninstall(prefix: prefix, access: registry.access)
    }
    func hasReceipt() -> Bool { FileManager.default.fileExists(atPath: receipt.path) }
}

@main
private struct RegistrationTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("preserves arbitrary previous registry types and raw bytes", {
                for original in [Registry.Value(type: 3, data: Data([0, 255, 0, 13, 10])),
                                 Registry.Value(type: 4, data: Data([0x78, 0x56, 0x34, 0x12])),
                                 Registry.Value(type: 0, data: Data())] {
                    let f = try Fixture(), r = Registry(original)
                    try f.install(r)
                    try check(r.value?.type == 1, "runtime is not REG_SZ")
                    let decoded = r.value.flatMap { String(data: $0.data.dropLast(2), encoding: .utf16LittleEndian) }
                    try check(decoded == OpenVRRegistration.windowsPath(f.manifest), "wrong UTF-16 Windows path")
                    try f.undo(r)
                    try check(r.value == original, "original type or bytes changed")
                    try check(!f.hasReceipt(), "receipt not removed")
                }
            }),
            ("preserves an absent original across repeated setup and runtime updates", {
                let f = try Fixture(), r = Registry()
                try f.install(r)
                try f.install(r)
                let second = f.root.appendingPathComponent("other.json")
                try Data("{}".utf8).write(to: second)
                try f.install(r, manifest: second)
                try f.undo(r)
                try f.undo(r)
                try check(r.value == nil, "an absent original became an installed runtime")
                try check(!f.hasReceipt(), "receipt left after repeated undo")
            }),
            ("repeated setup performs one live query and no writes or receipt rewrite", {
                let f = try Fixture(), r = Registry(.string("original"))
                try f.install(r)
                let receipt = try Data(contentsOf: f.receipt)
                r.reads = 0
                r.writes = 0
                try f.install(r)
                try check(r.reads == 1 && r.writes == 0, "repeated setup did not use its live-query fast path")
                try check(try Data(contentsOf: f.receipt) == receipt, "repeated setup rewrote the durable receipt")
                // The fast path must not treat a saved receipt as a cached registry query.
                r.value = r.external
                r.reads = 0
                try expectFailure("changed") { try f.install(r) }
                try check(r.reads == 1 && r.writes == 0, "external changes were hidden by a cache")
            }),
            ("a matching value without a receipt still records its original state", {
                let f = try Fixture()
                let target = Registry.Value.string(OpenVRRegistration.windowsPath(f.manifest))
                let r = Registry(target)
                try f.install(r)
                try check(f.hasReceipt() && r.writes == 1, "a matching value incorrectly bypassed first setup")
                try f.undo(r)
                try check(r.value == target, "undo lost a pre-existing matching value")
            }),
            ("refuses external changes on install and undo", {
                let f = try Fixture(), r = Registry(.string("original"))
                try f.install(r)
                let receipt = try Data(contentsOf: f.receipt)
                r.value = r.external
                let writes = r.writes
                try expectFailure("changed") { try f.install(r) }
                try expectFailure("changed") { try f.undo(r) }
                try check(r.value == r.external && r.writes == writes, "external value was overwritten")
                try check(try Data(contentsOf: f.receipt) == receipt, "external change rewrote the receipt")
            }),
            ("refuses malformed and unsupported receipts without touching the registry", {
                let f = try Fixture(), r = Registry(.string("untouched"))
                for data in [Data("broken".utf8), Data("{\"version\":2,\"installed\":{\"type\":1,\"data\":\"\"}}".utf8)] {
                    try data.write(to: f.receipt)
                    try expectFailure("invalidReceipt") { try f.install(r) }
                    try expectFailure("invalidReceipt") { try f.undo(r) }
                }
                try check(r.writes == 0, "invalid receipt wrote to the registry")
            }),
            ("undo without a receipt needs neither Wine nor a helper", {
                let f = try Fixture()
                try WineOpenXRRegistration.uninstall(prefix: f.prefix,
                    installation: .init(applicationURL: f.root.appendingPathComponent("Missing.app")),
                    helperURL: f.root.appendingPathComponent("missing.exe"), manifestURL: f.manifest)
                try check(!f.hasReceipt(), "no-op undo created a receipt")
            }),
            ("rolls back a helper failure before or after its registry write", {
                for fault in [Registry.Fault.beforeWrite, .afterWrite] {
                    let f = try Fixture(), r = Registry(.string("original"))
                    let original = r.value
                    r.faults = [fault]
                    do { try f.install(r); throw CheckFailure("simulated I/O failure was not propagated") }
                    catch is SimulatedIOFailure { }
                    try check(r.value == original, "failed setup did not restore the registry")
                    try check(!f.hasReceipt(), "successful rollback left a new receipt")
                }
            }),
            ("failed update restores its previous receipt and registered runtime", {
                let f = try Fixture(), r = Registry(.string("original"))
                try f.install(r)
                let a = r.value, oldReceipt = try Data(contentsOf: f.receipt)
                let second = f.root.appendingPathComponent("b.json")
                try Data("{}".utf8).write(to: second)
                r.faults = [.afterWrite]
                do { try f.install(r, manifest: second); throw CheckFailure("simulated update failure was not propagated") }
                catch is SimulatedIOFailure { }
                try check(r.value == a, "failed update did not restore runtime A")
                try check(try Data(contentsOf: f.receipt) == oldReceipt, "failed update did not restore A's receipt")
                try f.undo(r)
                try check(r.value == .string("original"), "rollback replaced the first original")
            }),
            ("retains a recoverable receipt if registry rollback fails", {
                let f = try Fixture(), r = Registry(.string("original"))
                r.faults = [.afterWrite, .beforeWrite]
                do { try f.install(r); throw CheckFailure("simulated write failure was not propagated") }
                catch is SimulatedIOFailure { }
                try check(f.hasReceipt(), "failed rollback lost the original receipt")
                try f.undo(r)
                try check(r.value == .string("original"), "explicit undo could not recover failed rollback")
            }),
            ("does not clobber an external change made during a helper failure", {
                let f = try Fixture(), r = Registry(.string("original"))
                r.faults = [.externalChange]
                do { try f.install(r); throw CheckFailure("simulated helper failure was not propagated") }
                catch is SimulatedIOFailure { }
                try check(r.value == r.external, "rollback overwrote a concurrent external change")
                try check(f.hasReceipt(), "receipt lost after an ambiguous write")
                try expectFailure("changed") { try f.undo(r) }
            }),
            ("recovers an update stopped after saving its receipt", {
                let f = try Fixture(), r = Registry(.string("original"))
                try f.install(r)
                let a = r.value
                let second = f.root.appendingPathComponent("b.json")
                try Data("{}".utf8).write(to: second)
                try f.install(r, manifest: second)
                r.value = a
                try f.undo(r)
                try check(r.value == .string("original"), "interrupted update was mistaken for external settings")
            }),
            ("finishes undo after a helper wrote the original then reported failure", {
                let f = try Fixture(), r = Registry(.string("original"))
                try f.install(r)
                r.faults = [.afterWrite]
                do { try f.undo(r); throw CheckFailure("simulated undo failure was not propagated") }
                catch is SimulatedIOFailure { }
                try check(f.hasReceipt() && r.value == .string("original"), "interrupted undo lost its recovery state")
                try f.undo(r)
                try check(!f.hasReceipt(), "retry did not finish interrupted undo")
            }),
            ("undo also works after the runtime manifest was removed", {
                let f = try Fixture(), r = Registry(.string("original"))
                try f.install(r)
                try FileManager.default.removeItem(at: f.manifest)
                try f.undo(r)
                try check(r.value == .string("original"), "removed build prevented restoration")
            }),
            ("validates Z mapping and manifest before calling the registry", {
                let f = try Fixture(), r = Registry()
                let z = f.prefix.appendingPathComponent("dosdevices/z:")
                try FileManager.default.removeItem(at: z)
                try expectFailure("unavailable") { try f.install(r) }
                try FileManager.default.createSymbolicLink(atPath: z.path, withDestinationPath: "/")
                try FileManager.default.removeItem(at: f.manifest)
                try expectFailure("unavailable") { try f.install(r) }
                try check(r.writes == 0 && !f.hasReceipt(), "invalid input changed the registry or receipt")
            })
        ]
        var failed = 0
        for (name, run) in tests {
            do { try run(); print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failed)/\(tests.count) Windows OpenXR registration tests passed")
        if failed != 0 { exit(1) }
    }
}
