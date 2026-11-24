// Reversible, bottle-wide OpenVR registration. This file has no app or headset dependencies.
import Foundation
import CryptoKit

enum OpenVRRegistration {
    enum Failure: LocalizedError {
        case noUsers, unavailableZDrive, changed(String), invalidJournal(String)
        var errorDescription: String? {
            switch self {
            case .noUsers: "This bottle has no Windows user profile. Start it once in its Wine application."
            case .unavailableZDrive: "This bottle must map Z: to / so it can find Halliday's runtime."
            case .changed(let path): "Another application changed the VR settings at \(path). They were left untouched."
            case .invalidJournal(let path): "The saved VR settings at \(path) could not be read. They were left untouched."
            }
        }
    }

    private struct State: Codable {
        var version = 1
        var original: Data?
        var installed: Data
        // The receipt is durable before its registration is replaced. A runtime update or legacy
        // adoption can therefore be interrupted while this previous Halliday registration remains.
        var previousInstalled: Data? = nil
    }

    private struct Change {
        var file: URL
        var journal: URL
        var before: Data?
        var oldJournal: Data?
        var after: Data?
        var newJournal: Data?
    }

    static func windowsPath(_ url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    static func automaticRuntimeRoot(prefix: URL, baseRuntime: URL) -> URL {
        let identity = prefix.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return baseRuntime.appendingPathComponent("AutoOpenXR").appendingPathComponent(key).appendingPathComponent("OpenVR")
    }

    private static func profiles(_ prefix: URL) throws -> [URL] {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let profiles = try fm.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && !["public", "all users"].contains($0.lastPathComponent.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
        guard !profiles.isEmpty else { throw Failure.noUsers }
        return profiles.map { $0.appendingPathComponent("AppData/Local/openvr/openvrpaths.vrpath") }
    }

    private static func read(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    private static func state(_ data: Data, at file: URL) throws -> State {
        guard let value = try? JSONDecoder().decode(State.self, from: data), value.version == 1 else {
            throw Failure.invalidJournal(file.path)
        }
        return value
    }

    private static func matches(_ current: Data?, _ state: State) -> Bool {
        current == state.installed || current == state.original ||
            (state.previousInstalled.map { current == $0 } ?? false)
    }

    private static func belongsToHalliday(_ data: Data?, runtime: URL) -> Bool {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = json["runtime"] as? [String] else { return false }
        return paths == [windowsPath(runtime)]
    }

    /// Read the saved original provider without writing registration or loading
    /// a DLL. Multiple Windows profiles must agree before sharing one broker
    /// configuration; differing providers remain restorable but are not guessed.
    static func originalRuntimePaths(prefix: URL, runtime: URL) throws -> [String] {
        var common: [String]?
        for file in try profiles(prefix) {
            let before = try read(file)
            let original: Data?
            let journal = file.appendingPathExtension("halliday-state.json")
            if let bytes = try read(journal) {
                let saved = try state(bytes, at: journal)
                guard matches(before, saved) else { throw Failure.changed(file.path) }
                original = saved.original
            } else if belongsToHalliday(before, runtime: runtime) {
                original = try read(file.deletingLastPathComponent().appendingPathComponent("openvrpaths.vrpath.before-halliday"))
            } else { original = before }
            let json = original.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let paths = (json?["runtime"] as? [String]) ?? []
            if let common, common != paths { return [] }
            common = paths
        }
        return common ?? []
    }

    private static func write(_ data: Data?, to file: URL) throws {
        let fm = FileManager.default
        if let data {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } else if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }

    /// Validate every profile before writing any; roll back earlier profiles on an I/O failure.
    private static func apply(_ changes: [Change], installing: Bool) throws {
        var started: [Change] = []
        do {
            for change in changes {
                // Preserve the original before installing; remove the receipt only after undo.
                started.append(change)
                if installing { try write(change.newJournal, to: change.journal) }
                try write(change.after, to: change.file)
                if !installing { try write(change.newJournal, to: change.journal) }
            }
        } catch {
            for change in started.reversed() {
                // Keep the durable journal if rollback itself fails, so a later Undo can recover.
                do {
                    try write(change.before, to: change.file)
                    try write(change.oldJournal, to: change.journal)
                } catch { /* The receipt remains available for recovery. */ }
            }
            throw error
        }
    }

    @discardableResult
    static func install(prefix: URL, runtime: URL) throws -> [URL] {
        let fm = FileManager.default
        let z = prefix.appendingPathComponent("dosdevices/z:")
        guard (try? fm.destinationOfSymbolicLink(atPath: z.path)) == "/" else { throw Failure.unavailableZDrive }
        let json: [String: Any] = ["jsonid": "vrpathreg", "version": 1,
            "runtime": [windowsPath(runtime)],
            "config": [windowsPath(runtime.appendingPathComponent("config"))],
            "log": [windowsPath(runtime.appendingPathComponent("logs"))]]
        let installed = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let changes = try profiles(prefix).map { file -> Change in
            let journal = file.appendingPathExtension("halliday-state.json")
            let before = try read(file), oldJournal = try read(journal)
            let original: Data?
            if let oldJournal {
                let previous = try state(oldJournal, at: journal)
                guard matches(before, previous) else { throw Failure.changed(file.path) }
                original = previous.original
            } else if belongsToHalliday(before, runtime: runtime) {
                // Adopt a registration made by an older Halliday, including its legacy backup.
                original = try read(file.deletingLastPathComponent().appendingPathComponent("openvrpaths.vrpath.before-halliday"))
            } else {
                original = before
            }
            let receipt = try JSONEncoder().encode(State(original: original, installed: installed, previousInstalled: before))
            return Change(file: file, journal: journal, before: before, oldJournal: oldJournal,
                          after: installed, newJournal: receipt)
        }
        try fm.createDirectory(at: runtime.appendingPathComponent("config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: runtime.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try apply(changes, installing: true)
        return changes.map(\.file)
    }

    static func uninstall(prefix: URL, runtime: URL) throws {
        let changes = try profiles(prefix).compactMap { file -> Change? in
            let journal = file.appendingPathExtension("halliday-state.json")
            let before = try read(file), oldJournal = try read(journal)
            if let oldJournal {
                let previous = try state(oldJournal, at: journal)
                guard matches(before, previous) else { throw Failure.changed(file.path) }
                return Change(file: file, journal: journal, before: before, oldJournal: oldJournal,
                              after: previous.original, newJournal: nil)
            }
            // Never restore a legacy backup over a different runtime's current registration.
            guard belongsToHalliday(before, runtime: runtime) else { return nil }
            let original = try read(file.deletingLastPathComponent().appendingPathComponent("openvrpaths.vrpath.before-halliday"))
            return Change(file: file, journal: journal, before: before, oldJournal: nil,
                          after: original, newJournal: nil)
        }
        try apply(changes, installing: false)
    }
}
