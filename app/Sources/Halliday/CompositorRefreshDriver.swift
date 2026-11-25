import Foundation

/// One physical clock callback; its identity/start belong to THIS refresh, never
/// to the last MainActor scene. All times use the existing host-nanosecond clock.
struct CompositorDisplayPulse: Sendable {
    let id: UInt64
    let startedNs: Int64
    let targetNs: Int64
    let linkTargetNs: Int64
    let pacedAimNs: Int64?
}

/// A direct, non-MainActor display path. MainActor publishes an immutable
/// renderer/pose/output snapshot; CVDisplayLink (or the pacer thread) offers
/// refreshes even while MainActor's scene/input work is delayed.
final class CompositorRefreshDriver: @unchecked Sendable {
    struct Clock: Equatable, Sendable { let id: UInt64 }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pulseID: UInt64 = 0
    private var active: Clock?
    private var offsetNs: Int64 = 0
    private var handler: (@Sendable (CompositorDisplayPulse) -> Void)?
    func startClock() -> Clock {
        lock.lock(); defer { lock.unlock() }
        generation = max(1, generation &+ 1)
        let clock = Clock(id: generation); active = clock
        return clock
    }
    var isClockRunning: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }
    func isCurrentClock(_ clock: Clock) -> Bool { lock.lock(); defer { lock.unlock() }; return active == clock }
    func stopClock() { lock.lock(); active = nil; handler = nil; lock.unlock() }
    func clearConfiguration() { lock.lock(); handler = nil; lock.unlock() }
    func configure(offsetNs: Int64, handler: @escaping @Sendable (CompositorDisplayPulse) -> Void) {
        lock.lock(); self.offsetNs = offsetNs; self.handler = handler; lock.unlock()
    }
    /// Conventional preview/CADisplayLink fallback. It never duplicates an
    /// active physical-clock pulse and retains the old non-headset behavior.
    func pulseIfUnclocked(startedNs: Int64, targetNs: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard active == nil, startedNs > 0, targetNs > 0, let handler else { return }
        pulseID = max(1, pulseID &+ 1)
        handler(.init(id: pulseID, startedNs: startedNs, targetNs: targetNs,
                      linkTargetNs: targetNs, pacedAimNs: nil))
    }
    /// The handler may only offer/coalesce work; no drawable, GPU wait, pose
    /// lookup, user callback or reentry into this driver is allowed under lock.
    @discardableResult
    func pulse(clock: Clock, startedNs: Int64, baseTargetNs: Int64,
               linkTargetNs: Int64, pacedAimNs: Int64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active == clock, startedNs > 0, baseTargetNs > 0, let handler else { return false }
        let (target, overflow) = baseTargetNs.addingReportingOverflow(offsetNs)
        guard !overflow, target > 0 else { return false }
        pulseID = max(1, pulseID &+ 1)
        handler(.init(id: pulseID, startedNs: startedNs, targetNs: target,
                      linkTargetNs: linkTargetNs, pacedAimNs: pacedAimNs))
        return true
    }
}

struct CompositorPulseFeedback: Sendable {
    var presented: (@Sendable (CompositorDisplayPulse, Double) -> Void)?
    var drawn: (@Sendable (CompositorDisplayPulse, Double) -> Void)?
}
