import Foundation

@main struct SenseLEDFeedbackAndTouchTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { FileHandle.standardError.write(Data(("FAIL: "+message+"\n").utf8)); exit(1) }
    }
    static func lifecycle() {
        var gate = SenseOutputPolicy()
        let left = gate.token(hand: 0), right = gate.token(hand: 1)
        check(gate.accepts(hand: 0, token: left), "classic haptics retain default focus")
        gate.cancel(hand: 0)
        check(!gate.accepts(hand: 0, token: left) && gate.accepts(hand: 1, token: right), "one-hand stop preserves the other hand")
        let playing = gate.token(hand: 0)
        check(gate.setFocused(false), "focus loss retires requests")
        check(!gate.accepts(hand: 0, token: playing), "unfocused output rejected")
        check(gate.setFocused(true) && !gate.accepts(hand: 0, token: playing), "focus round trip cannot revive an old effect")
        let stable = gate.token(hand: 1)
        check(!gate.setFocused(true) && gate.token(hand: 1) == stable, "same-setting update preserves valid output")
        check(!gate.accepts(hand: -1, token: 0) && !gate.accepts(hand: 2, token: 0), "invalid hands are rejected")
        print("PASS classic-output focus, request retirement, independent hands and same-setting preservation")
    }
    static func leds() {
        var sync = SenseLEDSynchronizer()
        let base: Int64 = 20_000_000_000
        // Start shortly before the device tick rollover; independently vary arrival latency.
        var ticks: UInt32 = .max-300_000
        for index in 0..<40 {
            ticks &+= 30_000
            sync.receive(.init(sequence: UInt32(index+1), ticks: ticks, echoedHostUs: 0,
                crcFailures: 0, receivedNs: base+Int64(index)*10_000_000+Int64(index%4)*100_000))
        }
        let now = base+400_000_000
        let command = sync.camera(counter: 100, exposureNs: now-5_000_000,
            periodNs: 1e9/60, centreOffsetNs: 2_300_000, nowNs: now)
        check(command?.phase == 1 && command?.pulse == 42 && command?.cycle == 50_000_000, "camera sync uses documented phase and unchanged pulse/period")
        check(sync.state == .awaitingEcho, "sending timing is not optical proof")
        sync.optical(counter: 101, exposureNs: now+20_000_000, visible: true)
        check(sync.state == .awaitingEcho, "pre-echo optical evidence rejected")
        sync.outputSent(hostUs: .max-7, atNs: now, settings: command!)
        ticks &+= 30_000
        sync.receive(.init(sequence: 41, ticks: ticks, echoedHostUs: .max-7, crcFailures: 0, receivedNs: now+10_000_000))
        check(sync.state == .observing, "known wrapping host timestamp confirms known output reception")
        sync.optical(counter: 101, exposureNs: now+20_000_000, visible: true)
        sync.optical(counter: 101, exposureNs: now+21_000_000, visible: true)
        check(sync.state == .observing, "same physical exposure cannot confirm twice")
        sync.optical(counter: 102, exposureNs: now+36_000_000, visible: true)
        check(sync.state == .synchronized, "two independent post-echo optical samples confirm")
        check(sync.camera(counter: 101, exposureNs: now+500_000_000, periodNs: 1e9/60,
            centreOffsetNs: 0, nowNs: now+500_000_000) == nil && sync.state == .stale, "stale controller clock never emits timing")
        sync.reset(); check(sync.state == .warming, "reconnect clears LED state")
        check(sync.camera(counter: 0, exposureNs: now, periodNs: .nan, centreOffsetNs: 0, nowNs: now) == nil, "nonfinite camera period rejected")
        print("PASS LED clock rollover, camera timing, known-output echo, independent optical confirmation, stale/reconnect/nonfinite guards; no speculative hardware phases")
    }
    static func touch() {
        for (source, target) in [(8,33),(9,2),(10,32),(11,7),(12,1)] {
            let touch = GameControllerTouch(buttons: UInt32(1)<<source, triggerProximity: 0.3, gripProximity: 0.8)
            check(touch.bridgeTouched == UInt64(1)<<target, "actual touch maps correct bridge bit")
            check(touch.proximity == SIMD2(0.3,0.8), "analog proximity preserved independently")
        }
        let clicks = GameControllerTouch(buttons: 0xff, triggerProximity: 1, gripProximity: 1)
        check(clicks.bridgeTouched == 0, "pressed buttons/full proximity do not invent actual touch")
        check(GameControllerTouch(buttons: 0, triggerProximity: .nan, gripProximity: -.infinity).proximity == .zero, "nonfinite proximity sanitized")
        print("PASS both-hand bridge capacitive mapping, real contact vs press independence and analog proximity")
    }
    static func main() { lifecycle(); leds(); touch() }
}
