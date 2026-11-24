import Foundation

@main struct GameFrameCadenceTests {
    static func count(_ times: [Double], physical: Float, half: Bool) -> Int {
        var cadence = GameFrameCadence(physicalHz: physical, halfFrameRate: half)
        return times.reduce(0) { $0 + (cadence.shouldNotify(at: $1) ? 1 : 0) }
    }

    /// Independent integer display-tick oracle: after any full-rate tick, half
    /// rate next wakes two physical ticks later. Returning to full wakes on each
    /// new tick, including when the switch follows a skipped half-rate tick.
    static func liveTransitions(physical: Float) {
        for switchTick in 0..<12 {
            let origin = 31.127 + Double(switchTick) * 0.037
            func target(_ tick: Int) -> Double { origin + Double(tick) / Double(physical) }
            var cadence = GameFrameCadence(physicalHz: physical, halfFrameRate: false)
            for tick in 0...switchTick { precondition(cadence.shouldNotify(at: target(tick))) }
            precondition(cadence.setHalfFrameRate(true))
            precondition(cadence.physicalHz == physical && cadence.gameHz == physical / 2)
            precondition(!cadence.shouldNotify(at: target(switchTick)))
            for step in 1...9 {
                precondition(cadence.shouldNotify(at: target(switchTick + step)) == (step % 2 == 0))
                precondition(!cadence.setHalfFrameRate(true))
                precondition(!cadence.shouldNotify(at: target(switchTick + step)))
            }
            // The last callback was a skipped half-rate tick. It cannot be
            // replayed by switching to full; the following one wakes normally.
            precondition(cadence.setHalfFrameRate(false))
            precondition(!cadence.shouldNotify(at: target(switchTick + 9)))
            for step in 10...15 {
                precondition(cadence.shouldNotify(at: target(switchTick + step)))
                precondition(!cadence.shouldNotify(at: target(switchTick + step)))
            }
            precondition(cadence.setHalfFrameRate(true))
            for step in 16...23 {
                precondition(cadence.shouldNotify(at: target(switchTick + step)) == (step % 2 == 1))
            }
        }
    }

    static func liveMissesAndClockChanges(physical: Float) {
        let origin = 87.913
        func target(_ tick: Int) -> Double { origin + Double(tick) / Double(physical) }
        var cadence = GameFrameCadence(physicalHz: physical, halfFrameRate: false)
        precondition(!cadence.shouldNotify(at: .nan) && !cadence.shouldNotify(at: .infinity))
        precondition(cadence.shouldNotify(at: target(0)))
        precondition(cadence.shouldNotify(at: target(1)))
        precondition(cadence.setHalfFrameRate(true))
        // Miss the first two half-rate deadlines. One callback wakes once,
        // keeping the nominal phase rather than accumulating catch-up wakes.
        precondition(cadence.shouldNotify(at: target(6)))
        for _ in 0..<100 { precondition(!cadence.shouldNotify(at: target(6))) }
        precondition(!cadence.setHalfFrameRate(true))
        precondition(cadence.shouldNotify(at: target(7)))
        precondition(!cadence.shouldNotify(at: target(8)))
        precondition(!cadence.shouldNotify(at: -.infinity))
        precondition(cadence.shouldNotify(at: target(9)))
        // Settings may change repeatedly between physical callbacks, but cannot
        // recreate that callback's wake or lose the last notified target.
        for _ in 0..<20 {
            precondition(cadence.setHalfFrameRate(false))
            precondition(!cadence.shouldNotify(at: target(9)))
            precondition(cadence.setHalfFrameRate(true))
            precondition(!cadence.shouldNotify(at: target(9)))
        }
        precondition(!cadence.shouldNotify(at: target(10)))
        precondition(cadence.shouldNotify(at: target(11)))
        precondition(cadence.setHalfFrameRate(false))
        precondition(cadence.shouldNotify(at: target(1000)))
        for _ in 0..<100 { precondition(!cadence.shouldNotify(at: target(1000))) }
        precondition(cadence.setHalfFrameRate(true))
        precondition(!cadence.shouldNotify(at: target(1001)))
        precondition(cadence.shouldNotify(at: target(1002)))
        // A replacement display-link clock starts a single new phase in either
        // mode. Tiny backwards jitter is a repeated sample, not a new clock.
        precondition(cadence.shouldNotify(at: 1))
        precondition(!cadence.shouldNotify(at: 1 - 0.0000005))
        precondition(!cadence.shouldNotify(at: 1 + 1 / Double(physical)))
        precondition(cadence.shouldNotify(at: 1 + 2 / Double(physical)))
        precondition(cadence.setHalfFrameRate(false))
        precondition(cadence.shouldNotify(at: 0))
        precondition(!cadence.shouldNotify(at: 0))
        precondition(cadence.shouldNotify(at: 1 / Double(physical)))
    }

