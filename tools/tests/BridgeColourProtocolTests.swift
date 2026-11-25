import Foundation
import CHallidayCore

@_silgen_name("halliday_colour_fixture_publish")
private func fixturePublish(_ mapping: UnsafeMutableRawPointer, _ metadata: UInt32, _ index: UInt64) -> Bool

@main
struct BridgeColourProtocolTests {
    static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    static func run() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-colour-\(UUID().uuidString).shm")
        var config = HallidayBridgeConfig()
        config.eye_width = 4; config.eye_height = 2; config.display_hz = 72; config.ipd = 0.064
        guard let bridge = path.path.withCString({ halliday_bridge_open($0, &config) }),
              let base = halliday_bridge_base(bridge) else { throw Failure("Could not open private bridge fixture") }
        defer { halliday_bridge_close(bridge) }
        func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message) } }
        try require(MemoryLayout<HallidayBridgeFrame>.size == 144, "Existing native frame ABI changed")
        try require(halliday_bridge_frame_color_space(nil, 0, 0) == 0, "Null bridge must preserve legacy handling")
        let metadata: UInt32 = 4 | (1 << 8) | (2 << 10)
        try require(fixturePublish(UnsafeMutableRawPointer(base),metadata,1), "C++ publication failed")
        var frame = HallidayBridgeFrame()
        try require(halliday_bridge_begin_read(bridge,&frame), "Rust reader did not claim C++ frame")
        try require(frame.width == 4 && frame.height == 2 && frame.frame_index == 1,
                    "C++ frame metadata did not survive native C ABI")
        try require(halliday_bridge_frame_color_space(bridge,frame.slot,0) == 1 &&
                    halliday_bridge_frame_color_space(bridge,frame.slot,1) == 2,
                    "Distinct per-eye transfer flags were lost between C++ and Swift")
        try require(halliday_bridge_frame_color_space(bridge,99,0) == 0 &&
                    halliday_bridge_frame_color_space(bridge,frame.slot,99) == 0,"Invalid slots/eyes must be safe")
        halliday_bridge_end_read(bridge)
        try require(halliday_bridge_frame_color_space(bridge,frame.slot,0) == 0,
                    "Metadata was readable without owning the frame")
        try require(fixturePublish(UnsafeMutableRawPointer(base),1,2), "Legacy publication failed")
        try require(halliday_bridge_begin_read(bridge,&frame), "Legacy frame was not readable")
        try require(halliday_bridge_frame_color_space(bridge,frame.slot,0) == 0 &&
                    halliday_bridge_frame_color_space(bridge,frame.slot,1) == 0,"Old OpenVR producers changed meaning")
        halliday_bridge_end_read(bridge)
        print("PASS: real C++ producer -> v6 mapped bridge -> Rust reader -> native C ABI -> Swift per-eye colour tags, legacy compatibility and frame ownership")
    }

    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
