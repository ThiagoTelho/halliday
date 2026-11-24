// Explicit, reversible registration of the Windows OpenXR runtime for one Wine bottle.
// The registry helper uses Win32 APIs; this code never edits Wine's .reg files.
import Foundation

enum WineOpenXRRegistration {
    struct Value: Codable, Equatable, Sendable {
        var type: UInt32
        var data: Data

        static func string(_ text: String) -> Self {
            let bytes = (Array(text.utf16) + [0]).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
            return Self(type: 1, data: Data(bytes)) // REG_SZ, including its UTF-16 terminator.
        }
    }

    /// Injectable, synchronous registry operations for deterministic fixture tests.
    struct Access {
        var read: () throws -> Value?
        var write: (Value?) throws -> Void
    }

    enum Failure: LocalizedError {
        case unavailable(String), changed, invalidReceipt, helper(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let what): "\(what) is unavailable. Windows OpenXR settings were left untouched."
            case .changed: "Another application changed this bottle's Windows OpenXR runtime. Its settings were left untouched."
            case .invalidReceipt: "The saved Windows OpenXR settings could not be read. Its settings were left untouched."
            case .helper(let message): "The Windows OpenXR registry helper failed: \(message)"
            }
        }
    }

    private struct State: Codable {
        var version = 1
        var original: Value?
        var installed: Value
        var previousInstalled: Value?

        func matches(_ current: Value?) -> Bool {
            current == installed || current == original ||
                (previousInstalled.map { current == $0 } ?? false)
        }
    }

    private struct Response: Decodable {
        var present: Bool?
        var type: UInt32?
        var data: String?
        var error: UInt32?
    }

    static func receiptURL(prefix: URL) -> URL {
        prefix.appendingPathComponent("halliday-openxr-state.json")
    }

    /// The pre-Halliday runtime is retained across switching our own backends and app updates.
    /// Query the live registry first; never silently adopt a concurrent external replacement.
    static func originalRuntime(prefix: URL, access: Access) throws -> Value? {
        let before = try access.read()
        guard let data = try receiptData(at: receiptURL(prefix: prefix)) else { return before }
        let prior = try decode(data)
        guard prior.matches(before) else { throw Failure.changed }
        return prior.original
    }

    static func registryString(_ value: Value?) -> String? {
        guard let value, value.type == 1, value.data.count >= 2, value.data.count % 2 == 0 else { return nil }
        let bytes = Array(value.data)
        var units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        guard units.removeLast() == 0, !units.isEmpty, !units.contains(0) else { return nil }
        let text = String(decoding: units, as: UTF16.self)
        return Array(text.utf16) == units ? text : nil
    }

    /// A readiness hint from our durable setup receipt, not a replacement for the live
    /// registry ownership check performed before every configuration change.
    static func hasSetupReceipt(prefix: URL) -> Bool {
        guard let data = try? Data(contentsOf: receiptURL(prefix: prefix)),
              let state = try? decode(data), let path = registryString(state.installed) else { return false }
        return !path.isEmpty
    }

    static func install(prefix: URL, installation: CrossOverInstallation, helperURL: URL, manifestURL: URL) throws {
        try install(prefix: prefix, manifestURL: manifestURL,
                    access: registryAccess(prefix: prefix, installation: installation, helperURL: helperURL))
    }

    static func uninstall(prefix: URL, installation: CrossOverInstallation, helperURL: URL, manifestURL: URL) throws {
        // manifestURL is deliberately not consulted: Undo must also work after a build was removed.
        guard FileManager.default.fileExists(atPath: receiptURL(prefix: prefix).path) else { return }
        try uninstall(prefix: prefix, access: registryAccess(prefix: prefix, installation: installation, helperURL: helperURL))
    }

    static func install(prefix: URL, manifestURL: URL, access: Access) throws {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path)) == "/" else {
            throw Failure.unavailable("This bottle's Z: mapping to /")
        }
        guard (try? manifestURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw Failure.unavailable("Halliday's Windows OpenXR manifest")
        }
        let url = receiptURL(prefix: prefix)
        let oldReceipt = try receiptData(at: url)
        let prior = try oldReceipt.map(decode)
        let before = try access.read()
        if let prior, !prior.matches(before) { throw Failure.changed }
        let installed = Value.string(OpenVRRegistration.windowsPath(manifestURL))
        // Always query the real registry, even on repeated Play. A matching durable receipt then
        // avoids another helper launch for write/readback and keeps the original receipt intact.
        if let prior, before == installed, prior.installed == installed { return }
        // An absent original must remain absent across updates; nil is a real saved state.
        let original: Value?
        if let prior { original = prior.original } else { original = before }
        let prepared = State(original: original, installed: installed, previousInstalled: before)
        try JSONEncoder().encode(prepared).write(to: url, options: .atomic)
        do {
            try access.write(installed)
            guard try access.read() == installed else { throw Failure.helper("the written runtime did not read back") }
        } catch {
            // An interrupted helper can have completed its write. Roll back only a state this
            // operation owns; a concurrently selected external runtime must remain untouched.
            do {
                let observed = try access.read()
                guard observed == before || observed == installed else { throw Failure.changed }
                if observed != before { try access.write(before) }
                if let oldReceipt { try oldReceipt.write(to: url, options: .atomic) }
                else { try fm.removeItem(at: url) }
            } catch { /* Keep the prepared receipt for an explicit later Undo. */ }
            throw error
        }
    }

    static func uninstall(prefix: URL, access: Access) throws {
        let url = receiptURL(prefix: prefix)
        guard let data = try receiptData(at: url) else { return }
        let saved = try decode(data)
        let before = try access.read()
        guard saved.matches(before) else { throw Failure.changed }
        if before != saved.original { try access.write(saved.original) }
        guard try access.read() == saved.original else { throw Failure.helper("the previous runtime did not read back") }
        // If this removal fails, the receipt still recognizes the restored original on retry.
        try FileManager.default.removeItem(at: url)
    }

    private static func receiptData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func decode(_ data: Data) throws -> State {
        guard let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1 else {
            throw Failure.invalidReceipt
        }
        return state
    }

    static func registryAccess(prefix: URL, installation: CrossOverInstallation, helperURL: URL) throws -> Access {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: installation.wineURL.path),
              (try? installation.wineURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw Failure.unavailable("The selected CrossOver application")
        }
        guard (try? helperURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw Failure.unavailable("Halliday's Windows OpenXR registry helper")
        }
        guard (try? prefix.appendingPathComponent("drive_c").resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Failure.unavailable("The selected CrossOver bottle")
        }
        let invoke: ([String], Data?) throws -> Value? = { arguments, input in
            let process = Process(), output = Pipe(), stdin = Pipe()
            process.executableURL = installation.wineURL
            process.arguments = ["--bottle", prefix.path, "--no-update", helperURL.path] + arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = stdin
            try process.run()
            if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
            try stdin.fileHandleForWriting.close()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                throw Failure.helper("invalid response (exit \(process.terminationStatus))")
            }
            if let error = response.error { throw Failure.helper("Windows registry error \(error)") }
            guard process.terminationStatus == 0, let present = response.present else {
                throw Failure.helper("exit \(process.terminationStatus)")
            }
            guard present else { return nil }
            guard let type = response.type, let hex = response.data, let bytes = decodeHex(hex) else {
                throw Failure.helper("invalid registry value")
            }
            return Value(type: type, data: bytes)
        }
        return Access(read: { try invoke(["query"], nil) }, write: { value in
            if let value {
                let hex = value.data.map { String(format: "%02x", $0) }.joined()
                let written = try invoke(["write", String(value.type)], Data(hex.utf8))
                guard written == value else { throw Failure.helper("the registry write did not match") }
            } else {
                guard try invoke(["delete"], nil) == nil else { throw Failure.helper("the registry value was not removed") }
            }
        })
    }

    private static func decodeHex(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ char: UInt8) -> UInt8? {
            switch char {
            case 48...57: char - 48
            case 65...70: char - 65 + 10
            case 97...102: char - 97 + 10
            default: nil
            }
        }
        var result = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            result.append((hi << 4) | lo)
        }
        return result
    }
}
