import Foundation

/// Pure host-nanosecond presentation model. It never waits or schedules work.
/// Targets are the middle of scanout, preserving the compositor's half-period
/// centre convention. Presentation timestamps describe the start of that frame.
struct LateDisplayTimeline: Sendable {
    private(set) var epoch: UInt64 = 1
    private(set) var periodNs: Int64
    private(set) var phaseNs: Int64?
    private(set) var presentationSamples = 0
    private var leads: [Int64] = []

    init(period: Double = 1.0 / 120) {
        periodNs = Self.validPeriod(period) ?? 8_333_333
    }

    var period: Double { Double(periodNs) * 1e-9 }
    var centreOffsetNs: Int64 { periodNs / 2 }
    /// Diagnostic commit-to-presentation delay, including phase wait. Never add
    /// this to a query before snapping to the refresh grid: that counts phase
    /// waiting twice and can skip a perfectly reachable refresh.
    var estimatedLeadNs: Int64 {
        // A bounded median follows a sustained change in the presentation path
        // without letting one queued/stalled drawable retarget every next frame.
        guard !leads.isEmpty else { return periodNs * 2 }
        let ordered = leads.sorted()
        return ordered[ordered.count / 2]
    }

    /// A new physical clock invalidates every callback from its predecessor.
    @discardableResult
    mutating func configure(period: Double) -> Bool {
        guard let next = Self.validPeriod(period) else { return false }
        guard next != periodNs else { return true }
        periodNs = next
        reset()
        return true
    }

    /// Also retire an old clock on stop/reconnect even when its rate is unchanged.
    mutating func reset() {
        epoch = epoch == UInt64.max ? 1 : epoch + 1
        phaseNs = nil; presentationSamples = 0; leads.removeAll(keepingCapacity: true)
    }

    mutating func observe(presentedNs: Int64, committedNs: Int64, epoch expected: UInt64) {
        guard expected == epoch, committedNs > 0, presentedNs > committedNs else { return }
        let (lead, overflow) = presentedNs.subtractingReportingOverflow(committedNs)
        guard !overflow, lead <= periodNs * 8 else { return }
        if let phase = phaseNs {
            guard presentedNs > phase else { return } // duplicate/out-of-order callback
            let elapsed = Double(presentedNs - phase) / Double(periodNs)
            let steps = max(1, Int64(elapsed.rounded()))
            let (advance, multiplyOverflow) = steps.multipliedReportingOverflow(by: periodNs)
            let (predicted, addOverflow) = phase.addingReportingOverflow(advance)
            guard !multiplyOverflow, !addOverflow else { return }
            let residual = presentedNs - predicted
            // Presentation callback jitter must not move the phase by a whole
            // refresh. A mode/clock change requires explicit configure/reset.
            guard abs(residual) <= periodNs / 4 else { return }
            phaseNs = predicted + residual / 8
        } else {
            phaseNs = presentedNs
        }
        leads.append(lead)
        if leads.count > 9 { leads.removeFirst() }
        presentationSamples += 1
    }

