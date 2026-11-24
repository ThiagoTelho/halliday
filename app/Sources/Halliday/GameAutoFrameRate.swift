import Foundation

/// Host policy over COMPLETE producer publications. Half-limited FPS cannot
/// establish full-rate headroom; recovery always uses a bounded full-rate probe.
struct GameAutoFrameRate: Sendable {
    struct Producer: Equatable, Sendable { let pid: UInt32; let epoch: UInt64; let revision: UInt64 }
    private(set) var mode: GameHalfFrameRateMode
    private(set) var halfFrameRate: Bool
    private(set) var probing = false
    private var producer: Producer?
    private var physicalHz = 0.0
    private var lastTime: Double?
    private var lastFrames: UInt64?
    private var anchorTime: Double?
    private var anchorFrames: UInt64 = 0
    private var settleUntil = 0.0
    private var deficitWindows = 0
    private var probeAt = Double.infinity
    private var probeFailures = 0
    private var blockedSince: Double?
    static let window = 0.5, settle = 0.25, engageFraction = 0.97
    static let halfDwell = 5.0, probeDuration = 1.0

    init(mode: GameHalfFrameRateMode = .off) { self.mode = mode; halfFrameRate = mode == .on }
    mutating func setMode(_ next: GameHalfFrameRateMode) {
        guard next != mode else { return } // unrelated settings must not restart Auto
        self = Self(mode: next)
    }
    mutating func resetProducer() {
        self = Self(mode: mode)
    }
    private mutating func discard(_ now: Double, abortProbe: Bool = true) {
        anchorTime = nil; deficitWindows = 0; settleUntil = now + Self.settle
        if abortProbe && probing { probing = false; halfFrameRate = true; probeAt = now + 8 }
    }
    private mutating func startHalf(_ now: Double, failedProbe: Bool) {
        halfFrameRate = true; probing = false; anchorTime = nil; deficitWindows = 0
        if failedProbe { probeFailures = min(3, probeFailures + 1) }
        let delay = failedProbe ? [8.0,16.0,30.0][max(0,probeFailures-1)] : Self.halfDwell
        probeAt = now + delay; settleUntil = now + Self.settle
    }
    /// consumerBlocked excludes sustained capture starvation, while individual
    /// normal mailbox-credit misses do not destroy every observation window.
    mutating func observe(now: Double, frames: UInt64, producer next: Producer,
                          physicalHz hz: Double, eligible: Bool, consumerBlocked: Bool = false) -> Bool {
        guard mode == .auto else { return halfFrameRate }
        guard now.isFinite, hz.isFinite, (20...240).contains(hz) else { return halfFrameRate }
        let reset = producer != next || abs(physicalHz-hz) > 0.01 ||
            (lastTime.map { now < $0 || now-$0 > 0.25 } ?? false) ||
            (lastFrames.map { frames < $0 } ?? false)
        lastTime = now; lastFrames = frames
        if reset {
            producer = next; physicalHz = hz; halfFrameRate = false; probing = false
            probeFailures = 0; probeAt = .infinity; blockedSince = nil; discard(now)
        }
        guard eligible else { blockedSince = nil; discard(now); return halfFrameRate }
        if consumerBlocked {
            if blockedSince == nil { blockedSince = now }
            if now-(blockedSince ?? now) >= 0.1 { discard(now) }
            return halfFrameRate
        }
        if let since = blockedSince, now-since >= 0.1 { discard(now) }
        blockedSince = nil
        if halfFrameRate {
            guard now >= probeAt else { return true }
            halfFrameRate = false; probing = true; anchorTime = nil
            settleUntil = now + Self.settle
            return false
        }
        guard now >= settleUntil else { return false }
        guard let began = anchorTime else { anchorTime = now; anchorFrames = frames; return false }
        let elapsed = now-began
        guard elapsed >= (probing ? Self.probeDuration : Self.window) else { return false }
        let count = frames-anchorFrames, expected = elapsed*hz
        // A producer may keep its lease during a loading screen. No new
        // stereo pair is absence of evidence, not a sustainable slow workload.
        guard count > 0 else { discard(now); return halfFrameRate }
        if probing {
            // One publication of phase/count quantization is not lack of headroom.
            let full = Double(count) >= expected-max(1, expected*0.01)
            if full { probing = false; probeFailures = 0; anchorTime = now; anchorFrames = frames }
            else { startHalf(now, failedProbe: true) }
        } else {
            deficitWindows = Double(count) < expected*Self.engageFraction ? deficitWindows+1 : 0
            anchorTime = now; anchorFrames = frames
            if deficitWindows >= 2 { startHalf(now, failedProbe: false) }
        }
        return halfFrameRate
    }
}
