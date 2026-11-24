import AppKit
import Darwin
import Foundation

/// Explicit Resume is the only game-menu action allowed to activate a Mac app.
/// The runtime's Windows PID is evidence of a producer, never a native PID.
struct GameResumeFocus {
    struct Producer: Equatable {
        let name: String
        let pid: UInt32
        let nativePID: pid_t?
        let lease: String
    }

    struct Candidate {
        let identity: NativeProcessIdentity
        let parentPID: pid_t
        let image: String
        let hasWindow: Bool
        let canActivate: Bool
    }

    struct Target: Equatable {
        let producer: Producer
        let identity: NativeProcessIdentity
    }

    struct Request {
        let producer: Producer
        let revision: UInt64
        let originalFrontmostPID: pid_t?

        func accepts(producer current: Producer, revision currentRevision: UInt64,
                     presenting: Bool, dashboard: Bool, frontmostPID: pid_t?, targetPID: pid_t) -> Bool {
            presenting && !dashboard && producer == current && revision == currentRevision
                && (frontmostPID == originalFrontmostPID || frontmostPID == targetPID)
        }
    }

    static func basename(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    }

    private static func isGame(_ candidate: Candidate) -> Bool {
        let name = basename(candidate.image)
        let forbidden = ["steam.exe", "steamwebhelper.exe", "openxrhelper64.exe", "winewrapper.exe",
                         "wineserver", "wine", "explorer.exe", "services.exe", "halliday"]
        return candidate.identity.pid > 0 && candidate.hasWindow && candidate.canActivate
            && !forbidden.contains(name) && !name.isEmpty
    }

    /// Ambiguity is a no-op. A helper can name only its verified native parent
    /// with a real Mac window; the helper, launcher and Steam are never targets.
    static func select(producer: Producer, candidates: [Candidate]) -> Target? {
        guard producer.pid > 0, !producer.name.isEmpty, !producer.lease.isEmpty else { return nil }
        let matching: [Candidate]
        if basename(producer.name) == "openxrhelper64.exe" {
            // A globally unique helper is not producer evidence. Only an
            // independently proven native owner may nominate its own parent.
            guard let native = producer.nativePID else { return nil }
            let helpers = candidates.filter {
                $0.identity.pid == native && basename($0.image) == "openxrhelper64.exe"
            }
            guard helpers.count == 1, let parent = helpers.first?.parentPID else { return nil }
            matching = candidates.filter { $0.identity.pid == parent }
        } else if let native = producer.nativePID {
            matching = candidates.filter { $0.identity.pid == native }
        } else {
            // Count every same-image process before checking windows. Otherwise
            // an unrelated bottle's visible game could replace the real owner
            // whose window is still loading, hidden or unavailable.
            matching = candidates.filter { basename($0.image) == basename(producer.name) }
        }
        guard matching.count == 1, isGame(matching[0]) else { return nil }
        return Target(producer: producer, identity: matching[0].identity)
    }

    /// The same producer and native start time must survive the menu. No action
    /// is needed when the game is already frontmost, or its PID was recycled.
    static func shouldActivate(_ target: Target?, producer: Producer,
                               frontmostPID: pid_t?, currentIdentity: NativeProcessIdentity?) -> Bool {
        guard let target, target.producer == producer, target.identity == currentIdentity,
              target.identity.pid != frontmostPID else { return false }
        return true
    }

    /// Once a producer has been bound to a native process, its old lease may
    /// not switch to another same-name process after the first one dies.
    static func preferRemembered(_ remembered: Target?, discovered: Target?, producer: Producer) -> Target? {
        if let remembered, remembered.producer == producer { return remembered }
        return discovered?.producer == producer ? discovered : nil
    }

    /// The owned `ps` child is bounded and runs away from the compositor's
    /// main thread. It never launches a game or asks for a permission.
    private static func processRows() -> [(pid_t, pid_t, String)] {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0, data.count <= 2 * 1024 * 1024 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(8192).compactMap { line in
            let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3, let pid = pid_t(parts[0]), let parent = pid_t(parts[1]) else { return nil }
            return (pid, parent, String(parts[2]))
        }
    }

    @MainActor
    static func discover(producer: Producer) async -> Target? {
        let rows = await Task.detached(priority: .userInitiated) { processRows() }.value
        guard !Task.isCancelled else { return nil }
        let windows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let windowPIDs = Set(windows.compactMap { item -> pid_t? in
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let pid = item[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 80, rect.height > 80 else { return nil }
            return pid
        })
        // Only inspect identity for matching images and, for a helper, its parent.
        let helperParents = Set(rows.filter { basename(image(command: $0.2)) == "openxrhelper64.exe" }.map { $0.1 })
        let own = ProcessInfo.processInfo.processIdentifier
        let candidates = rows.compactMap { row -> Candidate? in
            guard row.0 != own else { return nil }
            let commandImage = image(command: row.2)
            var bytes = [CChar](repeating: 0, count: 4096)
            let length = bytes.withUnsafeMutableBytes { proc_pidpath(row.0, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { return nil }
            let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let nativeImage = commandImage.contains(":\\") || commandImage.contains(":/") ? commandImage : path
            guard row.0 == producer.nativePID || basename(nativeImage) == basename(producer.name)
                    || helperParents.contains(row.0) else { return nil }
            guard let identity = NativeProcessIdentity.capture(pid: row.0,
                expectedBasename: URL(fileURLWithPath: path).lastPathComponent) else { return nil }
            let app = NSRunningApplication(processIdentifier: row.0)
            return Candidate(identity: identity, parentPID: row.1,
                image: nativeImage,
                hasWindow: windowPIDs.contains(row.0), canActivate: app?.activationPolicy == .regular)
        }
        return select(producer: producer, candidates: candidates)
    }

    /// `ps` prints Wine's first Windows image with unquoted spaces in its path.
    /// Parse that image only: later helper/launcher arguments are not identities.
    static func image(command: String) -> String {
        let value = command.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        let chars = Array(value)
        if chars.count > 2, chars[1] == ":", chars[2] == "\\" || chars[2] == "/",
           let end = value.range(of: ".exe", options: .caseInsensitive)?.upperBound {
            return String(value[..<end])
        }
        return value.split(separator: " ").first.map(String.init) ?? ""
    }
}
