import Foundation

@main
struct SenseHapticsTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() {
        var scheduler = SenseHapticScheduler()
        scheduler.connect(hand: 0, generation: 1, bluetooth: true)
        scheduler.connect(hand: 1, generation: 2, bluetooth: true)
        var sink: [SenseHapticScheduler.Output] = []
        sink += scheduler.play(hand: 0, generation: 1, amplitude: 0.5, frequencyHz: 160,
                               durationNanoseconds: 5_000_000_000, requestedAt: 0, now: 0)
        sink += scheduler.play(hand: 1, generation: 2, amplitude: 0.25, frequencyHz: 60,
                               durationNanoseconds: 10_000_000, requestedAt: 0, now: 0)
        require(sink.count == 2 && sink[0].hand == 0 && sink[1].hand == 1, "Hands were not independent")
        require(scheduler.advance(now: 9_999_999).isEmpty, "Short pulse stopped early")
        let stop = scheduler.advance(now: 10_000_000)
        require(stop.count == 1 && stop[0].hand == 1 && stop[0].amplitude == 0, "Short default pulse missed deadline")
        let resend = scheduler.advance(now: 2_000_000_000)
        require(resend.count == 1 && resend[0].hand == 0 && resend[0].amplitude == 0.5, "Two-second refresh missing")
        require(scheduler.advance(now: 2_000_000_001).isEmpty, "Refresh repeated at every tick")
        let expiry = scheduler.advance(now: 5_000_000_000)
        require(expiry.count == 1 && expiry[0].amplitude == 0 && scheduler.nextDeadline == nil, "Long pulse failed to stop")
        require(scheduler.advance(now: 6_000_000_000).isEmpty, "Expired pulse replayed")
        _ = scheduler.play(hand: 0, generation: 1, amplitude: 0.5, frequencyHz: 160,
                           durationNanoseconds: 100, requestedAt: 100, now: 100)
        _ = scheduler.play(hand: 0, generation: 1, amplitude: 0.5, frequencyHz: 160,
                           durationNanoseconds: 300, requestedAt: 150, now: 150)
        require(scheduler.advance(now: 200).isEmpty, "Old deadline cancelled replacement with the same amplitude")
        require(scheduler.advance(now: 450).first?.amplitude == 0, "Replacement deadline did not stop")
        require(scheduler.play(hand: 0, generation: 1, amplitude: 1, frequencyHz: 160,
                               durationNanoseconds: 10, requestedAt: 0, now: 20).isEmpty, "Queued expired pulse played late")
        require(scheduler.play(hand: 0, generation: 1, amplitude: 1, frequencyHz: 160,
                               durationNanoseconds: 10, requestedAt: .max - 5, now: 0).isEmpty, "Overflow created an unbounded pulse")
        require(scheduler.play(hand: 0, generation: 1, amplitude: .nan, frequencyHz: 160,
                               durationNanoseconds: 10, requestedAt: 0, now: 0).isEmpty, "Nonfinite amplitude accepted")
        require(!SenseHapticScheduler.valid(amplitude: 1.1, frequencyHz: 160, durationNanoseconds: 10), "Amplitude bound ignored")
        require(!SenseHapticScheduler.valid(amplitude: 1, frequencyHz: -.infinity, durationNanoseconds: 10), "Nonfinite frequency accepted")
        require(!SenseHapticScheduler.valid(amplitude: 1, frequencyHz: 160, durationNanoseconds: .max), "Duration bound ignored")
        for counter in 0..<257 {
            let report = scheduler.nextReport(hand: 0, generation: 1)!
            require(report.counter == UInt8(truncatingIfNeeded: counter), "Report counter did not wrap")
            require(report.sequence == UInt8(counter & 15), "LED/vibration sequence did not share allocator")
        }
        sink += scheduler.play(hand: 0, generation: 1, amplitude: 1, frequencyHz: 160,
                               durationNanoseconds: 100, requestedAt: 100, now: 100)
        scheduler.disconnect(hand: 0, generation: 1)
        scheduler.connect(hand: 0, generation: 3, bluetooth: true)
        require(scheduler.advance(now: 201).isEmpty, "Detached connection's timer affected replacement")
        require(scheduler.nextReport(hand: 0, generation: 1) == nil, "Old connection allocated a new controller's report")
        require(scheduler.play(hand: 0, generation: 1, amplitude: 1, frequencyHz: 160,
                               durationNanoseconds: 100, requestedAt: 300, now: 300).isEmpty, "Stale queued request affected replacement")
        scheduler.connect(hand: 1, generation: 4, bluetooth: false)
        require(scheduler.play(hand: 1, generation: 4, amplitude: 1, frequencyHz: 160,
                               durationNanoseconds: 100, requestedAt: 300, now: 300).isEmpty, "USB guessed a Bluetooth output report")
        sink += scheduler.play(hand: 0, generation: 3, amplitude: 1, frequencyHz: 90,
                               durationNanoseconds: 100, requestedAt: 300, now: 300)
        let cancelled = scheduler.stopAll()
        require(cancelled.count == 1 && cancelled[0].hand == 0 && cancelled[0].amplitude == 0, "Focus/close cancellation did not stop active hand")
        require(scheduler.stopAll().isEmpty && scheduler.nextDeadline == nil, "Cancellation left a timer")
        print("PASS: fake-clock/fake-sink Sense scheduling, short expiry, refresh, cancel, per-hand report sequences, reconnect generations and Bluetooth-only output")
    }
}
