import Foundation

private func testRequire(_ value: @autoclosure () -> Bool, _ message: String = "Assertion failed") {
    guard value() else { testFailure(message) }
}
private func testFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}

private final class Capture: @unchecked Sendable {
    let lock = NSLock()
    var poseReport = 0
    var results: [(pulse: UInt64, pose: Int, scene: String, start: Int64)] = []
    func nextPose(_ n: Int) { lock.lock(); poseReport = n; lock.unlock() }
    func record(_ pulse: CompositorDisplayPulse, scene: String) {
        testRequire(!Thread.isMainThread, "physical refresh incorrectly required MainActor")
        lock.lock(); results.append((pulse.id, poseReport, scene, pulse.startedNs)); lock.unlock()
    }
}
@main struct CompositorRefreshDriverTests {
    static func main() {
        let driver = CompositorRefreshDriver(), capture = Capture()
        let mailbox = CompositorSceneMailbox<String, CompositorDisplayPulse>()
        let write = mailbox.reserveWrite()!
        mailbox.finishWrite(write, scene: "ONE completed scene")
        let clock = driver.startClock()
        driver.configure(offsetNs: 4_000_000) { pulse in
            mailbox.offer(pulse, epoch: 1)
            let work = mailbox.takeAfterDrawable(mailbox.beginWait()!)!
            capture.record(work.request, scene: work.scene)
            mailbox.finishRead(work.lease)
        }
        // MainActor is intentionally unavailable (blocked in group.wait). The
        // actual production refresh driver must still deliver five latest head
        // requests from ONE already-completed scene, with fresh pulse identities.
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            for i in 1...5 {
                capture.nextPose(i)
                testRequire(driver.pulse(clock: clock, startedNs: 1_000_000_000 + Int64(i)*8_333_333,
                    baseTargetNs: 1_010_000_000 + Int64(i)*8_333_333, linkTargetNs: Int64(i)))
            }
            group.leave()
        }
        testRequire(group.wait(timeout: .now() + 3) == .success)
        testRequire(capture.results.count == 5)
        testRequire(capture.results.map(\.pose) == [1,2,3,4,5])
        testRequire(Set(capture.results.map(\.pulse)).count == 5)
        testRequire(Set(capture.results.map(\.start)).count == 5)
        testRequire(capture.results.allSatisfy { $0.scene == "ONE completed scene" })
        driver.stopClock()
        testRequire(!driver.pulse(clock: clock, startedNs: 1, baseTargetNs: 2, linkTargetNs: 3))
        let replacement = driver.startClock()
        driver.configure(offsetNs: 0) { _ in }
        testRequire(!driver.pulse(clock: clock, startedNs: 1, baseTargetNs: 2, linkTargetNs: 3))
        testRequire(driver.pulse(clock: replacement, startedNs: 1, baseTargetNs: 2, linkTargetNs: 3))
        driver.clearConfiguration()
        testRequire(!driver.pulse(clock: replacement, startedNs: 1, baseTargetNs: 2, linkTargetNs: 3))
        print("PASS: real display driver delivers5fresh off-main head/presentation requests from1completedscene while MainActor stalled; pulse identities, old clock retirement and cleared configurations checked; no GPU/HID/app")
    }
}
