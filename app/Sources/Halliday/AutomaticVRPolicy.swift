import Foundation

/// A small, atomic heartbeat for newly launched VR processes. The owner confines
/// this publisher to one actor; it never starts or talks to a headset or runtime.
final class AutomaticVRPolicy {
    private struct State: Equatable {
        var hallidayReady: Bool
        var worn: Bool
        var externalActive: Bool
    }

    private struct Snapshot: Encodable {
        let version = 1
        let updatedUnixMs: Int64
        let hallidayReady: Bool
        let psvr2Worn: Bool
        let externalActive: Bool

        enum CodingKeys: String, CodingKey {
            case version
            case updatedUnixMs = "updated_unix_ms"
            case hallidayReady = "halliday_ready"
            case psvr2Worn = "psvr2_worn"
            case externalActive = "external_active"
        }
    }

    private enum Failure: LocalizedError {
        case invalidClock, symbolicLink(String), invalidParent(String), invalidTarget(String)
        var errorDescription: String? {
            switch self {
            case .invalidClock: "VR selection policy: invalid clock"
            case .symbolicLink(let path): "VR selection policy: refusing symbolic link at \(path)"
            case .invalidParent(let path): "VR selection policy: parent is not a directory at \(path)"
            case .invalidTarget(let path): "VR selection policy: destination is not a regular file at \(path)"
            }
        }
    }

    private let url: URL
    private var lastAttemptMs: Int64?
    private var desired = State(hallidayReady: false, worn: false, externalActive: false)
    private var failureState: State?
    private var failureMessage: String?
    private var pendingError: String?
    private(set) var lastError: String?

    init(url: URL) { self.url = url }

    /// Refreshes at most twice a second, including after a failed write. An
    /// unchanged state still needs a heartbeat so consumers can reject a dead host.
    @discardableResult
    func update(hallidayReady: Bool, worn: Bool, externalActive: Bool = false, now: Date) -> Bool {
        desired = State(hallidayReady: hallidayReady, worn: worn, externalActive: externalActive)
        return publish(now: now, immediate: false)
    }

    /// Invalidate readiness immediately, even between heartbeat deadlines.
    @discardableResult
    func shutdown(now: Date) -> Bool {
        desired.hallidayReady = false
        desired.worn = false
        return publish(now: now, immediate: true)
    }

    /// One diagnostic per logical state/error, rather than a repeated frame log.
    /// A successful retry clears the failure, allowing a later failure to report.
    func takeError() -> String? {
        defer { pendingError = nil }
        return pendingError
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        if failureState != desired || failureMessage != message {
            failureState = desired
            failureMessage = message
            pendingError = message
        }
    }

    private func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return Int64(value.rounded(.down))
    }

    private func publish(now: Date, immediate: Bool) -> Bool {
        guard let nowMs = milliseconds(now) else {
            report(Failure.invalidClock)
            return false
        }
        // A clock moving backwards must not leave a future-dated ready policy
        // in place while waiting for the old deadline. Republish using the new
        // clock immediately; consumers independently enforce freshness limits.
        if !immediate, let last = lastAttemptMs, nowMs >= last, nowMs - last < 500 {
            return false
        }
        lastAttemptMs = nowMs
        do {
            try validateDestination()
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try validateDestination()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Snapshot(updatedUnixMs: nowMs,
                hallidayReady: desired.hallidayReady, psvr2Worn: desired.worn,
                externalActive: desired.externalActive))
            // Foundation stages a complete file and replaces the destination;
            // readers see either complete previous JSON or complete new JSON.
            try data.write(to: url, options: .atomic)
            lastError = nil
            pendingError = nil
            failureState = nil
            failureMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Do not follow a file or parent symlink, including a dangling one. Never
    /// replace another kind of filesystem object with the heartbeat.
    private func validateDestination() throws {
        guard url.isFileURL else { throw Failure.invalidTarget(url.absoluteString) }
        var component = URL(fileURLWithPath: "/", isDirectory: true)
        let parts = url.pathComponents.dropFirst()
        for (index, name) in parts.enumerated() {
            component.appendPathComponent(name)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: component.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw Failure.symbolicLink(component.path) }
            if index == parts.count - 1 {
                guard type == .typeRegular else { throw Failure.invalidTarget(component.path) }
            } else {
                guard type == .typeDirectory else { throw Failure.invalidParent(component.path) }
            }
        }
    }
}
