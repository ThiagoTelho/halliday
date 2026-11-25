// CPU presentation-target analytics. No app, display, GPU or device dependencies.
import Foundation

@main
struct LateDisplayTimelineTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
    }

    static func main() {
        var checks = 0
        for hz in [90.0, 120.0] {
            var clock = LateDisplayTimeline(period: 1 / hz)
            let epoch = clock.epoch, p = clock.periodNs, origin: Int64 = 1_000_000_000
            // A stable display path, including bounded sub-vsync callback jitter.
            for i in 1...12 {
                let jitter = Int64((i % 3) - 1) * 50_000
                let presented = origin + Int64(i) * p + jitter
                clock.observe(presentedNs: presented, committedNs: presented - p * 3 / 2, epoch: epoch)
            }
            require(clock.presentationSamples == 12, "Valid physical-clock samples lost at \(hz)Hz")
            let query = origin + 14 * p
            let original = query + p / 2
            let budget: Int64 = 500_000
            let picked = clock.chooseTarget(originalTargetNs: original, queryNs: query, epoch: epoch, processingBudgetNs: budget)!
            require(picked >= query + budget + p / 2, "Selected target precedes measured readiness")
            // Scene work/drawable acquisition misses three refreshes. Prediction
            // advances to a future slot; no wait is part of this pure function.
            let stalledQuery = query + 3 * p
            let stalled = clock.chooseTarget(originalTargetNs: original, queryNs: stalledQuery, epoch: epoch, processingBudgetNs: budget)!
            require(stalled >= stalledQuery + budget + p / 2, "Expired early target survived stall")
            require(stalled > picked, "Late query did not advance presentation slot")
            require(stalled - stalledQuery <= budget + p * 3 / 2, "Unbounded catch-up target")
            // One stalled drawable is not allowed to move the whole forecast path.
            let leadBefore = clock.estimatedLeadNs
            let presented = origin + 15 * p
            clock.observe(presentedNs: presented, committedNs: presented - 7 * p, epoch: epoch)
            require(clock.estimatedLeadNs == leadBefore, "One long queue sample moved median lead")
            let count = clock.presentationSamples
            clock.observe(presentedNs: presented, committedNs: presented - p, epoch: epoch)
            require(clock.presentationSamples == count, "Duplicate presentation counted twice")
            clock.reset()
            require(clock.chooseTarget(originalTargetNs: original, queryNs: query, epoch: epoch) == nil, "Retired epoch chose a target")
            clock.observe(presentedNs: presented + p, committedNs: presented, epoch: epoch)
            require(clock.presentationSamples == 0, "Retired clock callback contaminated new phase")
            let nextEpoch = clock.epoch
            require(clock.configure(period: 1 / (hz == 90 ? 120 : 90)), "Valid rate change rejected")
            require(clock.epoch != nextEpoch && clock.phaseNs == nil, "Rate change retained old phase")
            require(!clock.configure(period: .nan), "Nonfinite period accepted")
            checks += 12
        }
        // A commit-to-present sample includes its wait for the next vblank.
        // Adding that delay and snapping a second time would skip this still
        // reachable refresh and overpredict exactly one physical period.
        var phaseWait = LateDisplayTimeline(period: 1.0 / 120)
        let e = phaseWait.epoch
        phaseWait.observe(presentedNs: 8_333_333, committedNs: 1_000_000, epoch: e)
        require(phaseWait.chooseTarget(originalTargetNs: 12_499_999, queryNs: 2_000_000,
            epoch: e, processingBudgetNs: 500_000) == 12_499_999,
            "Vblank phase wait was counted twice")
        let gate = LateDisplayClock()
        let oldEpoch = gate.epoch
        var submitted = 0
        require(gate.submitIfCurrent(epoch: oldEpoch) { submitted += 1 }, "Current epoch failed commit gate")
        gate.reset()
        require(!gate.submitIfCurrent(epoch: oldEpoch) { submitted += 1 }, "Retired epoch committed")
        require(submitted == 1, "Retired callback executed submission")
        let current = gate.epoch
        require(gate.chooseTarget(originalTargetNs: 1, queryNs: Int64.max - 1, epoch: current) == nil, "Overflow did not fail closed")
        print("PASS \(checks + 5) late display timeline/epoch assertions (CPU only)")
    }
}
