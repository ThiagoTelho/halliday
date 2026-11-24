import Foundation

@main struct GameSpacewarpCadenceTests {
    typealias Decision = GameSpacewarpCadence.Decision

    static func phase(_ decision: Decision) -> Float {
        guard case .predict(let phase) = decision else { fatalError("Expected a bounded prediction, got \(decision)") }
        precondition(phase > 0 && phase <= 0.5)
        return phase
    }
    static func position(_ decision: Decision, source: Double, step: Double) -> Double {
        switch decision {
        case .source, .original: return source
        case .predict(let value): return source + Double(value) * step
        }
    }
    static func primed(_ interval: Double, start: Double = 1) -> GameSpacewarpCadence {
        var policy = GameSpacewarpCadence()
        precondition(policy.update(sequence: 1, sourceTime: start, target: start, sourceInterval: interval) == .source(resetHistory: true))
        precondition(policy.update(sequence: 2, sourceTime: start + interval, target: start + interval, sourceInterval: interval) == .source(resetHistory: false))
        return policy
    }
    static func missedFramesAndRecovery(display: Double) {
        let frame = 1 / display, game = frame * 2, realTime = 1 + game
        var policy = primed(game)
        var x = 20.0
        // A moving marker advances ten units between genuine source images.
        // The old stale cutoff returned .original at the fourth display tick:
        // x fell from 25 to20 although this real image had not changed.
        for tick in [1, 2, 3, 4, 5, 6, 30, 120] {
            let decision = policy.update(sequence: 2, sourceTime: realTime,
                target: realTime + Double(tick) * frame, sourceInterval: game)
            let next = position(decision, source: 20, step: 10)
            precondition(next >= x, "Animation snapped backwards on a missed source at \(display) Hz")
            precondition(abs(phase(decision) - 0.5) < 1e-5)
            x = next
        }
        // A late genuine source is shown immediately, never put behind a
        // synthetic queue. Its long pair gap invalidates motion history.
        let recovered = realTime + 121 * frame
        let real = policy.update(sequence: 3, sourceTime: recovered, target: recovered, sourceInterval: game)
        precondition(real == .source(resetHistory: true))
        precondition(position(real, source: 30, step: 10) >= x)
        precondition(policy.update(sequence: 3, sourceTime: recovered, target: recovered + frame, sourceInterval: game) == .original)
        precondition(policy.update(sequence: 4, sourceTime: recovered + game, target: recovered + game, sourceInterval: game) == .source(resetHistory: false))
        _ = phase(policy.update(sequence: 4, sourceTime: recovered + game, target: recovered + game + frame, sourceInterval: game))
    }
    static func staleWithoutForecast(display: Double) {
        let game = 2 / display, realTime = 1 + game
        var policy = primed(game)
        for age in [2.0, 3, 20, 100] {
            precondition(policy.update(sequence: 2, sourceTime: realTime, target: realTime + age * game,
                sourceInterval: game) == .original, "A late first repeat must not initiate stale prediction")
        }
    }
    static func jitter(display: Double) {
        let game = 2 / display, frame = 1 / display
        var policy = GameSpacewarpCadence(), previousX = 0.0
        let jitter = [0.0, 0.12, -0.08, 0.05, -0.1, 0.0]
        for index in 0..<jitter.count {
            let sourceTime = 10 + (Double(index) + jitter[index]) * game
            let target = 10 + Double(index) * game
            let decision = policy.update(sequence: UInt64(index + 1), sourceTime: sourceTime,
                target: target, sourceInterval: game)
            precondition(decision == .source(resetHistory: index == 0))
            let sourceX = Double(index) * 10
            precondition(sourceX >= previousX)
            previousX = sourceX
            let repeated = policy.update(sequence: UInt64(index + 1), sourceTime: sourceTime,
                target: target + frame, sourceInterval: game)
            if index == 0 { precondition(repeated == .original); continue }
            let first = phase(repeated)
            let tinyBackwardJitter = policy.update(sequence: UInt64(index + 1), sourceTime: sourceTime,
                target: target + frame - 0.0000005, sourceInterval: game)
            precondition(phase(tinyBackwardJitter) == first, "Sub-microsecond target jitter reduced phase")
            let x = position(tinyBackwardJitter, source: sourceX, step: 10)
            precondition(x >= previousX)
            previousX = x
        }
        // Cross the stale cutoff without reaching half a pair interval first:
        // hold exactly the requested phase, rather than advancing stale motion.
        policy = primed(game)
        let realTime = 1 + game
        let early = phase(policy.update(sequence: 2, sourceTime: realTime,
            target: realTime + game * 0.25, sourceInterval: game))
        precondition(abs(early - 0.25) < 1e-5)
        precondition(phase(policy.update(sequence: 2, sourceTime: realTime,
            target: realTime + game * 3, sourceInterval: game)) == early)
    }
    static func resets(display: Double) {
        let game = 2 / display, frame = 1 / display, realTime = 1 + game
        var policy = primed(game)
        _ = phase(policy.update(sequence: 2, sourceTime: realTime, target: realTime + frame, sourceInterval: game))
        // An off/on cycle or a reconnect can keep the same cached sequence.
        policy.reset()
        precondition(policy.update(sequence: 2, sourceTime: realTime, target: realTime + game * 3, sourceInterval: game) == .source(resetHistory: true))
        precondition(policy.update(sequence: 2, sourceTime: realTime, target: realTime + game * 4, sourceInterval: game) == .original)
        for changedRate in [display == 90 ? 120.0 : 90.0] {
            policy = primed(game)
            _ = phase(policy.update(sequence: 2, sourceTime: realTime, target: realTime + frame, sourceInterval: game))
            let nextInterval = 2 / changedRate
            precondition(policy.update(sequence: 2, sourceTime: realTime, target: realTime + game * 2, sourceInterval: nextInterval) == .source(resetHistory: true))
            precondition(policy.update(sequence: 2, sourceTime: realTime, target: realTime + game * 2 + nextInterval / 2, sourceInterval: nextInterval) == .original)
        }
        policy = primed(game)
        _ = phase(policy.update(sequence: 2, sourceTime: realTime, target: realTime + frame, sourceInterval: game))
        precondition(policy.update(sequence: 1, sourceTime: realTime + game, target: realTime + game, sourceInterval: game) == .source(resetHistory: true))
        precondition(policy.update(sequence: 1, sourceTime: realTime + game, target: realTime + game + frame, sourceInterval: game) == .original)
        precondition(policy.update(sequence: 0, sourceTime: realTime, target: realTime, sourceInterval: game) == .original)
        precondition(policy.update(sequence: 1, sourceTime: realTime, target: realTime, sourceInterval: game) == .source(resetHistory: true))
    }
    static func main() {
        for display in [90.0, 120.0] {
            missedFramesAndRecovery(display: display)
            staleWithoutForecast(display: display)
            jitter(display: display)
            resets(display: display)
        }
        var policy = primed(1.0 / 60, start: 10)
        let interval = 1.0 / 60
        precondition(policy.update(sequence: 2, sourceTime: 10 + interval, target: 9, sourceInterval: interval) == .source(resetHistory: true))
        precondition(policy.update(sequence: 1, sourceTime: .nan, target: 10, sourceInterval: interval) == .original)
        precondition(policy.update(sequence: 1, sourceTime: 10, target: .infinity, sourceInterval: interval) == .original)
        precondition(policy.update(sequence: 1, sourceTime: 10, target: 10, sourceInterval: 0) == .original)
        print("PASS: 45→90/60→120 monotonic cached-image trajectory, missed frames/stall/recovery, exact bounded hold, arrival/target jitter, no stale first prediction, fresh-source-only history, toggle/reconnect/rate/clock/invalid-input resets")
    }
}