    /// Pick the next plausible presentation slot at the late query, not the
    /// expired slot captured before scene rendering/drawable acquisition.
    /// This updates prediction only: it adds no sleep, present delay or FIFO.
    func chooseTarget(originalTargetNs: Int64, queryNs: Int64, epoch expected: UInt64,
                      processingBudgetNs: Int64 = 0) -> Int64? {
        guard expected == epoch, queryNs > 0, originalTargetNs > 0,
              processingBudgetNs >= 0, processingBudgetNs <= 100_000_000 else { return nil }
        // An optional caller-measured encode/submission/GPU budget may define
        // eligibility. Zero means no such measurement exists: only retire an
        // already expired start, preserving existing future prediction policy.
        let (earliest, overflow) = queryNs.addingReportingOverflow(processingBudgetNs)
        guard !overflow else { return nil }
        let (originalStart, subtractOverflow) = originalTargetNs.subtractingReportingOverflow(centreOffsetNs)
        guard !subtractOverflow, originalStart > 0 else { return nil }
        let presentation: Int64
        if originalStart >= earliest {
            // Do not replace a legitimate future target merely because a past
            // frame waited for vblank. This is retargeting, not a new delay.
            presentation = originalStart
        } else if let phase = phaseNs {
            let slots = max(0, ceil(Double(earliest - phase) / Double(periodNs)))
            guard slots <= Double(Int64.max / periodNs) else { return nil }
            let (advance, multiplyOverflow) = Int64(slots).multipliedReportingOverflow(by: periodNs)
            let (next, addOverflow) = phase.addingReportingOverflow(advance)
            guard !multiplyOverflow, !addOverflow, next >= earliest else { return nil }
            presentation = next
        } else {
            // Startup retains the existing target's phase. If it expired during
            // scene/drawable work, advance it by whole physical refresh periods.
            let slots = max(0, ceil(Double(earliest - originalStart) / Double(periodNs)))
            guard slots <= Double(Int64.max / periodNs) else { return nil }
            let (advance, multiplyOverflow) = Int64(slots).multipliedReportingOverflow(by: periodNs)
            let (next, addOverflow) = originalStart.addingReportingOverflow(advance)
            guard !multiplyOverflow, !addOverflow, next >= earliest else { return nil }
            presentation = next
        }
        let (target, addOverflow) = presentation.addingReportingOverflow(centreOffsetNs)
        let (horizon, horizonOverflow) = target.subtractingReportingOverflow(queryNs)
        // Tracker prediction is already capped at 100 ms; do not fabricate a
        // later accurate pose when the display path has fallen outside it.
        guard !addOverflow, !horizonOverflow, horizon > 0, horizon <= 100_000_000 else { return nil }
        return target
    }

    private static func validPeriod(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, (1.0 / 240...1.0 / 20).contains(seconds) else { return nil }
        return Int64((seconds * 1e9).rounded())
    }
}

/// The display thread, GPU completion callbacks and MainActor share one clock.
/// A submission check and epoch retirement are serialized, so a callback cannot
/// pass an unlocked epoch check and then commit after its clock was retired.
final class LateDisplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timeline: LateDisplayTimeline
    init(period: Double = 1.0 / 120) { timeline = LateDisplayTimeline(period: period) }
    var epoch: UInt64 { lock.lock(); defer { lock.unlock() }; return timeline.epoch }
    var period: Double { lock.lock(); defer { lock.unlock() }; return timeline.period }
    @discardableResult
    func configure(period: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }; return timeline.configure(period: period)
    }
    func reset() { lock.lock(); defer { lock.unlock() }; timeline.reset() }
    /// A stale output must not retire a newer replacement clock.
    @discardableResult
    func retireIfCurrent(epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard timeline.epoch == epoch else { return false }
        timeline.reset(); return true
    }
    /// Serialize mailbox retirement with the epoch read. Otherwise two reset
    /// callers could observe2/3 and retire the mailbox in reverse order.
    func withCurrentState(_ body: (UInt64, Double) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(timeline.epoch, timeline.period)
    }

    func isCurrent(epoch: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return timeline.epoch == epoch }
    func chooseTarget(originalTargetNs: Int64, queryNs: Int64, epoch: UInt64,
                      processingBudgetNs: Int64 = 0) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return timeline.chooseTarget(originalTargetNs: originalTargetNs, queryNs: queryNs,
                                     epoch: epoch, processingBudgetNs: processingBudgetNs)
    }
    func observe(presentedNs: Int64, committedNs: Int64, epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        timeline.observe(presentedNs: presentedNs, committedNs: committedNs, epoch: epoch)
    }
    /// The body must only commit the already encoded frame: no blocking work,
    /// callbacks into this clock, drawable acquisition or pose lookup under lock.
    @discardableResult
    func submitIfCurrent(epoch: UInt64, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard timeline.epoch == epoch else { return false }
        body(); return true
    }
}
