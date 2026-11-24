import Foundation

/// Fresh connection telemetry from the user's selected external VR provider.
/// An idle application or an old shared-memory file is not an active external headset.
struct ExternalVRActivity {
    let statsURL: URL

    init(statsURL: URL) { self.statsURL = statsURL }

    /// Only an explicitly configured local telemetry file may establish
    /// availability. A registered manifest never proves a connected headset.
    /// Providers without this optional contract retain manual selection.
    static func statusURL(originalManifest: String, configuredPath: String? = nil) -> URL? {
        guard let configuredPath, !configuredPath.isEmpty,
              configuredPath.hasPrefix("/"), !configuredPath.contains("\0") else { return nil }
        return URL(fileURLWithPath: configuredPath)
    }

    private struct Status: Decodable { let connected: Bool }
    private static let maximumBytes = 128 * 1024

    /// Menu/unworn clients may report tracking=0 while still connected. Neither
    /// tracking validity, controller motion nor video FPS is required here.
    /// This returns only availability; raw telemetry is never logged or saved.
    func isAvailable(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince1970.isFinite, statsURL.isFileURL,
              statsURL.host == nil || statsURL.host == "" || statsURL.host == "localhost"
        else { return false }
        let path = statsURL.path
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ $0 != "." && $0 != ".." }) else { return false }
        // The publisher supplies /private/tmp, not its /tmp symlink alias.
        // Refuse symlink ancestors as well as a symlink leaf.
        // Do not use standardizedFileURL: Foundation shortens /private/tmp to
        // its symlink alias /tmp, undoing the caller's canonical path.
        for depth in 1..<parts.count {
            let parent = "/" + parts.prefix(depth).joined(separator: "/")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: parent),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        }

        // O_NOFOLLOW closes the leaf lookup/open race; O_NONBLOCK prevents a
        // substituted pipe from blocking. Inspect the opened file, not a later
        // path lookup, and never allocate according to its reported length.
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= Self.maximumBytes,
              before.st_mtimespec.tv_nsec >= 0, before.st_mtimespec.tv_nsec < 1_000_000_000
        else { return false }
        let modified = Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) * 1e-9
        let age = now.timeIntervalSince1970 - modified
        guard modified.isFinite, age.isFinite, (-0.5...3.0).contains(age) else { return false }

        var bytes = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let received = bytes.withUnsafeMutableBytes {
                read(fd, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if received < 0 { if errno == EINTR { continue }; return false }
            if received == 0 { break }
            count += received
        }
        var after = stat()
        guard count <= Self.maximumBytes, count == before.st_size,
              fstat(fd, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              let status = try? JSONDecoder().decode(Status.self, from: Data(bytes.prefix(count)))
        else { return false }
        return status.connected
    }
}
