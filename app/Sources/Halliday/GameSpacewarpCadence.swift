import Foundation

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
    private var firstTarget = 0.0
    private var lastTarget = 0.0
    private var interval = 0.0
    private var expected = 0.0
    private var predictedPhase: Float?

    mutating func reset() { self = Self() }

    mutating func update(sequence next: UInt64, sourceTime nextTime: Double,
                         target: Double, sourceInterval: Double) -> Decision {
        guard next > 0, nextTime.isFinite, nextTime > 0, target.isFinite, target > 0,
              sourceInterval.isFinite, (1.0 / 120...1.0 / 20).contains(sourceInterval) else {
            reset(); return .original
        }
        let clockChanged = lastTarget > 0 && target < lastTarget - 1e-6
        let cadenceChanged = expected > 0 && abs(sourceInterval - expected) > expected * 0.05
        if clockChanged || cadenceChanged { reset() }
        lastTarget = target
        expected = sourceInterval
        if sequence != next {
            let elapsed = nextTime - sourceTime
            let validPair = sequence != nil && next > sequence! &&
                elapsed >= sourceInterval * 0.45 && elapsed <= sourceInterval * 1.8
            sequence = next
            sourceTime = nextTime
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
