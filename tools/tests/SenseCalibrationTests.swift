import Foundation
import CHallidayCore

@main
struct SenseCalibrationTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        let first = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let second = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let core = halliday_sense_open(0x0e45)!
        defer { halliday_sense_close(core) }
        var collector = SenseCalibrationCollector()
        require(collector.consume(status: -1, length: 64, bytes: first) == nil, "Failed HID read accepted")
        require(collector.consume(status: 0, length: 63, bytes: first) == nil, "Truncated HID read accepted")
        var bad = first; bad[10] ^= 1
        require(collector.consume(status: 0, length: 64, bytes: bad) == nil, "Corrupt CRC accepted")
        require(collector.consume(status: 0, length: 64, bytes: second) == nil, "Single part became a pair")
        require(collector.consume(status: 0, length: 64, bytes: second) == nil, "Duplicate part became a pair")
        require(collector.consume(status: -2, length: 64, bytes: first) == nil, "Transient failure accepted")
        let pair = collector.consume(status: 0, length: 64, bytes: first)!
        require(pair.first == first && pair.second == second, "Reordered parts were not retained")
        require(halliday_sense_calibrate(core, pair.first, pair.second, 64), "Actual Rust parser rejected valid captured pair")
        require(!halliday_sense_calibrate(core, first, first, 64), "Actual Rust parser accepted duplicate parts")
        collector.rejectPair()
        require(collector.consume(status: 0, length: 64, bytes: first) == nil, "Rejected pair retained old half")
        require(collector.consume(status: 0, length: 64, bytes: bad) == nil, "Corrupt half displaced valid half")
        let recovered = collector.consume(status: 0, length: 64, bytes: second)!
        require(halliday_sense_calibrate(core, recovered.first, recovered.second, 64), "Recovery pair did not validate")
        var unknown = first; unknown[1] = 0x7f
        var empty = SenseCalibrationCollector()
        require(empty.consume(status: 0, length: 64, bytes: unknown) == nil, "Unknown part accepted")
        require(empty.consume(status: 0, length: 64, bytes: Array(first.dropLast())) == nil, "Short buffer accepted")
        var usbFirst = first, usbSecond = second
        for i in 60..<64 { usbFirst[i] = 0; usbSecond[i] = 0 }
        require(empty.consume(status: 0, length: 64, bytes: usbFirst) == nil, "Single USB half accepted")
        let usb = empty.consume(status: 0, length: 64, bytes: usbSecond)!
        require(halliday_sense_calibrate(core, usb.first, usb.second, 64), "Core's zero-CRC USB convention rejected")

        var plan = SenseCalibrationRetryPlan()
        var totalReads = 0
        while plan.beginAttempt(isCurrent: true) {
            totalReads += 2
            if plan.retryDelay == nil { break }
        }
        require(plan.attempts == 6 && totalReads == 12 && plan.retryDelay == nil, "Retry budget is not bounded")
        require(!plan.beginAttempt(isCurrent: true), "Exhausted plan resumed")
        var retired = SenseCalibrationRetryPlan()
        require(retired.beginAttempt(isCurrent: true), "Initial current connection skipped")
        require(!retired.beginAttempt(isCurrent: false), "Detached/stopped generation retried")
        require(!retired.beginAttempt(isCurrent: true) && retired.retryDelay == nil, "Retired job affected replacement connection")
        var success = SenseCalibrationRetryPlan()
        require(success.beginAttempt(isCurrent: true), "Initial attempt skipped")
        success.complete()
        require(success.retryDelay == nil && !success.beginAttempt(isCurrent: true), "Success kept retrying")
        print("PASS: captured reports through actual Rust parser, transient HID errors, duplicates, reordered/CRC-bad halves, recovery, bounded retries and retired/successful job cancellation")
    }
}
