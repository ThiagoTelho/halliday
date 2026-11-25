import Foundation

private func testRequire(_ value: @autoclosure () -> Bool, _ message: String = "Assertion failed") {
    guard value() else { testFailure(message) }
}
private func testFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}
private final class Capture: @unchecked Sendable { var values: [CompositorPresentationTelemetry.Summary] = [] }
@main struct CompositorPresentationTelemetryTests {
 static func main() {
    let capture = Capture(), stats = CompositorPresentationTelemetry(window: 3) { capture.values.append($0) }
    stats.configure(epoch: 1, period: 0.01)
    func frame(_ id: UInt64, _ gen: Bool = false) -> CompositorPresentationTelemetry.Frame {
        .init(epoch: 1, pulse: id, scene: id + 100, nativeSequence: 42, generated: gen,
              targetNs: Int64(id)*10_000_000 + 5_000_000, committedNs: Int64(id)*10_000_000 - 1_000_000, drawableWaitNs: 100_000)
    }
    stats.gpu(frame(1), startNs: 9_100_000, endNs: 9_300_000)
    stats.presented(frame(1), atNs: 10_000_000)
    stats.presented(frame(1), atNs: 10_000_000) // duplicate, never a fake zero-ms frame
    stats.presented(frame(2, true), atNs: 20_000_000)
    stats.presented(frame(3), atNs: 40_000_000)
    testRequire(capture.values.count == 1)
    let s = capture.values[0]
    testRequire(s.frames == 3 && s.native == 2 && s.generated == 1)
    testRequire(s.refreshGaps == 1 && s.rejectedCallbacks == 1)
    testRequire(s.intervalMaxMs == 20 && s.intervalP95Ms == 20)
    testRequire(abs(s.gpuQueueP95Ms - 0.1) < 1e-8 && abs(s.gpuWorkP95Ms - 0.2) < 1e-8)
    testRequire(s.lastPulse == 3 && s.lastScene == 103 && s.lastNativeSequence == 42)
    stats.configure(epoch: 2, period: 1.0/90)
    stats.presented(frame(4), atNs: 50_000_000) // retired callback cannot seed the next epoch
    testRequire(capture.values.count == 1)
    for id in 1...3 {
        let start = Int64(id)*11_111_111
        let f = CompositorPresentationTelemetry.Frame(epoch: 2, pulse: UInt64(id), scene: 9,
            nativeSequence: 99, generated: true, targetNs: start+5_555_555, committedNs: start-1_000_000, drawableWaitNs: 0)
        stats.presented(f, atNs: start)
    }
    testRequire(capture.values.count == 2 && capture.values[1].refreshGaps == 0)
    testRequire(capture.values[1].generated == 3)
    print("PASS: actual presentation interval gaps, duplicates, epoch/rate retirement, independent GPU feedback and native/generated identities; no synthetic FPS/latency acceptance claim")
 }
}