    static func livePhysicalTransitions(half: Bool) {
        var cadence = GameFrameCadence(physicalHz: 90, halfFrameRate: half)
        var target = 113.927
        precondition(cadence.shouldNotify(at: target))
        for hz: Float in [120, 90, 120, 90, 120] {
            precondition(cadence.setPhysicalHz(hz))
            precondition(cadence.physicalHz == hz && cadence.gameHz == hz / (half ? 2 : 1))
            precondition(!cadence.setPhysicalHz(hz))
            precondition(!cadence.shouldNotify(at: target))
            var wakes = 0
            // Integer physical-tick oracle: a new rate still wakes on every
            // tick (full) or on exactly every second tick (half).
            for tick in 1...Int(hz) {
                target += 1 / Double(hz)
                let wake = cadence.shouldNotify(at: target)
                precondition(wake == (!half || tick % 2 == 0))
                wakes += wake ? 1 : 0
                precondition(!cadence.shouldNotify(at: target))
            }
            precondition(wakes == Int(hz) / (half ? 2 : 1))
        }
        let before = cadence.physicalHz
        for hz: Float in [.nan, .infinity, -.infinity, 0, -1, 19, 241] {
            precondition(!cadence.setPhysicalHz(hz) && cadence.physicalHz == before)
        }
        // A switch after a skipped half-rate callback uses the last delivered
        // wake, rather than replaying that callback or restarting the phase.
        var skipped = GameFrameCadence(physicalHz: 120, halfFrameRate: true)
        precondition(skipped.shouldNotify(at: 10))
        let first = 10 + 1.0 / 120
        precondition(!skipped.shouldNotify(at: first))
        precondition(skipped.setPhysicalHz(90))
        for _ in 0..<20 {
            precondition(skipped.setPhysicalHz(120))
            precondition(skipped.setPhysicalHz(90))
            precondition(!skipped.shouldNotify(at: first))
        }
        for tick in 1...8 {
            precondition(skipped.shouldNotify(at: first + Double(tick) / 90) == (tick % 2 == 0))
        }
    }

    static func main() {
        let full120 = (0..<240).map { 17.0 + Double($0) / 120 }
        precondition(count(full120, physical: 120, half: false) == 240)
        precondition(count(full120, physical: 120, half: true) == 120)
        let full90 = (0..<180).map { 17.0 + Double($0) / 90 }
        precondition(count(full90, physical: 90, half: true) == 90)
        // Ten skipped draw callbacks per second must not silently reduce the game to 55 FPS.
        let keptTicks: [Int] = (0..<240).filter { $0 == 0 || $0 % 12 != 0 }
        let missing: [Double] = keptTicks.map { 17.0 + Double($0) / 120.0 }
        precondition(count(missing, physical: 120, half: true) == 120)
        let callbacks110 = (0..<220).map { 17.0 + Double($0) / 110 }
        precondition(count(callbacks110, physical: 120, half: true) == 120)
        var cadence = GameFrameCadence(physicalHz: 120, halfFrameRate: true)
        precondition(cadence.gameHz == 60 && abs(cadence.gameInterval - 1.0 / 60) < 1e-9)
        precondition(cadence.shouldNotify(at: 10))
        precondition(!cadence.shouldNotify(at: 10))
        precondition(!cadence.shouldNotify(at: 10 + 1.0 / 120))
        precondition(cadence.shouldNotify(at: 10 + 1.0 / 60))
        // A long pause coalesces every missed game deadline into exactly one wake.
        precondition(cadence.shouldNotify(at: 20))
        for _ in 0..<100 { precondition(!cadence.shouldNotify(at: 20)) }
        precondition(!cadence.shouldNotify(at: 20 + 1.0 / 120))
        precondition(cadence.shouldNotify(at: 20 + 1.0 / 60))
        precondition(!cadence.shouldNotify(at: .nan) && !cadence.shouldNotify(at: .infinity))
        // Changing display-link time bases starts a new phase rather than waiting for old time.
        precondition(cadence.shouldNotify(at: 1))
        precondition(!cadence.shouldNotify(at: 1 + 1.0 / 120))
        precondition(cadence.shouldNotify(at: 1 + 1.0 / 60))
        for physical: Float in [120, 90] {
            liveTransitions(physical: physical)
            liveMissesAndClockChanges(physical: physical)
        }
        livePhysicalTransitions(half: false)
        livePhysicalTransitions(half: true)
        // Before the first callback there is no phase to lose.
        var beforeFirst = GameFrameCadence(physicalHz: 120, halfFrameRate: false)
        precondition(beforeFirst.setHalfFrameRate(true))
        precondition(!beforeFirst.setHalfFrameRate(true))
        precondition(beforeFirst.shouldNotify(at: 4.25))
        precondition(!beforeFirst.shouldNotify(at: 4.25 + 1.0 / 120))
        precondition(beforeFirst.shouldNotify(at: 4.25 + 1.0 / 60))
        print("PASS: full120, half120→60/90→45, live full↔half at24 phases, physical90↔120 full/half, missed/duplicate/nonfinite callbacks, repeated toggles, clock reset")
    }
}
