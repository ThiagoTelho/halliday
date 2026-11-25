import Foundation

/// Per-connection host-side synchronization; hardware phases2...4 remain undocumented.
/// We deliberately retain Monado's PRESCAN wire phase, with explicit clock, output-echo
/// and independent optical confirmation states rather than claiming phase4 means success.
struct SenseLEDSynchronizer: Sendable {
    enum State: String, Sendable { case warming, awaitingEcho, observing, synchronized, stale }
    struct Feedback: Sendable {
        let sequence: UInt32, ticks: UInt32, echoedHostUs: UInt32
        let crcFailures: UInt8
        let receivedNs: Int64
    }
    struct Command: Equatable, Sendable {
        let phase: UInt8, pulse: UInt8, position: UInt32, cycle: UInt32
    }
    private(set) var state: State = .warming
    private var last: Feedback?
    private var totalTicks: Int64 = 0
    private var offsets: [Int64] = []
    private var command: Command?
    private var commandAt: Int64 = 0
    private var sent: [(hostUs: UInt32, sentNs: Int64)] = []
    private var echoedAt: Int64?
    private var confirmedExposures = 0
    private var lastOpticalCounter: Int64?
    private var lastOpticalNs: Int64 = 0
    private var lastCameraCounter: Int64?
    private var lastCameraNs: Int64 = 0

    mutating func reset() { self = Self() }
    mutating func receive(_ value: Feedback) {
        if let old = last {
            if value.sequence == old.sequence { return }
            let ticks = Int32(bitPattern: value.ticks &- old.ticks)
            let sequence = Int32(bitPattern: value.sequence &- old.sequence)
            if sequence <= 0 || ticks <= 0 || value.receivedNs <= old.receivedNs ||
                value.receivedNs-old.receivedNs > 250_000_000 {
                reset()
            } else { totalTicks += Int64(ticks) }
        }
        if last == nil { totalTicks = Int64(value.ticks) }
        if let old = last, value.crcFailures != old.crcFailures {
            // Device-reported dropped output is not a successful synchronization.
            command = nil; sent.removeAll(); echoedAt = nil; confirmedExposures = 0; state = .warming
        }
        last = value
        offsets.append(value.receivedNs - totalTicks * 1000 / 3)
        if offsets.count > 240 { offsets.removeFirst(offsets.count-240) }
        // An echoed timestamp proves receipt of a known output containing these LED
        // settings, not the undocumented internal latch state or actual light emission.
        if echoedAt == nil, sent.contains(where: {
            $0.hostUs == value.echoedHostUs && value.receivedNs >= $0.sentNs && value.receivedNs-$0.sentNs < 250_000_000
        }) { echoedAt = value.receivedNs; state = .observing }
    }
    mutating func outputSent(hostUs: UInt32, atNs now: Int64, settings: Command) {
        guard let command, settings == command, now >= commandAt else { return }
        sent.append((hostUs, now)); if sent.count > 32 { sent.removeFirst(sent.count-32) }
    }
    /// Camera timestamps must name the real exposure, not callback arrival time.
    /// centreOffsetNs preserves the caller's existing camera-to-pulse calibration.
    mutating func camera(counter: Int64, exposureNs: Int64, periodNs: Double,
                         centreOffsetNs: Int64, nowNs: Int64, pulse: UInt8 = 42) -> Command? {
        guard exposureNs > 0, exposureNs <= nowNs, nowNs-exposureNs < 100_000_000,
              periodNs.isFinite, (8_000_000...34_000_000).contains(periodNs),
              (-34_000_000...34_000_000).contains(centreOffsetNs), (1...42).contains(pulse) else { return nil }
        if let old = lastCameraCounter, counter < old || exposureNs < lastCameraNs { reset() }
        guard lastCameraCounter != counter else { return nil }
        lastCameraCounter = counter; lastCameraNs = exposureNs
        guard let last, nowNs >= last.receivedNs, nowNs-last.receivedNs < 100_000_000,
              offsets.count >= 30, let offset = offsets.min() else { state = .stale; return nil }
        guard command == nil || nowNs-commandAt >= 100_000_000 else { return nil }
        let deviceNs = exposureNs + centreOffsetNs - offset
        let next = Command(phase: 1, pulse: pulse,
            position: UInt32(truncatingIfNeeded: deviceNs * 3 / 1000), cycle: UInt32((periodNs*3).rounded()))
        command = next; commandAt = nowNs; sent.removeAll(); echoedAt = nil
        confirmedExposures = 0; lastOpticalCounter = nil; state = .awaitingEcho
        return next
    }
    /// Only independent accepted optical evidence may label a synchronization successful.
    /// Missing/occluded hands are absence of evidence, never a reason to hunt LED phases.
    mutating func optical(counter: Int64, exposureNs: Int64, visible: Bool) {
        guard let applied = echoedAt, visible, exposureNs > applied,
              exposureNs > lastOpticalNs, lastOpticalCounter.map({counter > $0}) ?? true else { return }
        lastOpticalCounter = counter; lastOpticalNs = exposureNs
        confirmedExposures += 1
        if confirmedExposures >= 2 { state = .synchronized }
    }
}
