import Foundation

private func testRequire(_ value: @autoclosure () -> Bool, _ message: String = "Assertion failed") {
    guard value() else { testFailure(message) }
}
private func testFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}

@main struct CompositorSceneMailboxTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            testRequire(value(), message); checks += 1
        }
        let box = CompositorSceneMailbox<String, Int>()
        expect(box.offer(1, epoch: 1), "first physical refresh can offer before any scene")
        expect(box.beginWait() == nil, "no uninitialized scene may be presented")
        let a = box.reserveWrite()!
        expect(box.reserveWrite() == nil, "one scene writer only")
        expect(box.finishWrite(a, scene: "A"), "successful scene becomes ready")
        let wait = box.beginWait()!
        let b = box.reserveWrite()!
        expect(b.slot != a.slot, "do not write latest ready source while a drawable waits")
        expect(box.finishWrite(b, scene: "B"), "new ready scene supersedes A")
        for n in 2...100 { expect(box.offer(n, epoch: 1), "replace, do not queue display offers") }
        let job = box.takeAfterDrawable(wait)!
        expect(job.scene == "B" && job.request == 100, "after blocked drawable choose newest scene and newest request")
        expect(box.beginWait() == nil, "one lens GPU reader at a time")
        let c = box.reserveWrite()!
        expect(c.slot != job.lease.slot, "cannot overwrite active lens texture")
        expect(!box.finishWrite(c, scene: nil), "failed scene cannot replace successful B")
        expect(box.offer(101, epoch: 1), "queue a repeat without new scene completion")
        box.finishRead(job.lease)
        let repeated = box.takeAfterDrawable(box.beginWait()!)!
        expect(repeated.scene == "B" && repeated.request == 101, "lens repeat is driven by physical display, not new scene callback")
        box.finishRead(repeated.lease)
        box.finishRead(repeated.lease) // duplicate callback is harmless
        expect(box.offer(102, epoch: 1), "prepare blocked wait for retirement")
        let oldWait = box.beginWait()!
        box.retire(to: 2)
        expect(!box.offer(103, epoch: 1), "retired display callback rejected")
        let fresh = box.reserveWrite()!
        expect(box.finishWrite(fresh, scene: "new epoch"), "new epoch can produce while old drawable wait drains")
        expect(box.offer(104, epoch: 2), "new display offer")
        expect(box.takeAfterDrawable(oldWait) == nil, "retired waiter cannot take new epoch request or scene")
        let current = box.takeAfterDrawable(box.beginWait()!)!
        expect(current.scene == "new epoch" && current.request == 104, "new epoch request survives old callback")
        let inFlight = box.reserveWrite()!
        box.retire(to: 3)
        expect(box.reserveWrite() == nil, "retirement never releases an in-flight scene writer early")
        expect(!box.finishWrite(inFlight, scene: "old late GPU success"), "old completed writer cannot become ready")
        let next = box.reserveWrite()!
        expect(next.slot != current.lease.slot, "old lens reader survives retirement until completion")
        expect(box.finishWrite(next, scene: "third epoch"), "third epoch ready")
        expect(box.offer(105, epoch: 3), "third epoch offer")
        expect(box.beginWait() == nil, "old GPU reader still owns presentation credit")
        box.finishRead(current.lease)
        let third = box.takeAfterDrawable(box.beginWait()!)!
        expect(third.scene == "third epoch", "old release admits newest scene only")
        box.finishRead(third.lease)

        // Fixed-size model exercised through delayed/out-of-order callbacks:
        // stale/duplicate completion identities cannot free a newer ticket.
        var policy = CompositorScenePolicy()
        var epoch: UInt64 = 1
        for i in 0..<4000 {
            let w = policy.reserveWrite()!
            expect(policy.reserveWrite() == nil, "bounded writer under stress")
            if i % 13 == 0 { epoch += 1; policy.retire(to: epoch) }
            let accepted = policy.finishWrite(w, success: i % 7 != 0)
            expect(accepted == (w.epoch == epoch && i % 7 != 0), "success and exact epoch required")
            policy.finishWrite(w, success: true) // stale duplicate
            policy.offer(epoch: epoch)
            if let waiter = policy.beginWait() {
                if i % 11 == 0 { epoch += 1; policy.retire(to: epoch) }
                if let read = policy.takeAfterDrawable(waiter) {
                    expect(policy.activeReaders == 1, "one active GPU reader")
                    expect(policy.beginWait() == nil, "no second queued lens job")
                    policy.finishRead(read); policy.finishRead(read)
                }
            }
            expect(policy.activeReaders == 0 && !policy.hasWriter, "no leaked lease after stress step")
        }
        print("PASS: \(checks) scene/drawable/latest-request/reader/retirement assertions; no GPU, display, HID or app")
    }
}
