import Foundation

@main struct ExternalVRActivityTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/halliday-external-activity-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("stats.json")
        let activity = ExternalVRActivity(statsURL: file)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(ExternalVRActivity.statusURL(originalManifest: "C:\\Vendor\\runtime.json") == nil,
                     "Unknown installed provider acquired a connection probe")
        precondition(ExternalVRActivity.statusURL(originalManifest: "C:\\Provider\\custom-runtime.json") == nil,
                     "A provider-specific manifest acquired an implicit telemetry probe")
        precondition(ExternalVRActivity.statusURL(originalManifest: "C:\\Vendor\\runtime.json", configuredPath: file.path) == file)
        precondition(ExternalVRActivity.statusURL(originalManifest: "C:\\Vendor\\runtime.json", configuredPath: "relative.json") == nil)
        func write(_ text: String, age: TimeInterval = 0) throws {
            try Data(text.utf8).write(to: file, options: .atomic)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        precondition(!activity.isAvailable(now: now), "Missing telemetry selected an external provider")
        try write("{\"connected\":true,\"hs_status\":{\"tracking\":0,\"worn\":false},\"fps\":0}")
        precondition(activity.isAvailable(now: now), "Connected menu/unworn client was rejected")
        for age in [0.0, 1.0, 3.0, -0.5] {
            try write("{\"connected\":true}", age: age)
            precondition(activity.isAvailable(now: now), "Valid freshness boundary rejected: \(age)")
        }
        for age in [3.001, 60, -0.501, -30] {
            try write("{\"connected\":true}", age: age)
            precondition(!activity.isAvailable(now: now), "Stale/future telemetry accepted: \(age)")
        }
        let invalid = ["", "{broken", "{}", "null", "[]", "true",
            "{\"connected\":false}", "{\"connected\":\"true\"}",
            "{\"connected\":null}", "{\"connected\":0}", "{\"connected\":1}",
            "{\"connected\":2}", "{\"connected\":1.0}", "{\"connected\":[]} ",
            "{\"connected\":{}}", "{\"connected\":NaN}", "{\"connected\":Infinity}",
            "{\"connected\":true,\"fps\":NaN}", "{\"connected\":true} trailing"]
        for text in invalid {
            try write(text)
            precondition(!activity.isAvailable(now: now), "Malformed or non-Boolean connection accepted")
        }
        try write("{\"connected\":true}")
        for badNow in [Double.nan, Double.infinity, -Double.infinity] {
            precondition(!activity.isAvailable(now: Date(timeIntervalSince1970: badNow)), "Nonfinite time accepted")
        }
        let prefix = "{\"connected\":true,\"padding\":\""
        let suffix = "\"}"
        let exact = prefix + String(repeating: "x", count: 128 * 1024 - prefix.utf8.count - suffix.utf8.count) + suffix
        try write(exact)
        precondition(activity.isAvailable(now: now), "128KiB valid file rejected")
        try write(exact + " ")
        precondition(!activity.isAvailable(now: now), "Oversized file accepted")
        try write("{\"connected\":true}")
        let link = root.appendingPathComponent("link.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        precondition(!ExternalVRActivity(statsURL: link).isAvailable(now: now), "Leaf symlink accepted")
        let linkedParent = root.appendingPathComponent("linked-parent")
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: root)
        precondition(!ExternalVRActivity(statsURL: linkedParent.appendingPathComponent("stats.json")).isAvailable(now: now),
                     "Symlink ancestor accepted")
        let alias = URL(fileURLWithPath: "/tmp").appendingPathComponent(root.lastPathComponent).appendingPathComponent("stats.json")
        precondition(!ExternalVRActivity(statsURL: alias).isAvailable(now: now), "Noncanonical /tmp symlink alias accepted")
        precondition(!ExternalVRActivity(statsURL: root).isAvailable(now: now), "Directory accepted")
        precondition(!ExternalVRActivity(statsURL: URL(string: "https://example.invalid/stats.json")!).isAvailable(now: now))
        let pipe = root.appendingPathComponent("pipe")
        precondition(mkfifo(pipe.path, 0o600) == 0)
        precondition(!ExternalVRActivity(statsURL: pipe).isAvailable(now: now), "Pipe accepted")
        print("PASS: fresh connected-only external-provider availability, tracking0/unworn, exact3s/500ms boundaries, strictJSON Bool, malformed/nonfinite times, bounded128KiB, symlink/ancestor/directory/pipe rejection")
    }
}
