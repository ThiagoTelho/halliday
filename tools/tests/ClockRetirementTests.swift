import Foundation

private func testRequire(_ value: @autoclosure () -> Bool, _ message: String = "Assertion failed") {
    guard value() else { testFailure(message) }
}
private func testFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}
@main struct ClockRetirementTests {
 static func main() {
    let clock = LateDisplayClock(), mailbox = CompositorSceneMailbox<Int, Int>()
    let old = clock.epoch
    clock.reset()
    testRequire(!clock.retireIfCurrent(epoch: old))
    testRequire(clock.epoch == old+1)
    DispatchQueue.concurrentPerform(iterations: 1000) { _ in
        clock.reset()
        clock.withCurrentState { epoch, _ in mailbox.retire(to: epoch) }
    }
    testRequire(mailbox.epoch == clock.epoch, "reverse-ordered callbacks regressed mailbox epoch")
    let current = clock.epoch
    testRequire(clock.retireIfCurrent(epoch: current))
    testRequire(!clock.retireIfCurrent(epoch: current))
    testRequire(!clock.submitIfCurrent(epoch: current) { testFailure("old output committed") })
    var ran = false
    testRequire(clock.submitIfCurrent(epoch: clock.epoch) { ran = true })
    testRequire(ran)
    print("PASS: stale conditional retirement cannot reset replacement clock;1000concurrent reset/mailbox retirements end on current epoch; old output commit refused")
 }
}
