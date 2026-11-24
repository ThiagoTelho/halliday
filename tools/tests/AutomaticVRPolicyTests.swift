import Foundation

@main struct AutomaticVRPolicyTests {
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var failures = 0
        private var successes = 0
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        func running() -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
        func record(_ valid: Bool) {
            lock.lock(); defer { lock.unlock() }
            if valid { successes += 1 } else { failures += 1 }
        }
        func result() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (successes, failures) }
    }

    static func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func check(_ condition: @autoclosure () throws -> Bool) rethrows {
        let valid = try condition(); precondition(valid)
    }

    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/halliday-policy-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/OpenVR/runtime-policy.json")
        let policy = AutomaticVRPolicy(url: file)
        let date: (Double) -> Date = { Date(timeIntervalSince1970: $0) }
        precondition(!fm.fileExists(atPath: file.path), "initialization must perform no I/O")
        precondition(policy.update(hallidayReady: true, worn: true, externalActive: false, now: date(2_000)))
        let original = try Data(contentsOf: file)
        let value = try json(file)
        precondition(Set(value.keys) == ["version", "updated_unix_ms", "halliday_ready", "psvr2_worn", "external_active"])
        precondition(value["version"] as? Int == 1 && value["updated_unix_ms"] as? Int64 == 2_000_000)
        precondition(value["halliday_ready"] as? Bool == true && value["psvr2_worn"] as? Bool == true)
        precondition(value["external_active"] as? Bool == false && policy.lastError == nil && policy.takeError() == nil)
        // No writes within the timer, including a desired-state change.
        precondition(!policy.update(hallidayReady: false, worn: false, externalActive: true, now: date(2_000.499)))
        try check(try Data(contentsOf: file) == original)
        precondition(policy.update(hallidayReady: true, worn: true, externalActive: false, now: date(2_000.5)))
        try check(try json(file)["updated_unix_ms"] as? Int64 == 2_000_500)
        precondition(policy.shutdown(now: date(2_000.501)), "shutdown bypasses heartbeat throttling")
        try check(try json(file)["halliday_ready"] as? Bool == false)
        try check(try json(file)["psvr2_worn"] as? Bool == false)
        // A backwards wall clock refreshes immediately rather than retaining a
        // future ready timestamp, and does not permanently suppress later updates.
        precondition(policy.update(hallidayReady: true, worn: false, externalActive: true, now: date(1_999)))
        try check(try json(file)["updated_unix_ms"] as? Int64 == 1_999_000)
        precondition(!policy.update(hallidayReady: true, worn: false, externalActive: true, now: date(1_999.499)))
        precondition(policy.update(hallidayReady: true, worn: false, externalActive: true, now: date(1_999.5)))
        let bounded = try Data(contentsOf: file)
        for invalid in [Double.nan, .infinity, -.infinity, -1, Double(Int64.max)] {
            precondition(!policy.update(hallidayReady: true, worn: false, externalActive: true, now: date(invalid)))
            try check(try Data(contentsOf: file) == bounded)
        }
        precondition(policy.takeError() != nil && policy.takeError() == nil)
        precondition(policy.update(hallidayReady: true, worn: false, externalActive: true, now: date(2_001)))
        precondition(policy.lastError == nil)

        // Failure is bounded by the same retry clock; fixing the destination
        // recovers without changing the desired headset selection.
        let blocked = root.appendingPathComponent("blocked")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        let failed = AutomaticVRPolicy(url: blocked)
        precondition(!failed.update(hallidayReady: true, worn: true, externalActive: false, now: date(3_000)))
        precondition(failed.takeError() != nil && failed.takeError() == nil)
        precondition(!failed.update(hallidayReady: true, worn: true, externalActive: false, now: date(3_000.5)))
        precondition(failed.takeError() == nil, "identical failure state must not spam logs")
        precondition(!failed.update(hallidayReady: false, worn: false, externalActive: true, now: date(3_001)))
        precondition(failed.takeError() != nil, "a changed logical state can report its failure once")
        try fm.removeItem(at: blocked)
        precondition(!failed.update(hallidayReady: false, worn: false, externalActive: true, now: date(3_001.1)))
        precondition(!fm.fileExists(atPath: blocked.path), "failed writes cannot cause per-frame retry I/O")
        precondition(failed.update(hallidayReady: false, worn: false, externalActive: true, now: date(3_001.5)))
        precondition(failed.lastError == nil && failed.takeError() == nil)

        let victim = root.appendingPathComponent("victim.json")
        try Data("preserve".utf8).write(to: victim)
        let link = root.appendingPathComponent("file-link.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: victim)
        precondition(!AutomaticVRPolicy(url: link).update(hallidayReady: true, worn: true, externalActive: false, now: date(4_000)))
        try check(try Data(contentsOf: victim) == Data("preserve".utf8))
        let directoryLink = root.appendingPathComponent("directory-link")
        try fm.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        precondition(!AutomaticVRPolicy(url: directoryLink.appendingPathComponent("redirect.json"))
            .update(hallidayReady: true, worn: true, externalActive: false, now: date(4_000)))
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("redirect.json").path))
        let dangling = root.appendingPathComponent("dangling.json")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("absent.json"))
        precondition(!AutomaticVRPolicy(url: dangling).update(hallidayReady: true, worn: true, externalActive: false, now: date(4_000)))

        // Independent concurrent readers must never observe partial JSON during
        // replacements. This tests the filesystem publication, not an in-memory mirror.
        let reads = Reads(), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while reads.running() {
                let data = try? Data(contentsOf: file)
                let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                reads.record(j?["version"] as? Int == 1 && j?.count == 5)
            }
            finished.signal()
        }
        for index in 0..<100 {
            precondition(policy.update(hallidayReady: index.isMultiple(of: 2), worn: index.isMultiple(of: 3),
                externalActive: index.isMultiple(of: 5), now: date(5_000 + Double(index))))
        }
        reads.stop()
        precondition(finished.wait(timeout: .now() + 5) == .success)
        let (complete, partial) = reads.result()
        precondition(complete > 0 && partial == 0, "observed \(partial) partial/invalid snapshots")
        print("PASS AutomaticVRPolicy: exact JSON, 500ms heartbeat/retry, shutdown, backwards/invalid clocks, failure recovery, symlink preservation, \(complete) complete concurrent reads")
    }
}
