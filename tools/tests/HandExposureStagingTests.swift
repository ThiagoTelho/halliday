import Foundation

@main struct HandExposureStagingTests {
    static let q = SIMD4<Float>(0, 0, 0, 1)
    static func frame(_ n: Int, at: Int64, left: Bool = false, generation: UInt64 = 10) -> HandTrackingWorker.Frame {
        .init(counter: n, exposureHostNs: at, headOrientation: q, headPosition: [1, 2, 3], heightLift: 0.1,
              handOrientations: (left ? [0, 1] : [1]).map { .init(index: $0, orientation: q) },
              views: [[], []], fisheyes: true, trackingGeneration: generation)
    }
    static func main() throws {
        var s = HandExposureStaging()
        s.insert(frame(1, at: 1_000_000_000), expected: [0, 1], nowNs: 1_020_000_000)
        precondition(s.ready(nowNs: 1_020_000_000, orientation: { _, _ in nil }) == nil)
        let recovered = s.ready(nowNs: 1_045_000_000, orientation: { hand, exposure in
            precondition(hand == 0 && exposure == 1_000_000_000); return q
        })!
        precondition(Set(recovered.handOrientations.map(\.index)) == [0, 1])
        precondition(recovered.headPosition == [1, 2, 3] && recovered.heightLift == 0.1)
        s.insert(frame(2, at: 2_000_000_000), expected: [1], nowNs: 2_020_000_000)
        precondition(s.ready(nowNs: 2_020_000_000, orientation: { _, _ in nil })?.counter == 2)

        // A genuinely stalled/unsettled left link cannot repeatedly freeze the
        // right. After one bounded warm-up, partial right frames continue60Hz.
        s.reset(); var rightTimes: [Int64] = []
        for tick in 0..<100 {
            let now = 3_000_000_000 + Int64(tick) * 8_333_334
            if tick % 2 == 0 { s.insert(frame(tick / 2, at: now - 20_000_000), expected: [0, 1], nowNs: now) }
            if let f = s.ready(nowNs: now, orientation: { _, _ in nil }) {
                precondition(f.handOrientations.map(\.index) == [1]); rightTimes.append(now)
            }
            precondition(s.count <= HandExposureStaging.capacity)
        }
        precondition(rightTimes.count >= 45)
        precondition(zip(rightTimes, rightTimes.dropFirst()).allSatisfy { $1 - $0 <= 16_666_668 })
        s.reset(); s.insert(frame(4, at: 4_000_000_000), expected: [0, 1], nowNs: 4_000_000_000)
        s.insert(frame(5, at: 4_016_666_667, left: true, generation: 11), expected: [0, 1], nowNs: 4_020_000_000)
        precondition(s.count == 1 && s.ready(nowNs: 4_021_000_000, orientation: { _, _ in nil })?.counter == 5)
        // A disconnect/optical-history clear can occur before any worker was
        // created. No pending exposure from that source may later become ready.
        s.insert(frame(6, at: 5_000_000_000), expected: [0, 1], nowNs: 5_020_000_000)
        s.reset()
        precondition(s.ready(nowNs: 5_080_000_000, orientation: { _, _ in q }) == nil)
        try savedReplay(CommandLine.arguments[1])
        print("PASS: late-left bracket reattaches original exposure, stalled left retains right60Hz, disconnected/unsettled hand need not wait, bounded queue, generation retirement and saved both-hand movement replay")
    }
    static func savedReplay(_ path: String) throws {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
        func vector(_ value: Any) -> SIMD4<Float> { let a = value as! [NSNumber]; return SIMD4(a[0].floatValue, a[1].floatValue, a[2].floatValue, a[3].floatValue) }
        let frames = rows.map { r -> HandTrackingWorker.Frame in
            let at = (r["exposureHostNs"] as! NSNumber).int64Value
            let head = r["head"] as! [NSNumber]
            return .init(counter: r["counter"] as! Int, exposureHostNs: at, headOrientation: SIMD4(head[3].floatValue, head[4].floatValue, head[5].floatValue, head[6].floatValue),
                headPosition: [head[0].floatValue, head[1].floatValue, head[2].floatValue], heightLift: 0,
                handOrientations: [.init(index: 1, orientation: vector(r["right"]!))], views: [[], []], fisheyes: true)
        }
        let exact = Dictionary(uniqueKeysWithValues: rows.map { r in ((r["exposureHostNs"] as! NSNumber).int64Value, vector(r["left"]!)) })
        var s = HandExposureStaging(), next = 0, outputs = 0, previous = -1
        let first = frames.first!.exposureHostNs, last = frames.last!.exposureHostNs
        var now = first + 20_000_000
        while now <= last + 100_000_000 {
            while next < frames.count && frames[next].exposureHostNs + 20_000_000 <= now {
                s.insert(frames[next], expected: [0, 1], nowNs: now); next += 1
            }
            if let f = s.ready(nowNs: now, orientation: { hand, at in now >= at + 44_000_000 && hand == 0 ? exact[at] : nil }) {
                precondition(f.counter > previous); previous = f.counter
                precondition(Set(f.handOrientations.map(\.index)) == [0, 1])
                precondition(f.handOrientations.first(where: { $0.index == 0 })!.orientation == exact[f.exposureHostNs]!)
                outputs += 1
            }
            now += 8_333_333
        }
        precondition(outputs >= frames.count - 2, "Late BT must not erase saved left-hand exposures")
        print("Saved replay: \(frames.count) exposures, \(outputs) paired outputs with24ms extra left-link latency")
    }
}
