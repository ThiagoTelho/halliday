import Foundation

/// Optional producer time of the exact published image, not host receipt time.
/// OpenXR intended display time and OpenVR submit-monotonic time have distinct
/// kinds. Only differences within one producer epoch and clock kind are used.
struct GameSourceImageTime: Equatable, Sendable {
    var epoch: UInt64
    var frameIndex: UInt64
    var nanoseconds: Int64
    var clockKind: UInt32

    static let invalid = Self(epoch: 0, frameIndex: 0, nanoseconds: 0, clockKind: 0)
    var isValid: Bool {
        epoch > 0 && frameIndex > 0 && nanoseconds > 0 && (clockKind == 1 || clockKind == 2)
    }

    func interval(since previous: Self) -> Double? {
        guard isValid, previous.isValid, epoch == previous.epoch,
              clockKind == previous.clockKind, frameIndex > previous.frameIndex else { return nil }
        let (delta, overflow) = nanoseconds.subtractingReportingOverflow(previous.nanoseconds)
        guard !overflow, delta > 0 else { return nil }
        return Double(delta) * 1e-9
    }
}

/// Schedules forward prediction between real frames. Never waits for a future
/// source frame, invents a catch-up queue, or predicts farther than half a source interval.
struct GameSpacewarpCadence {
    enum Decision: Equatable {
        case source(resetHistory: Bool)
        case predict(phase: Float)
        case original
    }

    private var sequence: UInt64?
    private var sourceTime = 0.0
    private var imageTiming: GameSourceImageTime?
    private var firstTarget = 0.0
    private var lastTarget = 0.0
    private var interval = 0.0
    private var expected = 0.0
    private var predictedPhase: Float?

    mutating func reset() { self = Self() }

    mutating func update(sequence next: UInt64, sourceTime nextTime: Double,
                         target: Double, sourceInterval: Double,
                         imageTiming nextTiming: GameSourceImageTime? = nil) -> Decision {
        guard next > 0, nextTime.isFinite, nextTime > 0, target.isFinite, target > 0,
              sourceInterval.isFinite, (1.0 / 120...1.0 / 20).contains(sourceInterval) else {
            reset(); return .original
        }
        let clockChanged = lastTarget > 0 && target < lastTarget - 1e-6
        let cadenceChanged = expected > 0 && abs(sourceInterval - expected) > expected * 0.05
        let changedImageMetadata = sequence == next && imageTiming != nextTiming
        if clockChanged || cadenceChanged || changedImageMetadata { reset() }
        lastTarget = target
        expected = sourceInterval
        if sequence != next {
            let receiptElapsed = nextTime - sourceTime
            let elapsed: Double
            let validClockPair: Bool
            switch (imageTiming, nextTiming) {
            case (.some(let previous), .some(let current)):
                // A delayed/bunched readback must not rescale motion belonging
                // to the game's submitted image times. Skipped publications are
                // fine if the exact pair's positive time delta remains bounded.
                elapsed = current.interval(since: previous) ?? 0
                validClockPair = (0.001...0.1).contains(elapsed) &&
                    receiptElapsed >= 0 && receiptElapsed <= max(0.1, sourceInterval * 4)
            case (.none, .none):
                // Unadvertised legacy producers retain the old approximate
                // arrival-time fallback. It is not an exact content clock.
                elapsed = receiptElapsed
                validClockPair = elapsed >= sourceInterval * 0.45 && elapsed <= sourceInterval * 1.8
            default:
                elapsed = 0
                validClockPair = false
            }
            let validPair = sequence != nil && next > sequence! && validClockPair
            sequence = next
            sourceTime = nextTime
            imageTiming = nextTiming
            firstTarget = target
            interval = validPair ? elapsed : 0
            predictedPhase = nil
            return .source(resetHistory: !validPair)
        }
        guard interval > 0 else { return .original }
        let age = target - firstTarget
        // Never initiate or advance a forecast from stale motion. If one was
        // already shown, hold that bounded phase: returning the older real
        // image here would visibly move animation backwards on a missed frame.
        guard age >= interval * 0.2, age <= sourceInterval * 1.5 else {
            return predictedPhase.map { .predict(phase: $0) } ?? .original
        }
        // Tiny target-clock jitter may not be a clock discontinuity, but must
        // still never move an already generated image backwards in time.
        let phase = max(predictedPhase ?? 0, Float(min(0.5, age / interval)))
        predictedPhase = phase
        return .predict(phase: phase)
    }
}
