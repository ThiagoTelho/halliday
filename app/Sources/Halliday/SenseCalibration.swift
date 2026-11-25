import Foundation

/// Calibration reports can arrive twice, out of order, or fail while a controller wakes.
/// Retain independently validated halves; the core still validates the completed data.
struct SenseCalibrationCollector: Sendable {
    struct Pair: Sendable { let first: [UInt8]; let second: [UInt8] }
    private var first: [UInt8]?
    private var second: [UInt8]?
    private(set) var issue = "waiting for both parts"

    mutating func consume(status: Int32, length: Int, bytes: [UInt8]) -> Pair? {
        guard status == 0 else {
            issue = String(format: "feature 05 failed 0x%08x", UInt32(bitPattern: status))
            return nil
        }
        guard length == 64, bytes.count == 64 else {
            issue = "feature 05 length \(length), expected 64"
            return nil
        }
        guard bytes[0] == 0x05, bytes[1] == 0 || bytes[1] == 0x81 else {
            issue = String(format: "unexpected feature/part %02x/%02x", bytes[0], bytes[1])
            return nil
        }
        let sent = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[60 + $1]) << ($1 * 8) }
        // Matches the core's USB convention: a zero CRC is accepted.
        guard sent == 0 || Self.crc32([0xa3] + bytes.prefix(60)) == sent else {
            issue = String(format: "feature 05 part %02x CRC mismatch", bytes[1])
            return nil
        }
        if bytes[1] == 0 { first = bytes } else { second = bytes }
        guard let first, let second else {
            issue = self.first == nil ? "waiting for part 00" : "waiting for part 81"
            return nil
        }
        return Pair(first: first, second: second)
    }

    mutating func rejectPair() {
        first = nil; second = nil
        issue = "core rejected calibration values"
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        }
        return ~crc
    }
}

/// Six two-read attempts over a bounded wake-up window. A retired job cannot resume.
struct SenseCalibrationRetryPlan: Sendable {
    static let maximumAttempts = 6
    private(set) var attempts = 0
    private(set) var finished = false
    mutating func beginAttempt(isCurrent: Bool) -> Bool {
        guard isCurrent, !finished, attempts < Self.maximumAttempts else {
            finished = true
            return false
        }
        attempts += 1
        return true
    }
    mutating func complete() { finished = true }
    var retryDelay: Double? {
        guard !finished, attempts > 0, attempts < Self.maximumAttempts else { return nil }
        return [0.25, 0.5, 1.0, 2.0, 3.0][attempts - 1]
    }
}
