import Foundation

/// Bounded observed presentation telemetry. Refresh gaps describe intervals
/// between actual presented callbacks, not game FPS or a claimed photon time.
final class CompositorPresentationTelemetry: @unchecked Sendable {
    struct Frame: Sendable {
        let epoch: UInt64
        let pulse: UInt64
        let scene: UInt64
        let nativeSequence: UInt64
        let generated: Bool
        let targetNs: Int64
        let committedNs: Int64
        let drawableWaitNs: Int64
    }
    struct Summary: Sendable {
        let epoch: UInt64
        let frames: Int
        let native: Int
        let generated: Int
        let refreshGaps: Int
        let rejectedCallbacks: Int
        let intervalP50Ms: Double
        let intervalP95Ms: Double
        let intervalP99Ms: Double
        let intervalMaxMs: Double
        let commitToPresentP95Ms: Double
        let gpuQueueP95Ms: Double
        let gpuWorkP95Ms: Double
        let targetErrorP95Ms: Double
        let drawableWaitP95Ms: Double
        let lastPulse: UInt64
        let lastScene: UInt64
        let lastNativeSequence: UInt64
    }
    private let lock = NSLock()
    private let window: Int
    private let report: @Sendable (Summary) -> Void
    private var epoch: UInt64 = 0
    private var periodNs: Int64 = 8_333_333
    private var previousPresented: Int64?
    private var frames = 0, native = 0, generated = 0, gaps = 0, rejected = 0
    private var intervals: [Double] = [], lead: [Double] = [], gpuQueue: [Double] = []
    private var gpuWork: [Double] = [], targetError: [Double] = [], drawableWait: [Double] = []
    init(window: Int = 600, report: @escaping @Sendable (Summary) -> Void) {
        precondition(window >= 2 && window <= 10_000)
        self.window = window; self.report = report
    }
    func configure(epoch: UInt64, period: Double) {
        guard epoch > 0, period.isFinite, period > 0, period < 1 else { return }
        lock.lock(); defer { lock.unlock() }
        let ns = Int64((period * 1e9).rounded())
        guard self.epoch != epoch || periodNs != ns else { return }
        self.epoch = epoch; periodNs = ns; previousPresented = nil
        clearWindow()
    }
    private func clearWindow() {
        frames = 0; native = 0; generated = 0; gaps = 0; rejected = 0
        intervals.removeAll(keepingCapacity: true); lead.removeAll(keepingCapacity: true)
        gpuQueue.removeAll(keepingCapacity: true); gpuWork.removeAll(keepingCapacity: true)
        targetError.removeAll(keepingCapacity: true); drawableWait.removeAll(keepingCapacity: true)
    }
    func gpu(_ frame: Frame, startNs: Int64, endNs: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard frame.epoch == epoch, startNs > 0, endNs >= startNs else { return }
        // GPU feedback can arrive before or after presented feedback; these
        // distributions explicitly describe the bounded GPU callback window.
        if startNs >= frame.committedNs && gpuQueue.count < window * 2 {
            gpuQueue.append(Double(startNs - frame.committedNs) / 1e6)
        }
        if gpuWork.count < window * 2 { gpuWork.append(Double(endNs - startNs) / 1e6) }
    }
    func presented(_ frame: Frame, atNs shown: Int64) {
        lock.lock()
        guard frame.epoch == epoch, shown > frame.committedNs else { lock.unlock(); return }
        if let previous = previousPresented {
            guard shown > previous else { rejected += 1; lock.unlock(); return }
            let delta = shown - previous
            intervals.append(Double(delta) / 1e6)
            if delta > periodNs + periodNs / 2 {
                gaps += max(1, Int((Double(delta) / Double(periodNs)).rounded()) - 1)
            }
        }
        previousPresented = shown
        frames += 1
        if frame.generated { generated += 1 } else { native += 1 }
        lead.append(Double(shown - frame.committedNs) / 1e6)
        // targetNs uses the existing scanout-centre convention. Actual
        // presentedTime marks presentation start, not the middle row/photons.
        targetError.append(Double(shown + periodNs / 2 - frame.targetNs) / 1e6)
        drawableWait.append(Double(max(0, frame.drawableWaitNs)) / 1e6)
        guard frames == window else { lock.unlock(); return }
        func percentile(_ a: [Double], _ p: Double) -> Double {
            guard !a.isEmpty else { return .nan }
            let s = a.sorted(); return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
        }
        let summary = Summary(epoch: epoch, frames: frames, native: native, generated: generated,
            refreshGaps: gaps, rejectedCallbacks: rejected,
            intervalP50Ms: percentile(intervals, 0.5), intervalP95Ms: percentile(intervals, 0.95), intervalP99Ms: percentile(intervals, 0.99), intervalMaxMs: intervals.max() ?? .nan,
            commitToPresentP95Ms: percentile(lead, 0.95), gpuQueueP95Ms: percentile(gpuQueue, 0.95),
            gpuWorkP95Ms: percentile(gpuWork, 0.95), targetErrorP95Ms: percentile(targetError, 0.95),
            drawableWaitP95Ms: percentile(drawableWait, 0.95), lastPulse: frame.pulse,
            lastScene: frame.scene, lastNativeSequence: frame.nativeSequence)
        clearWindow(); lock.unlock()
        report(summary) // never invoke user/log code while the telemetry lock is held
    }
}
