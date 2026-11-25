import Foundation

@main struct GameAutoFrameRateTests {
    struct Run {
        var policy = GameAutoFrameRate(mode: .auto)
        var producer = GameAutoFrameRate.Producer(pid: 17, epoch: 3, revision: 1)
        var hz = 120.0
        var now = 100.0
        var frames: UInt64 = 0
        var fraction = 0.0
        var transitions: [(Double, Bool)] = []
        var physicalTicks = 0
        mutating func tick(capacity: Double, eligible: Bool = true, blocked: Bool = false,
                           burst: Bool = false) {
            now += 1 / hz
            physicalTicks += 1
            let produced = min(capacity, hz / (policy.halfFrameRate ? 2 : 1)) / hz
            fraction += produced
            // Counter arrival may be batched, but its unit remains stereo pairs.
            if !burst || physicalTicks % 4 == 0 {
                let whole = UInt64(floor(fraction + 1e-8)); fraction -= Double(whole); frames += whole
            }
            let before = policy.halfFrameRate
            _ = policy.observe(now: now, frames: frames, producer: producer,
                physicalHz: hz, eligible: eligible, consumerBlocked: blocked)
            if policy.halfFrameRate != before { transitions.append((now, policy.halfFrameRate)) }
        }
        mutating func advance(_ seconds: Double, capacity: Double,
                              eligible: Bool = true, blocked: Bool = false, burst: Bool = false) {
            for _ in 0..<Int((seconds * hz).rounded()) {
                tick(capacity: capacity, eligible: eligible, blocked: blocked, burst: burst)
            }
        }
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }
    static func healthyAndDeficit() {
        for hz in [90.0, 120.0] {
            var full = Run(); full.hz = hz
            full.advance(4, capacity: hz)
            check(!full.policy.halfFrameRate && full.transitions.isEmpty, "healthy full-rate \(hz)")
            var nearNative = Run(); nearNative.hz = hz
            nearNative.advance(12, capacity: hz - 1)
            check(nearNative.transitions.isEmpty, "near-native quantized delivery stays full")
            var batched = Run(); batched.hz = hz
            batched.advance(4, capacity: hz, burst: true)
            check(batched.transitions.isEmpty, "batched healthy stereo count must stay full")
            var dip = Run(); dip.hz = hz
            dip.advance(1.5, capacity: hz); dip.advance(0.1, capacity: hz / 2); dip.advance(2, capacity: hz)
            check(dip.transitions.isEmpty, "one brief deficit window must not switch")
            for capacity in [43.0, hz * 0.75, hz / 2, hz - 10] {
                var low = Run(); low.hz = hz; low.advance(2, capacity: capacity)
                check(low.policy.halfFrameRate, "sustained deficit \(capacity) at \(hz)")
                let began = low.transitions.first!.0 - 100
                check(began >= 1.2 && began < 1.5, "two complete post-settle windows before half")
            }
        }
        print("PASS healthy/near-native(119 at120), burst, brief dip, sustained deficit(110 at120) at90/120")
    }
    static func recoverAndBackoff() {
        var run = Run(); run.advance(2, capacity: 60)
        check(run.policy.halfFrameRate, "initial half")
        run.advance(4, capacity: 120)
        check(run.policy.halfFrameRate && !run.policy.probing, "half-rate counts alone cannot prove headroom")
        run.advance(2, capacity: 120)
        check(!run.policy.halfFrameRate && !run.policy.probing, "bounded full-rate probe recovers")
        run.advance(3, capacity: 120)
        check(!run.policy.halfFrameRate, "recovery remains full")
        var capped = Run(); capped.advance(65, capacity: 60)
        let opens = capped.transitions.filter { !$0.1 }.map(\.0)
        let closes = capped.transitions.filter { $0.1 }.map(\.0)
        check(opens.count >= 4 && opens.count <= 5, "failed probes are bounded with backoff")
        for began in opens {
            guard let ended = closes.first(where: { $0 > began }) else { continue }
            check(ended - began >= 1.24 && ended - began < 1.3, "failed probe bound includes settling")
        }
        let gaps = zip(opens, opens.dropFirst()).map { $1 - $0 }
        check(gaps.count >= 3 && gaps[0] >= 9.2 && gaps[1] >= 17.2 && gaps[2] >= 31.2,
              "failed recovery backoff8/16/30")
        print("PASS no self-lock, cap, bounded probes/backoff, eventual recovery")
    }
    static func interruptions() {
        var run = Run(); run.advance(0.9, capacity: 43)
        run.advance(2, capacity: 43, eligible: false)
        run.advance(0.9, capacity: 43)
        check(!run.policy.halfFrameRate, "pause/dashboard must discard partial deficit")
        run.advance(1, capacity: 43)
        check(run.policy.halfFrameRate, "new eligible interval can independently engage")
        var loading = Run(); loading.advance(5, capacity: 0)
        check(loading.transitions.isEmpty, "zero-pair loading is not overload")
        var starved = Run(); starved.advance(0.9, capacity: 43)
        starved.advance(2, capacity: 43, blocked: true)
        starved.advance(0.9, capacity: 43)
        check(!starved.policy.halfFrameRate, "consumer starvation not attributed to game")
        var credits = Run()
        for i in 0..<240 { credits.tick(capacity: 60, blocked: i % 3 == 0) }
        check(credits.policy.halfFrameRate, "ordinary single-tick mailbox misses must not starve Auto")
        var probe = Run(); probe.advance(6.6, capacity: 60)
        check(probe.policy.probing, "test has entered full-rate probe")
        probe.advance(0.1, capacity: 120, eligible: false)
        check(probe.policy.halfFrameRate && !probe.policy.probing, "dashboard abort restores prior half")
        print("PASS pause/dashboard/loading/acquisition gaps and aborted probe")
    }
    static func resetsAndOverrides() {
        var run = Run(); run.advance(2, capacity: 43)
        run.policy.setMode(.auto)
        check(run.policy.halfFrameRate, "same mode cannot reset observations")
        run.producer = .init(pid: 18, epoch: 4, revision: 2); run.tick(capacity: 120)
        check(!run.policy.halfFrameRate, "new producer begins independently full")
        run.advance(2, capacity: 43); run.frames = 0; run.fraction = 0; run.tick(capacity: 120)
        check(!run.policy.halfFrameRate, "counter regression resets")
        run.advance(2, capacity: 43); run.now += 1; run.tick(capacity: 120)
        check(!run.policy.halfFrameRate, "callback suspension resets")
        run.advance(2, capacity: 43); run.now -= 0.2; run.tick(capacity: 120)
        check(!run.policy.halfFrameRate, "backward clock resets")
        run.advance(2, capacity: 43); run.hz = 90; run.tick(capacity: 90)
        check(!run.policy.halfFrameRate, "verified physical rate change resets")
        run.advance(2, capacity: 43); run.policy.resetProducer()
        check(!run.policy.halfFrameRate, "finished presentation resets Auto")
        run.policy.setMode(.on)
        _ = run.policy.observe(now: .nan, frames: 0, producer: run.producer, physicalHz: .nan, eligible: false)
        check(run.policy.halfFrameRate, "manual Half overrides all Auto evidence")
        run.policy.setMode(.off); run.advance(3, capacity: 0)
        check(!run.policy.halfFrameRate, "manual Off overrides all Auto evidence")
        run.policy.setMode(.auto); run.advance(2, capacity: 43)
        check(run.policy.halfFrameRate, "Off to Auto enables fresh policy")
        print("PASS producer/counter/clock/rate resets and explicit modes")
    }
    static func liveCadence() {
        for hz in [90.0, 120.0] {
            var run = Run(); run.hz = hz
            var cadence = GameFrameCadence(physicalHz: Float(hz), halfFrameRate: false)
            var wakeTargets: [Double] = []
            var halfTicks = 0
            for i in 0..<Int(hz * 12) {
                run.tick(capacity: i < Int(hz * 3) ? 43 : hz)
                cadence.setHalfFrameRate(run.policy.halfFrameRate)
                let notified = cadence.shouldNotify(at: run.now)
                if notified { wakeTargets.append(run.now) }
                check(!cadence.shouldNotify(at: run.now), "mode switch cannot replay a physical tick")
                check(cadence.gameHz == Float(hz / (run.policy.halfFrameRate ? 2 : 1)), "resolved source budget")
                if run.policy.halfFrameRate { halfTicks += 1 }
            }
            check(halfTicks > Int(hz * 4), "half interval exists")
            check(!run.policy.halfFrameRate && !run.policy.probing, "live cadence recovery")
            check(zip(wakeTargets, wakeTargets.dropFirst()).allSatisfy { $1 > $0 }, "no catch-up/duplicate wakes")
        }
        print("PASS actual cadence actuator90/45 and120/60 without replay")
    }
    static func main() {
        healthyAndDeficit(); recoverAndBackoff(); interruptions(); resetsAndOverrides(); liveCadence()
        print("GameAutoFrameRate: all CPU policy/cadence scenarios passed")
    }
}
