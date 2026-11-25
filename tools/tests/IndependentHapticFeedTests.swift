import Foundation
import CHallidayCore
@_silgen_name("fixture_haptic_claim") private func claim(_ base: UnsafeMutableRawPointer, _ epoch: UInt64) -> UInt64
@_silgen_name("fixture_haptic_send") private func send(_ base: UnsafeMutableRawPointer, _ epoch: UInt64, _ hand: UInt32, _ duration: UInt64, _ frequency: Float, _ amplitude: Float) -> Bool
@_silgen_name("fixture_haptic_end") private func end(_ base: UnsafeMutableRawPointer, _ epoch: UInt64)

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GameHapticEvent] = []
    func append(_ event: GameHapticEvent) { lock.lock(); values.append(event); lock.unlock() }
    func snapshot() -> [GameHapticEvent] { lock.lock(); defer { lock.unlock() }; return values }
}
@main struct IndependentHapticFeedTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    static func wait(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        check(condition(), message)
    }
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-independent-haptic-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("bridge.shm")
        var config = HallidayBridgeConfig(); config.eye_width = 8; config.eye_height = 8; config.display_hz = 72; config.ipd = 0.064
        guard let host = path.path.withCString({ halliday_bridge_open($0, &config) }), let bytes = halliday_bridge_base(host) else { fatalError("fixture host") }
        defer { halliday_bridge_close(host) }
        let base = UnsafeMutableRawPointer(bytes), sink = Sink()
        check(claim(base, 31) == 31, "C++ could not claim Rust host extension")
        guard let feed = GameHapticFeed(bridgePath: path, connected: { 3 }, output: { sink.append($0) }) else { fatalError("fixture feed") }
        defer { feed.close() }
        check(send(base, 31, 0, 30_000_000, 160, 0.7), "left command")
        check(send(base, 31, 1, 30_000_000, 60, 0.4), "right command")
        wait("C++→Rust→Swift lost stereo haptics") { Set(sink.snapshot().filter { !$0.stop }.map(\.hand)) == [0, 1] }
        wait("finite vibration did not stop") { Set(sink.snapshot().filter(\.stop).map(\.hand)) == [0, 1] }
        feed.setFocused(false)
        let pause = sink.snapshot().count
        check(send(base, 31, 0, 50_000_000, 0, 1), "paused producer")
        Thread.sleep(forTimeInterval: 0.012)
        feed.setFocused(true)
        Thread.sleep(forTimeInterval: 0.012)
        check(sink.snapshot().dropFirst(pause).allSatisfy(\.stop), "paused request replayed")
        check(send(base, 31, 0, 100_000_000, 120, 0.6), "resumed producer")
        wait("fresh resumed command missing") { sink.snapshot().dropFirst(pause).contains { !$0.stop } }
        end(base, 31)
        let ended = sink.snapshot().count
        wait("ended session did not stop") { sink.snapshot().dropFirst(ended).contains( where: \.stop) }
        check(claim(base, 32) == 32, "recreated session")
        let fresh = sink.snapshot().count
        check(send(base, 32, 1, 30_000_000, 0, 0.5), "fresh session producer")
        wait("fresh session suppressed") { sink.snapshot().dropFirst(fresh).contains { !$0.stop && $0.hand == 1 } }
        feed.close()
        let closed = sink.snapshot().count
        _ = send(base, 32, 0, 100_000_000, 0, 1)
        Thread.sleep(forTimeInterval: 0.02)
        check(sink.snapshot().count == closed, "output after close")
        print("PASS: independent C++→Rust→Swift stereo haptics, expiry, focus suppression, session recreation and close")
    }
}
