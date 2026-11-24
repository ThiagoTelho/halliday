import Foundation
import CHallidayCore

@main struct SenseLEDProgrammingTests {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    /// An independent oracle over the complete Bluetooth wire report, not its source fields.
    static func crc(_ report: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in [0xa2] + Array(report.prefix(74)) {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        }
        return ~value
    }
    static func uint32(_ report: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(report[at + $1]) << ($1 * 8) }
    }
    static func run() throws {
        var transport = SenseHapticScheduler()
        transport.connect(hand: 0, generation: 1, bluetooth: true)
        transport.connect(hand: 1, generation: 2, bluetooth: true)
        var left = SenseLEDProgramming(), right = SenseLEDProgramming()
        let id0 = transport.nextReport(hand: 0, generation: 1)!
        let off = left.report(transportSequence: id0.sequence, transportCounter: id0.counter,
                              phase: 5, pulse: 42, position: 0x0807_0605, cycle: 50_000_000, hostMicroseconds: 0x0403_0201)
        try require(off.count == 78 && off[22] == 5, "Off command was not composed as a real LED report")
        // Other output consumes a full transport-counter cycle without changing LED settings.
        for _ in 0..<255 { _ = transport.nextReport(hand: 0, generation: 1) }
        let id1 = transport.nextReport(hand: 0, generation: 1)!
        try require(id1 == id0, "Fixture did not recreate transport counter alias")
        let on = left.report(transportSequence: id1.sequence, transportCounter: id1.counter,
                             phase: 6, pulse: 42, position: 0x0807_0605, cycle: 50_000_000, hostMicroseconds: 0x0403_0201)
        try require(on[23] != off[23], "Changed LED phase reused its latch after transport-counter wrap")
        try require(on[22] == 6 && on[1] == off[1] && on[41] == off[41], "Fix altered the transport header/counter or phase")
        let rightID = transport.nextReport(hand: 1, generation: 2)!
        let other = right.report(transportSequence: rightID.sequence, transportCounter: rightID.counter,
                                 phase: 5, pulse: 42, position: 123, cycle: 50_000_000, hostMicroseconds: 456)
        try require(other[23] == off[23], "Programming left changed the right controller's LED sequence")
        let syncID = transport.nextReport(hand: 0, generation: 1)!
        var previous = left.report(transportSequence: syncID.sequence, transportCounter: syncID.counter,
                                   phase: 1, pulse: 42, position: 987, cycle: 50_050_000, hostMicroseconds: 789)
        try require(previous[22] == 1 && previous[23] != on[23], "Normal synchronization failed to latch after diagnostic phase")
        for report in [off, on, other, previous] {
            try require(Array(report.prefix(3)) == [0x31, (report[41] & 15) << 4, 0x10], "Bluetooth transport layout changed")
            try require(report[24] == 42 && Array(report[33..<37]) == [255, 255, 255, 255], "LED duration/selection changed")
            try require(uint32(report, 74) == crc(report), "LED-settings sequence did not participate in valid CRC")
        }
        try require(uint32(on, 18) == 0x0403_0201 && uint32(on, 25) == 0x0807_0605 && uint32(on, 29) == 50_000_000,
                    "Wire timing or host timestamp changed")
        for _ in 0..<260 {
            let id = transport.nextReport(hand: 0, generation: 1)!
            let next = left.report(transportSequence: id.sequence, transportCounter: id.counter,
                                   phase: 1, pulse: 42, position: 987, cycle: 50_050_000, hostMicroseconds: 789)
            try require(next[23] != previous[23] && uint32(next, 74) == crc(next), "LED latch did not survive its own UInt8 wrap")
            previous = next
        }
        try mixedOutputPreservesLEDs()
        print("PASS: real C-ABI mixed LED/haptic output preserves per-device LED latch across start/stop/cancellation, sequence wraps and reconnect; independent CRC/latch oracle; no HID writes")
    }

    /// Device-side latch semantics documented by pssense_led_settings: settings
    /// are consumed only when the LED sequence changes, regardless of rumble flags.
    struct LEDLatch {
        var sequence: UInt8 = 0
        var settings = [UInt8](repeating: 0, count: 15)
        mutating func accept(_ report: [UInt8]) throws {
            try require(uint32(report, 74) == crc(report), "Device model rejected CRC")
            if report[23] != sequence {
                sequence = report[23]
                settings = Array(report[22..<37])
            }
        }
    }

    static func mixedOutputPreservesLEDs() throws {
        var devices = [SenseLEDProgramming(), SenseLEDProgramming()]
        var latches = [LEDLatch(), LEDLatch()]
        var transport = SenseHapticScheduler()
        for hand in 0..<2 { transport.connect(hand: hand, generation: UInt64(hand + 1), bluetooth: true) }
        let initial = devices[0].vibrationReport(transportSequence: 0, transportCounter: 0,
            amplitude: 0.5, frequencyHz: 120, hostMicroseconds: 1)!
        try require(initial[22..<37].allSatisfy { $0 == 0 }, "Unconfigured output invented LED timing")
        try latches[0].accept(initial)

        let baseline = devices[0].report(transportSequence: 1, transportCounter: 1, phase: 1,
            pulse: 42, position: 100, cycle: 50_050_000, hostMicroseconds: 2)
        var oldBehavior = LEDLatch()
        try oldBehavior.accept(baseline)
        var standalone = [UInt8](repeating: 0, count: 78)
        halliday_sense_vibration_report(2, 2, 0.5, 120, 3, &standalone)
        try oldBehavior.accept(standalone)
        try require(baseline[22] == 1 && oldBehavior.settings[0] == 0,
                    "Regression fixture did not reproduce the old phase-INIT reset")

        var wrapped = [false, false]
        var previousSequence: [UInt8?] = [nil, nil]
        for iteration in 0..<530 {
            for hand in 0..<2 {
                let id = transport.nextReport(hand: hand, generation: UInt64(hand + 1))!
                let phase: UInt8 = hand == 0 ? (iteration % 3 == 0 ? 5 : 1) : 6
                let led = devices[hand].report(transportSequence: id.sequence, transportCounter: id.counter,
                    phase: phase, pulse: UInt8(30 + hand), position: UInt32(iteration + hand * 1000),
                    cycle: UInt32(50_000_000 + hand), hostMicroseconds: UInt32(iteration))
                if let previous = previousSequence[hand], led[23] < previous { wrapped[hand] = true }
                previousSequence[hand] = led[23]
                try latches[hand].accept(led)
                let otherSettings = latches[1 - hand].settings
                // Includes explicit stop/cancellation and a repeated active refresh.
                for amplitude: Float in [0.5, 0, 0.75] {
                    let id = transport.nextReport(hand: hand, generation: UInt64(hand + 1))!
                    let packet = devices[hand].vibrationReport(transportSequence: id.sequence,
                        transportCounter: id.counter, amplitude: amplitude, frequencyHz: 60,
                        hostMicroseconds: UInt32(iteration + 10_000))!
                    try require(Array(packet[22..<37]) == Array(led[22..<37]), "Haptics replaced current LED settings")
                    try require(packet[23] == led[23], "Haptics advanced the LED latch")
                    try require(packet[1] == (id.sequence & 15) << 4 && packet[41] == id.counter &&
                        packet[3] == 0x23 && packet[5] == UInt8(amplitude * 255), "Retained LEDs replaced fresh haptic flags/transport")
                    try require(uint32(packet, 18) == UInt32(iteration + 10_000), "Retained LEDs replayed an old host timestamp")
                    try latches[hand].accept(packet)
                    try require(latches[hand].settings == Array(led[22..<37]), "Mixed output changed the device-side LED latch")
                    try require(latches[1 - hand].settings == otherSettings, "One hand's output changed the other hand")
                }
            }
        }
        try require(wrapped.allSatisfy { $0 }, "Fixture missed LED sequence wrap")

        let reconnected = SenseLEDProgramming()
        let fresh = reconnected.vibrationReport(transportSequence: 0, transportCounter: 0,
            amplitude: 0, frequencyHz: 0, hostMicroseconds: 1)!
        try require(fresh[22..<37].allSatisfy { $0 == 0 }, "Reconnect replayed a previous connection's LED cache")
        var invalid = baseline; invalid[25] ^= 1
        var output = [UInt8](repeating: 0xaa, count: 78)
        let valid = invalid.withUnsafeBufferPointer {
            halliday_sense_vibration_report_with_led(0, 0, 1, 120, 0, $0.baseAddress, &output)
        }
        try require(!valid && output.allSatisfy { $0 == 0xaa }, "Damaged LED cache was transmitted or touched output")
        var alias = baseline
        let aliasValid = alias.withUnsafeMutableBufferPointer {
            halliday_sense_vibration_report_with_led(4, 4, 0, 120, 99, $0.baseAddress, $0.baseAddress)
        }
        try require(aliasValid && Array(alias[22..<37]) == Array(baseline[22..<37]) &&
                    uint32(alias, 74) == crc(alias), "In-place output lost retained LED settings or CRC")
        try require(!halliday_sense_vibration_report_with_led(0, 0, 0, 0, 0, nil, nil), "Null output was accepted")
    }
}
