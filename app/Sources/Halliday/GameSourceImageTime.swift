import Foundation

/// Optional producer time of the exact published image, not host receipt time.
/// OpenXR intended display time and OpenVR submit-monotonic time have distinct
/// kinds. Only differences within one producer epoch and clock kind are used.
struct GameSourceImageTime: Equatable, Sendable {
    var epoch: UInt64
    var frameIndex: UInt64
    var nanoseconds: Int64
    var clockKind: UInt32

    static let invalid = Self(epoch: 0, frameIndex: 0, nanoseconds: 0, clockKind: 0)
    var isValid: Bool {
        epoch > 0 && frameIndex > 0 && nanoseconds > 0 && (clockKind == 1 || clockKind == 2)
    }

    func interval(since previous: Self) -> Double? {
        guard isValid, previous.isValid, epoch == previous.epoch,
              clockKind == previous.clockKind, frameIndex > previous.frameIndex else { return nil }
        let (delta, overflow) = nanoseconds.subtractingReportingOverflow(previous.nanoseconds)
        guard !overflow, delta > 0 else { return nil }
        return Double(delta) * 1e-9
    }
}
