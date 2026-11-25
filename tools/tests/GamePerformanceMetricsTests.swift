import Foundation

@main struct GamePerformanceMetricsTests {
    static let producer = GamePerformanceMetrics.Producer(pid: 123, epoch: 7, revision: 1)
    static func near(_ value: Double?, _ expected: Double, _ text: String, tolerance: Double = 1e-6) {
        precondition(value != nil && abs(value! - expected) < tolerance, "\(text): \(String(describing: value)) != \(expected)")
    }
    static func metrics(at time: Double = 100) -> GamePerformanceMetrics {
        let m = GamePerformanceMetrics(); m.setEnabled(true, at: time)
        m.observeProducer(producer, frames: 1, at: time, active: true); return m
    }
    static func simulate(_ m: GamePerformanceMetrics, seconds: Double, sourceHz: Double = 60, displayHz: Double = 120, identity: GamePerformanceMetrics.Producer = producer) -> PerformanceHUDSnapshot {
        var previous: UInt64 = 0, image: UInt64 = 0
        var snapshot = PerformanceHUDSnapshot.empty
        for tick in 0...Int(seconds * displayHz) {
            let now = 100 + Double(tick) / displayHz
            let count = UInt64((Double(tick) / displayHz * sourceHz + 1e-7).rounded(.down)) + 1
            m.observeProducer(identity, frames: count, at: now, active: true)
            m.posePublished(stamp: UInt32(tick + 1), at: now)
            let new = count != previous
            if new {
                image += 1
                let stamp = tick >= 4 ? UInt32(tick - 3) : 0
                m.receivedImage(sequence: image, poseStamp: Float(stamp), at: now)
            }
            if let context = m.presentationContext() {
                m.presented(imageSequence: image, generated: !new, at: now, epoch: 1, context: context)
            }
            previous = count
            snapshot = m.snapshot(now: now)
        }
        return snapshot
    }
    static func main() {
        let m = metrics()
        let sample = simulate(m, seconds: 2)
        near(sample.gameFPS, 60, "GameFPS counts only native source publications", tolerance: 0.6)
        near(sample.displayFPS, 120, "Actual physical outputs count repeats/framegen separately")
        near(sample.poseToDisplayMs, 1000 * 4 / 120, "Software pose publication to actual presentation start")
        near(sample.history.last?.gameFrameTimeMs, 1000 / 60, "Graph is average publication interval, not GPU time", tolerance: 0.2)
        m.observeProducer(producer, frames: 121, at: 102.25, active: true)
        let stalled = m.snapshot(now: 102.25)
        precondition(stalled.gameFPS != nil && stalled.gameFPS! < 55 && stalled.gameFPS! > 30,
            "A short native-source stall must reduce throughput while compositor output stays separate")
        apiKindsShareSemantics()
        sourceCoalescingAndResets()
        firstActualNativeOnly()
        stampsAndClockValidation()
        pauseAndDisabledContexts()
        boundedHistoryAndSampling()
        concurrentActualCallbacks()
        print("PASS: native GameFPS vs120Hz FG/repeats, coalesced producer counters, first actual native pose latency, tag/clock validation, old-context rejection, pause display-only feedback,10s/5Hz history and concurrent callback deduplication")
    }
    static func apiKindsShareSemantics() {
        // Protocol identities, not per-game modes: all three transports feed
        // the same producer publications/image-tag model.
        for (label, identity) in [
            ("Windows OpenVR", GamePerformanceMetrics.Producer(pid: 11, epoch: 0, revision: 1)),
            ("Windows OpenXR", .init(pid: 22, epoch: 99, revision: 2)),
            ("native OpenXR", .init(pid: 33, epoch: 0, revision: 3))
        ] {
            let m = GamePerformanceMetrics(); m.setEnabled(true, at: 100)
            let sample = simulate(m, seconds: 2, identity: identity)
            near(sample.gameFPS, 60, label + " real producer FPS", tolerance: 0.6)
            near(sample.displayFPS, 120, label + " actual display FPS")
            near(sample.poseToDisplayMs, 1000 * 4 / 120, label + " exact valid pose tag")
        }
    }
    static func sourceCoalescingAndResets() {
        let m = metrics()
        // Consumer polls only5Hz, but it observes12 completed game publications
        // per poll. It must report60, not5, and fabricate no per-frame times.
        for i in 1...5 { m.observeProducer(producer, frames: UInt64(1 + i * 12), at: 100 + Double(i) * 0.2, active: true) }
        near(m.snapshot(now: 101).gameFPS, 60, "Coalesced publication count")
        let old = m.presentationContext()!
        m.observeProducer(producer, frames: 2, at: 101.01, active: true)
        precondition(m.presentationContext() != old && m.snapshot(now: 101.01).gameFPS == nil)
        m.observeProducer(.init(pid: 456, epoch: 8, revision: 2), frames: 10000, at: 101.02, active: true)
        precondition(m.snapshot(now: 101.03).gameFPS == nil, "New producer must not inherit the previous frame counter")
        let stale = m.snapshot(now: 101.6)
        precondition(stale.gameFPS == nil && stale.poseToDisplayMs == nil && stale.history.isEmpty)
    }
    static func firstActualNativeOnly() {
        let m = metrics(); m.posePublished(stamp: 7, at: 100)
        m.receivedImage(sequence: 1, poseStamp: 7, at: 100.01)
        let c = m.presentationContext()!
        m.presented(imageSequence: 1, generated: true, at: 100.02, epoch: 1, context: c)
        precondition(m.snapshot(now: 100.021).poseToDisplayMs == nil, "Generated image must not claim a lower native latency")
        m.presented(imageSequence: 1, generated: false, at: 100.06, epoch: 1, context: c)
        m.presented(imageSequence: 1, generated: false, at: 100.04, epoch: 1, context: c) // Callback delivery reordered.
        for i in 7...20 { m.presented(imageSequence: 1, generated: false, at: 100 + Double(i) * 0.01, epoch: 1, context: c) }
        near(m.snapshot(now: 100.23).poseToDisplayMs, 40, "Earliest actual native presentation once per source image")
    }
    static func stampsAndClockValidation() {
        let m = metrics(); m.posePublished(stamp: 7, at: 100)
        m.posePublished(stamp: 4103, at: 100.01) // Same bounded ring slot, different exact tag.
        m.receivedImage(sequence: 1, poseStamp: 7, at: 100.02)
        m.receivedImage(sequence: 2, poseStamp: .nan, at: 100.02)
        m.receivedImage(sequence: 3, poseStamp: .infinity, at: 100.02)
        let c = m.presentationContext()!
        for i in 1...3 { m.presented(imageSequence: UInt64(i), generated: false, at: 100.04, epoch: 1, context: c) }
        precondition(m.snapshot(now: 100.05).poseToDisplayMs == nil)
        m.receivedImage(sequence: 4, poseStamp: 4103, at: 100.02)
        m.presented(imageSequence: 4, generated: false, at: 1_700_000_000, epoch: 1, context: c)
        precondition(m.snapshot(now: 100.26).poseToDisplayMs == nil, "Wrong clock must not become measured milliseconds")
        m.presented(imageSequence: 4, generated: false, at: 100.05, epoch: 1, context: c)
        near(m.snapshot(now: 100.47).poseToDisplayMs, 40, "Exact bounded pose stamp")
    }
    static func pauseAndDisabledContexts() {
        let m = metrics(); let old = m.presentationContext()!
        m.observeProducer(producer, frames: 1, at: 100.01, active: false)
        let paused = m.presentationContext()!
        precondition(paused != old)
        for i in 0...40 {
            let t = 100.02 + Double(i) / 120
            m.presented(imageSequence: 0, generated: false, at: t, epoch: 2, context: paused)
            m.presented(imageSequence: 0, generated: false, at: t + 0.0001, epoch: 2, context: old)
        }
        let s = m.snapshot(now: 100.36)
        near(s.displayFPS, 120, "Paused menus still have actual display FPS")
        precondition(s.gameFPS == nil && s.poseToDisplayMs == nil && s.history.isEmpty)
        m.setEnabled(false, at: 100.4)
        precondition(m.presentationContext() == nil && m.snapshot(now: 100.4) == .empty)
        m.presented(imageSequence: 0, generated: false, at: 100.41, epoch: 2, context: paused)
        precondition(m.snapshot(now: 100.42) == .empty)
        m.setEnabled(true, at: 100.5)
        precondition(m.presentationContext() != paused)
        let same = m.presentationContext(); m.setEnabled(true, at: 100.51)
        precondition(m.presentationContext() == same, "Unrelated settings must not reset an already enabled HUD")
    }
    static func boundedHistoryAndSampling() {
        let m = metrics(); let snapshot = simulate(m, seconds: 15)
        precondition(snapshot.history.count <= 51 && !snapshot.history.isEmpty)
        precondition(snapshot.history.last!.time - snapshot.history.first!.time <= 10.000001)
        precondition(zip(snapshot.history, snapshot.history.dropFirst()).allSatisfy { $0.1.time - $0.0.time >= 0.199999 })
        let again = m.snapshot(now: 115.001)
        precondition(again == snapshot, "A redraw cannot create additional history samples")
        precondition(m.snapshot(now: .nan) == .empty)
        precondition(m.snapshot(now: 90) == .empty, "Host-clock rewind must retire the old window")
    }
    static func concurrentActualCallbacks() {
        let m = metrics(); m.sourceInactive(at: 100)
        let c = m.presentationContext()!
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<12 {
                let t = 100 + Double(i * 8 + worker) / 240
                m.presented(imageSequence: 0, generated: false, at: t, epoch: 3, context: c)
                m.presented(imageSequence: 0, generated: false, at: t, epoch: 3, context: c)
            }
        }
        let s = m.snapshot(now: 100.4)
        near(s.displayFPS, 240, "Concurrent duplicated actual callback observations are counted once")
        precondition(s.gameFPS == nil)
    }
}
