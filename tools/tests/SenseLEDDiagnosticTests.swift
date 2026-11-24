import Foundation

@main struct SenseLEDDiagnosticTests {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func parse(_ json: String, now: TimeInterval = 1000) -> [String: UInt8] {
        SenseLEDDiagnostic.phases(data: Data(json.utf8), now: now)
    }
    static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() throws {
        try require(SenseLEDDiagnostic.phases(data: nil, now: 1000).isEmpty, "Missing file must restore sync")
        try require(SenseLEDDiagnostic.phases(data: Data(), now: 1000).isEmpty, "Empty file must restore sync")
        try require(parse("{\"expires_at\":1008,\"left\":6}") == ["left": 6], "Left-only override affected another hand")
        try require(parse("{\"expires_at\":1008,\"right\":5}") == ["right": 5], "Right-only override affected another hand")
        try require(parse("{\"expires_at\":1008,\"left\":6,\"right\":5}") == ["left": 6, "right": 5], "Independent phases were not retained")
        for phase in [1, 5, 6] {
            try require(parse("{\"expires_at\":1008,\"left\":\(phase)}") == ["left": UInt8(phase)], "Valid phase rejected")
        }
        try require(parse("{\"expires_at\":1010,\"left\":1}") == ["left": 1], "Ten-second boundary must be accepted")
        for expiry in ["1000", "999.999", "1010.001", "1e999", "true", "null", "\"1008\"", "\"NaN\""] {
            try require(parse("{\"expires_at\":\(expiry),\"left\":6}").isEmpty, "Invalid expiry accepted: \(expiry)")
        }
        for phase in ["0", "2", "3", "4", "7", "255", "256", "-1", "5.5", "true", "null", "\"6\""] {
            try require(parse("{\"expires_at\":1008,\"left\":6,\"right\":\(phase)}").isEmpty, "Partially invalid override was accepted: \(phase)")
        }
        for json in ["{", "[]", "true", "{}", "{\"left\":6}", "{\"expires_at\":1008,\"middle\":6}"] {
            try require(parse(json).isEmpty, "Invalid document accepted: \(json)")
        }
        let active = "{\"expires_at\":1008,\"left\":6}"
        try require(parse(active, now: .nan).isEmpty && parse(active, now: .infinity).isEmpty, "Invalid host time accepted")
        try require(parse(active, now: 1008).isEmpty, "Expired override was retained")
        try require(SenseLEDDiagnostic.phases(data: Data(repeating: 32, count: 1025), now: 1000).isEmpty, "Oversized control accepted")
        print("PASS: independent left/right LED phases, valid 1/5/6 only, finite ten-second expiry, deletion/expiry restoration and fail-closed malformed controls; no HID writes")
    }
}
