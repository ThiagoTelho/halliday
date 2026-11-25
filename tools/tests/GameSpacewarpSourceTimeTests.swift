import Foundation

@main struct GameSpacewarpSourceTimeTests {
    typealias Decision = GameSpacewarpCadence.Decision
    static func stamp(_ frame: UInt64, ns: Int64, epoch: UInt64 = 7, kind: UInt32 = 1) -> GameSourceImageTime {
        .init(epoch: epoch, frameIndex: frame, nanoseconds: ns, clockKind: kind)
    }
    static func phase(_ decision: Decision) -> Double {
        guard case .predict(let p) = decision else { fatalError("Expected prediction, got \(decision)") }
        precondition(p > 0 && p <= 0.5)
        return Double(p)
    }
    static func requireClose(_ actual: Double, _ expected: Double, _ label: String) {
        precondition(abs(actual - expected) < 0.000001, "\(label): \(actual), expected \(expected)")
    }
    static func main() {
        var results: [[String: Any]] = []
        for display in [90.0, 120.0] {
            let tick = 1 / display, budget = tick * 2
            for kind in [UInt32(1), UInt32(2)] {
                for (label, receiptGap) in [("regular", budget), ("delayed", budget * 1.5), ("bunched", 0.0000001)] {
                    var policy = GameSpacewarpCadence()
                    let first = stamp(1, ns: 900_000_000_000, kind: kind)
                    let second = stamp(2, ns: first.nanoseconds + Int64((budget * 1e9).rounded()), kind: kind)
                    precondition(policy.update(sequence: 1, sourceTime: 10, target: 11, sourceInterval: budget,
                        imageTiming: first) == .source(resetHistory: true))
                    precondition(policy.update(sequence: 2, sourceTime: 10 + receiptGap, target: 11 + budget,
                        sourceInterval: budget, imageTiming: second) == .source(resetHistory: false))
                    let generated = policy.update(sequence: 2, sourceTime: 10 + receiptGap, target: 11 + budget + tick,
                        sourceInterval: budget, imageTiming: second)
                    requireClose(phase(generated), 0.5, "\(label) delivery at \(display) Hz")
                    results.append(["case": label, "clock_kind": kind, "display_hz": display, "source_hz": display / 2,
                                    "receipt_gap_ms": receiptGap * 1000, "phase": phase(generated)])
                }
            }
        }
        let budget = 1.0 / 60, tick = 1.0 / 120
        // A 43-FPS producer is below a 60-FPS budget. Its image motion spans
        // 23.256 ms; the forecast should advance only another 8.333 ms.
        let sourceStep: Int64 = 23_255_814
        let first = stamp(1, ns: 4_000_000_000)
        let second = stamp(2, ns: first.nanoseconds + sourceStep)
        for receiptGap in [Double(sourceStep) * 1e-9, 0.03, 0.0001] {
            var policy = GameSpacewarpCadence()
            _ = policy.update(sequence: 1, sourceTime: 20, target: 21, sourceInterval: budget, imageTiming: first)
            precondition(policy.update(sequence: 2, sourceTime: 20 + receiptGap, target: 21 + budget,
                sourceInterval: budget, imageTiming: second) == .source(resetHistory: false))
            let p = phase(policy.update(sequence: 2, sourceTime: 20 + receiptGap, target: 21 + budget + tick,
                sourceInterval: budget, imageTiming: second))
            let expected = tick / (Double(sourceStep) * 1e-9)
            requireClose(p, expected, "43-FPS motion duration must not become nominal 60 FPS")
            requireClose(p * Double(sourceStep) * 1e-9, tick, "constant velocity forecast time")
            results.append(["case": "43fps", "receipt_gap_ms": receiptGap * 1000,
                            "phase": p, "expected_phase": expected])
        }
        // Adjacent publication indices may hide skipped submissions. Time,
        // rather than the counter or negotiated budget, measures that pair.
        var policy = GameSpacewarpCadence()
        _ = policy.update(sequence: 1, sourceTime: 1, target: 1, sourceInterval: budget, imageTiming: first)
        let skipped = stamp(2, ns: first.nanoseconds + 50_000_000)
        precondition(policy.update(sequence: 2, sourceTime: 1.05, target: 1.05, sourceInterval: budget,
            imageTiming: skipped) == .source(resetHistory: false))
        requireClose(phase(policy.update(sequence: 2, sourceTime: 1.05, target: 1.05 + tick * 2,
            sourceInterval: budget, imageTiming: skipped)), tick * 2 / 0.05, "skipped submission pair")

        for invalid in [GameSourceImageTime.invalid, stamp(2, ns: 0), stamp(2, ns: first.nanoseconds - 1),
                        stamp(2, ns: second.nanoseconds, epoch: 8), stamp(2, ns: second.nanoseconds, kind: 2),
                        stamp(1, ns: second.nanoseconds), stamp(2, ns: second.nanoseconds, kind: 999)] {
            policy.reset()
            _ = policy.update(sequence: 1, sourceTime: 1, target: 1, sourceInterval: budget, imageTiming: first)
            precondition(policy.update(sequence: 2, sourceTime: 1 + budget, target: 1 + budget,
                sourceInterval: budget, imageTiming: invalid) == .source(resetHistory: true))
            precondition(policy.update(sequence: 2, sourceTime: 1 + budget, target: 1 + budget + tick,
                sourceInterval: budget, imageTiming: invalid) == .original)
        }
        // Absence, advertised-invalid, and a producer's changed timestamp on
        // the same cached image are different events, never silently mixed.
        policy.reset()
        _ = policy.update(sequence: 1, sourceTime: 1, target: 1, sourceInterval: budget)
        precondition(policy.update(sequence: 2, sourceTime: 1 + budget, target: 1 + budget,
            sourceInterval: budget, imageTiming: second) == .source(resetHistory: true))
        let third = stamp(3, ns: second.nanoseconds + Int64((budget * 1e9).rounded()))
        precondition(policy.update(sequence: 3, sourceTime: 1 + budget * 2, target: 1 + budget * 2,
            sourceInterval: budget, imageTiming: third) == .source(resetHistory: false))
        _ = phase(policy.update(sequence: 3, sourceTime: 1 + budget * 2, target: 1 + budget * 2 + tick,
            sourceInterval: budget, imageTiming: third))
        precondition(policy.update(sequence: 3, sourceTime: 1 + budget * 2, target: 1 + budget * 2 + tick * 2,
            sourceInterval: budget, imageTiming: stamp(3, ns: third.nanoseconds + 1)) == .source(resetHistory: true))

        // A prolonged receipt stall must not revive old motion simply because
        // source timestamps look plausible. Reprime on the next valid pair.
        policy.reset()
        _ = policy.update(sequence: 1, sourceTime: 1, target: 1, sourceInterval: budget, imageTiming: first)
        precondition(policy.update(sequence: 2, sourceTime: 10, target: 10, sourceInterval: budget,
            imageTiming: second) == .source(resetHistory: true))
        precondition(policy.update(sequence: 2, sourceTime: 10, target: 10 + tick,
            sourceInterval: budget, imageTiming: second) == .original)
        if CommandLine.arguments.count > 1 {
            let receipt: [String: Any] = ["scope": "CPU analytical trajectories; no GPU/game/headset measurement",
                "results": results, "pass": true,
                "coverage": ["same image times despite delayed/bunched readback", "actual43FPS under60FPS budget",
                    "skipped submissions", "epoch/kind/time/frame invalidation", "availability transition",
                    "cached metadata change", "receipt stall", "legacy absence retains explicit approximate fallback"]]
            let data = try! JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS: exact per-image time at90/120Hz, delayed/bunched receipt, actual43FPS, skipped submissions, clock/epoch/time/frame/availability/cache/stall guards")
    }
}
