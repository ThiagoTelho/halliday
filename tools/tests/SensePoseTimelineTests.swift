import Foundation
import simd

@main struct SensePoseTimelineTests {
    static func near(_ a: simd_quatf, _ b: simd_quatf) {
        precondition(abs(simd_dot(simd_normalize(a).vector, simd_normalize(b).vector)) > 0.999999)
    }
    static func main() throws {
        let identity = simd_quatf(angle: 0, axis: [0, 1, 0])
        for sign: Float in [-1, 1] {
            let omega = SIMD3<Float>(0, sign * 3, 0)
            let q = simd_quatf(angle: sign * 0.3, axis: [1, 0, 0])
            let sample = SensePoseTimeline.sample(orientation: q, bodyAngular: omega,
                sampleHostNs: 985_000_000, reportAge: 0.01, now: 1, frameTarget: 1.01,
                fallbackLead: 0.03, historical: { _ in nil })!
            precondition(sample.targetHostNs == 1_010_000_000)
            near(sample.orientation, q * simd_quatf(angle: sign * 3 * 0.025, axis: [0, 1, 0]))
            // The previous independent age+lookahead guessed 40ms instead of25ms.
            let wrong = q * simd_quatf(angle: sign * 3 * 0.04, axis: [0, 1, 0])
            precondition(abs(simd_dot(sample.orientation.vector, wrong.vector)) < 0.9999)
            let capped = SensePoseTimeline.sample(orientation: q, bodyAngular: omega,
                sampleHostNs: 985_000_000, reportAge: 0.01, now: 1, frameTarget: 2,
                fallbackLead: 0.03, historical: { _ in nil })!
            precondition(capped.targetHostNs == 1_045_000_000, "Common horizon must respect the position filter's60ms support")
            let historical = simd_quatf(angle: sign * -0.1, axis: [0, 0, 1])
            let past = SensePoseTimeline.sample(orientation: q, bodyAngular: omega,
                sampleHostNs: 1_000_000_000, reportAge: 0, now: 1.01, frameTarget: 0.98,
                fallbackLead: 0.03, historical: { target in precondition(target == 980_000_000); return historical })!
            near(past.orientation, historical)
            let noBracket = SensePoseTimeline.sample(orientation: q, bodyAngular: omega,
                sampleHostNs: 1_000_000_000, reportAge: 0, now: 1.01, frameTarget: 0.98,
                fallbackLead: 0.03, historical: { _ in nil })!
            precondition(noBracket.targetHostNs == 1_000_000_000); near(noBracket.orientation, q)
            let lever = SIMD3<Float>(0.03, 0.01, -0.04) // Synthetic oracle, never a device offset.
            let mounted = SensePoseTimeline.mounted(position: [1, 2, 3], sensor: sample.orientation,
                localPosition: lever, localOrientation: simd_quatf(angle: 0.7, axis: [1, 0, 0]))
            precondition(simd_distance(mounted.position, SIMD3<Float>(1, 2, 3) + sample.orientation.act(lever)) < 1e-6)
            let zero = SensePoseTimeline.mounted(position: [1, 2, 3], sensor: sample.orientation,
                localPosition: .zero, localOrientation: identity)
            precondition(zero.position == SIMD3<Float>(1, 2, 3)); near(zero.orientation, sample.orientation)
        }
        precondition(SensePoseTimeline.sample(orientation: identity, bodyAngular: .zero,
            sampleHostNs: 1, reportAge: .nan, now: 1, frameTarget: 1.01, fallbackLead: 0.03, historical: { _ in nil }) == nil)
        if CommandLine.arguments.count > 1 { try savedMovements(CommandLine.arguments[1]) }
        print("PASS: common signed sensor target, exact frame time, historical bracket, transport mapping, position/orientation horizon, both hands and predict-before-local-lever order")
    }
    static func savedMovements(_ path: String) throws {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
        func quat(_ value: Any) -> simd_quatf { let a = value as! [NSNumber]; return simd_normalize(simd_quatf(ix: a[0].floatValue, iy: a[1].floatValue, iz: a[2].floatValue, r: a[3].floatValue)) }
        var checked = 0
        for hand in ["left", "right"] {
            for (a, b) in zip(rows, rows.dropFirst()) {
                let ta = (a["exposureHostNs"] as! NSNumber).int64Value
                let tb = (b["exposureHostNs"] as! NSNumber).int64Value
                let dt = Float(tb - ta) * 1e-9
                guard dt > 0, dt < 0.06 else { continue }
                let qa = quat(a[hand]!), qb = quat(b[hand]!)
                var relative = simd_normalize(qa.inverse * qb)
                if relative.real < 0 { relative = simd_quatf(vector: -relative.vector) }
                let length = simd_length(relative.imag)
                let rate = length > 1e-8 ? relative.imag * (2 * atan2(length, relative.real) / (length * dt)) : .zero
                let predicted = SensePoseTimeline.sample(orientation: qa, bodyAngular: rate, sampleHostNs: ta,
                    reportAge: 0, now: Double(ta) * 1e-9, frameTarget: Double(tb) * 1e-9,
                    fallbackLead: 0.03, historical: { _ in nil })!
                near(predicted.orientation, qb); precondition(predicted.targetHostNs == tb)
                checked += 1
            }
        }
        precondition(checked >= 120)
        print("Saved movement endpoints: \(checked) both-hand SO3 segments, known segment rates derived from recorded endpoints")
    }
}
