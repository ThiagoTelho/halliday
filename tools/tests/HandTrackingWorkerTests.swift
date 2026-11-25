import Foundation
import CHallidayCore

private final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var calls: [Int] = []
    var outputs: [HandTrackingWorker.Output] = []
    var resets = 0
    var closes = 0
    var touchedMain = false
    func record(_ operation: () -> Void) { lock.lock(); defer { lock.unlock() }; touchedMain = touchedMain || Thread.isMainThread; operation() }
}

@main struct HandTrackingWorkerTests {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func wait(_ signal: DispatchSemaphore, _ message: String) throws {
        try require(signal.wait(timeout: .now() + 5) == .success, message)
    }
    static func frame(_ counter: Int) -> HandTrackingWorker.Frame {
        .init(counter: counter, exposureHostNs: Int64(counter) * 1_000_000, headOrientation: [0, 0, 0, 1],
              headPosition: [1, 2, 3], heightLift: 0.125,
              handOrientations: [.init(index: 0, orientation: [0, 0, 0, 1]), .init(index: 1, orientation: [0, 0, 0, 1])],
              views: [[], []], fisheyes: true)
    }
    static func fixes() -> [HandTrackingWorker.Fix] {
        [0, 1].map { .init(index: $0, position: [Float($0), 2, 3], heading: 0.2, tilt: [0.1, 0.3], sightings: 8, rms: 0.7) }
    }
    static func main() {
        do {
            try coalesces()
            try resets()
            try geometryGenerations()
            try trackingGenerations()
            try closesAndDrops()
            try nativeEquivalence(path: CommandLine.arguments[1])
            if CommandLine.arguments.count > 2 {
                try nativeEquivalence(path: CommandLine.arguments[2], alignment: loadedProfileAlignment(), requireBoth: true)
            }
            print("PASS: serial off-main optical worker, latest-only pending frame, reset/close generations, asynchronous lifetime cleanup and exact synchronous C-ABI replay equivalence; no HID")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
    static func coalesces() throws {
        let recorder = Recorder(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let output = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        let solver = HandTrackingWorker.Solver(solve: { f in
            recorder.record { recorder.calls.append(f.counter) }
            if f.counter == 1 { entered.signal(); release.wait() }
            return fixes()
        }, reset: { recorder.record { recorder.resets += 1 } }, close: { recorder.record { recorder.closes += 1 }; closed.signal() })
        let worker = HandTrackingWorker(solver: solver) { value in
            recorder.record { recorder.outputs.append(value) }; output.signal()
        }
        worker.submit(frame(1)); try wait(entered, "First solve did not start")
        for counter in 2...100 { worker.submit(frame(counter)) }
        release.signal(); try wait(output, "First output missing"); try wait(output, "Latest output missing")
        try require(recorder.lock.withLock { recorder.calls == [1, 100] && recorder.outputs.map { $0.frame.counter } == [1, 100] && !recorder.touchedMain }, "Worker queued stale exposures or used main thread")
        let value = recorder.lock.withLock { recorder.outputs.last! }
        try require(value.frame.exposureHostNs == 100_000_000 && value.frame.headPosition == [1, 2, 3] && value.frame.heightLift == 0.125 && value.fixes.map(\.index) == [0, 1], "Exposure/world context or hand order changed")
        try require(worker.isCurrent(value), "Fresh output rejected")
        worker.reset()
        try require(!worker.isCurrent(value), "Already-delivered result survived reset/actor handoff")
        worker.close(); try wait(closed, "Worker did not clean up")
    }
    static func resets() throws {
        let recorder = Recorder(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let output = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        let worker = HandTrackingWorker(solver: .init(solve: { f in
            recorder.record { recorder.calls.append(f.counter) }
            if f.counter == 1 { entered.signal(); release.wait() }
            return fixes()
        }, reset: { recorder.record { recorder.resets += 1 } }, close: { closed.signal() })) { value in
            recorder.record { recorder.outputs.append(value) }; output.signal()
        }
        worker.submit(frame(1)); try wait(entered, "Reset fixture did not start")
        worker.submit(frame(2)); worker.reset(); worker.submit(frame(3))
        release.signal(); try wait(output, "New generation output missing")
        try require(recorder.lock.withLock { recorder.calls == [1, 3] && recorder.outputs.map { $0.frame.counter } == [3] && recorder.resets == 1 }, "Reset delivered old result, retained pending work, or failed solver reset")
        worker.close(); try wait(closed, "Reset fixture did not close")
    }
    static func closesAndDrops() throws {
        for drop in [false, true] {
            let recorder = Recorder(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
            var worker: HandTrackingWorker? = HandTrackingWorker(solver: .init(solve: { f in
                recorder.record { recorder.calls.append(f.counter) }
                entered.signal(); release.wait(); return fixes()
            }, reset: {}, close: { recorder.record { recorder.closes += 1 }; closed.signal() })) { value in
                recorder.record { recorder.outputs.append(value) }
            }
            worker!.submit(frame(1)); try wait(entered, "Close fixture did not start")
            worker!.submit(frame(2))
            if drop { worker = nil } else { worker!.close(); worker!.close(); worker!.submit(frame(3)) }
            // This assertion is reachable only if close/deinit does not wait for blocked work.
            try require(closed.wait(timeout: .now()) == .timedOut, "Cleanup ran concurrently with active solve")
            release.signal(); try wait(closed, "In-flight lifetime cleanup missing")
            try require(recorder.lock.withLock { recorder.calls == [1] && recorder.outputs.isEmpty && recorder.closes == 1 && !recorder.touchedMain }, "Close/deinit allowed old callbacks, pending work or duplicate cleanup")
        }
    }

    static func geometryGenerations() throws {
        let recorder = Recorder(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let output = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        let worker = HandTrackingWorker(solver: .init(solve: { f in
            recorder.record { recorder.calls.append(f.counter) }
            if f.counter == 1 { entered.signal(); release.wait() }
            return fixes()
        }, reset: { recorder.record { recorder.resets += 1 } }, close: { closed.signal() })) { value in
            recorder.record { recorder.outputs.append(value) }; output.signal()
        }
        worker.submit(frame(1)); try wait(entered, "Geometry fixture did not start")
        var calibrated = frame(2); calibrated.fisheyeAlignment = [0.01, -0.02, 0.01]
        worker.submit(calibrated)
        var latest = frame(3); latest.fisheyeAlignment = calibrated.fisheyeAlignment
        worker.submit(latest)
        release.signal(); try wait(output, "Calibrated generation output missing")
        let value = recorder.lock.withLock { recorder.outputs.last! }
        try require(recorder.lock.withLock { recorder.calls == [1, 3] && recorder.outputs.count == 1 && recorder.resets == 1 },
                    "Geometry change leaked an old result or did not reset solver history")
        try require(value.frame.fisheyeAlignment == calibrated.fisheyeAlignment && worker.isCurrent(value),
                    "Calibrated geometry did not accompany the exposure")
        // Repeated equal calibration retains temporal state; a hidden roundtrip
        // still invalidates outputs already queued for the display actor.
        var repeated = frame(4); repeated.fisheyeAlignment = calibrated.fisheyeAlignment
        worker.submit(repeated); try wait(output, "Repeated geometry output missing")
        try require(recorder.lock.withLock { recorder.resets == 1 }, "Equal profile reset hypotheses")
        var invalid = frame(5); invalid.fisheyeAlignment = [.nan, 0, 0]
        worker.submit(invalid)
        try require(!worker.isCurrent(value), "Invalid geometry retained an earlier queued result")
        worker.submit(frame(6)); try wait(output, "Identity geometry recovery missing")
        try require(recorder.lock.withLock { !recorder.calls.contains(5) && recorder.outputs.last?.frame.counter == 6 },
                    "Invalid alignment reached solver or blocked recovery")
        var tooLarge = frame(7); tooLarge.fisheyeAlignment = [1, 0, 0]
        worker.submit(tooLarge)
        worker.submit(frame(8)); try wait(output, "Out-of-domain geometry recovery missing")
        try require(recorder.lock.withLock { !recorder.calls.contains(7) }, "Unsafe alignment reached native solver")
        worker.close(); try wait(closed, "Geometry fixture did not close")
    }

    static func trackingGenerations() throws {
        let recorder=Recorder(), entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
        let output=DispatchSemaphore(value:0), closed=DispatchSemaphore(value:0)
        let worker=HandTrackingWorker(solver:.init(solve:{ f in
            recorder.record{recorder.calls.append(f.counter)}
            if f.counter==1{entered.signal();release.wait()}
            return fixes()
        },reset:{recorder.record{recorder.resets+=1}},close:{closed.signal()})){ value in
            recorder.record{recorder.outputs.append(value)};output.signal()
        }
        var first=frame(1);first.trackingGeneration=10
        worker.submit(first);try wait(entered,"Tracked fixture did not begin")
        var next=frame(2);next.trackingGeneration=11;worker.submit(next)
        var newest=frame(3);newest.trackingGeneration=11;worker.submit(newest)
        release.signal();try wait(output,"Replacement tracking generation did not solve")
        let value=recorder.lock.withLock{recorder.outputs.last!}
        try require(recorder.lock.withLock{recorder.calls==[1,3]&&recorder.outputs.count==1&&recorder.resets==1},
                    "Tracking discontinuity leaked a completed old-world result or missed reset")
        var same=frame(4);same.trackingGeneration=11;worker.submit(same);try wait(output,"Same generation did not solve")
        worker.submit(frame(5));try wait(output,"Legacy untagged fallback did not solve")
        try require(recorder.lock.withLock{recorder.resets==1}&&worker.isCurrent(value),
                    "Equal/zero generations must not clear hypotheses every frame")
        var changed=frame(6);changed.trackingGeneration=12;worker.submit(changed)
        try require(!worker.isCurrent(value),"Queued old-world callback survived a known nonzero change")
        try wait(output,"Known generation after unknown fallback did not solve")
        try require(recorder.lock.withLock{recorder.resets==2&&recorder.outputs.last?.frame.trackingGeneration==12},
                    "Unknown fallback erased the previous known generation or lost source metadata")
        worker.close();try wait(closed,"Tracked fixture did not close")

        let initial=Recorder(), ready=DispatchSemaphore(value:0), finished=DispatchSemaphore(value:0)
        let legacy=HandTrackingWorker(solver:.init(solve:{_ in fixes()},reset:{initial.record{initial.resets+=1}},close:{finished.signal()})){ value in
            initial.record{initial.outputs.append(value)};ready.signal()
        }
        legacy.submit(frame(1));try wait(ready,"Initial legacy frame missing")
        var known=frame(2);known.trackingGeneration=20;legacy.submit(known);try wait(ready,"Initial known generation missing")
        try require(initial.lock.withLock{initial.resets==0},"Binding a first known token must preserve legacy fixtures")
        legacy.close();try wait(finished,"Legacy fixture did not close")
    }

    struct SavedFrame: Decodable {
        let counter: Int, exposureHostNs: Int64
        let head: [Float], left: [Float], right: [Float]
        let views: [[[Float]]]
        var snapshot: HandTrackingWorker.Frame {
            .init(counter: counter, exposureHostNs: exposureHostNs, headOrientation: [head[3], head[4], head[5], head[6]],
                  headPosition: [head[0], head[1], head[2]], heightLift: 0.125,
                  handOrientations: [.init(index: 0, orientation: [left[0], left[1], left[2], left[3]]), .init(index: 1, orientation: [right[0], right[1], right[2], right[3]])],
                  views: views.map { $0.map { .init(x: $0[0], y: $0[1], area: UInt32($0[2]), peak: UInt32($0[3])) } }, fisheyes: true)
        }
    }
    static func loadedProfileAlignment() throws -> SIMD3<Float> {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-worker-camera-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = "WORKER-TEST-1"
        let value: [String: Any] = ["version": 1, "headset_id": identity, "camera_mode": 16,
            "right_fisheye_rotation_radians": [-0.004112071331861413, 0.003328861353291489, -0.01492005963837453]]
        try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
        guard let profile = CameraTrackingProfiles.load(for: identity, from: file) else {
            throw Failure(message: "Measured fixture profile did not pass the real host loader")
        }
        return profile.rightFisheyeRotation
    }
    static func nativeEquivalence(path: String, alignment: SIMD3<Float> = .zero, requireBoth: Bool = false) throws {
        let frames = try JSONDecoder().decode([SavedFrame].self, from: Data(contentsOf: URL(fileURLWithPath: path))).map {
            var frame = $0.snapshot; frame.fisheyeAlignment = alignment; return frame
        }
        let handle = halliday_hand_pair_open()!
        defer { halliday_hand_pair_close(handle) }
        halliday_hand_pair_set_fisheyes(handle, true)
        try require(halliday_hand_pair_set_fisheye_alignment(handle, [alignment.x, alignment.y, alignment.z]), "Valid profile rejected by real Core")
        let recorder = Recorder(), output = DispatchSemaphore(value: 0)
        let worker = HandTrackingWorker { value in recorder.record { recorder.outputs.append(value) }; output.signal() }
        defer { worker.close() }
        var handFixes = [0, 0]
        let phases: [Range<Int64>] = [1_353_585_370..<2_357_257_162, 2_467_341_662..<7_470_531_245, 7_523_847_620..<8_529_437_120]
        var phaseExposures = [0, 0, 0], phaseFixes = [[0, 0], [0, 0], [0, 0]]
        for frame in frames {
            let phase = phases.firstIndex { $0.contains(frame.exposureHostNs) }
            if let phase { phaseExposures[phase] += 1 }
            let views = frame.views.map { $0.map { HallidayCameraSpot(x: $0.x, y: $0.y, area: $0.area, peak: $0.peak) } }
            let h = frame.headOrientation
            var controllers = [Float](repeating: 0, count: 8)
            var controllerMask: UInt32 = 0
            for hand in frame.handOrientations {
                let q = hand.orientation
                for (axis, value) in [q.x, q.y, q.z, q.w].enumerated() { controllers[hand.index * 4 + axis] = value }
                controllerMask |= UInt32(1) << UInt32(hand.index)
            }
            let p = frame.headPosition
            var native = [HallidayHandFix(), HallidayHandFix()]
            let accepted = halliday_hand_pair_update(handle, UInt64(frame.exposureHostNs), [h.x, h.y, h.z, h.w],
                [p.x, p.y, p.z], controllers, controllerMask,
                views[0], UInt32(views[0].count), views[1], UInt32(views[1].count),
                views[2], UInt32(views[2].count), views[3], UInt32(views[3].count), &native)
            let expected: [HallidayHandFix?] = (0..<2).map { hand in
                accepted & (UInt32(1) << UInt32(hand)) != 0 ? native[hand] : nil
            }
            worker.submit(frame); try wait(output, "Real worker replay timed out")
            let actual = recorder.lock.withLock { recorder.outputs.last! }
            try require(actual.frame.counter == frame.counter && actual.frame.exposureHostNs == frame.exposureHostNs && !recorder.touchedMain, "Real exposure context or worker thread changed")
            for hand in 0...1 {
                let got = actual.fixes.first { $0.index == hand }
                try require((got != nil) == (expected[hand] != nil), "Worker changed accepted/rejected optical fix")
                if let got, let want = expected[hand] {
                    try require(got.position == SIMD3(want.position.0, want.position.1, want.position.2) && got.heading == want.heading && got.tilt == SIMD2(want.tilt.0, want.tilt.1) && got.sightings == want.sightings && got.rms == want.rms, "Worker changed native position, rotation or fit values")
                    handFixes[hand] += 1
                    if let phase {
                        phaseFixes[phase][hand] += 1
                        if requireBoth && frames.count == 440 {
                            try require(got.sightings >= 10 && got.rms < 2, "Recorded phase lost its strong optical fit")
                        }
                    }
                }
            }
        }
        try require(handFixes[1] > 0 && (!requireBoth || handFixes[0] > 0), "Real replay fixture never exercised required accepted fixes")
        if requireBoth && frames.count == 440 {
            try require(phaseExposures == [60, 300, 48] && phaseFixes == [[60, 60], [300, 0], [48, 48]],
                        "Full host replay lost an illuminated hand or falsely acquired the explicitly dark right controller")
            print("PASS: full60Hz host phases [60,300,48]: calibrated left408/408, illuminated right108/108, dark-right false fixes0/300; actual profile loader -> Frame -> worker -> C ABI")
        }
        print("PASS: \(frames.count) saved stereo exposures matched synchronous C-ABI fixes bit-for-bit (alignment \(alignment), fixes left=\(handFixes[0]) right=\(handFixes[1]))")
    }
}
