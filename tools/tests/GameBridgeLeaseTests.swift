import Foundation

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0
    func released() { lock.withLock { releases += 1 } }
    var count: Int { lock.withLock { releases } }
}

@main struct GameBridgeLeaseTests {
    private static func completion(_ lease: GameBridgeLease, recorder: Recorder) -> @Sendable () -> Void {
        { [lease] in
            precondition(recorder.count == 0, "Bridge freed before pending copy completed")
            let bytes = UnsafeMutableRawPointer(lease.pointer).assumingMemoryBound(to: UInt64.self)
            precondition(bytes.pointee == 0x1234_ABCD)
            bytes.pointee = 0x5678_EFAB
        }
    }

    static func main() {
        let recorder = Recorder()
        let bytes = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        bytes.initialize(to: 0x1234_ABCD)
        var host: GameBridgeLease? = GameBridgeLease(pointer: OpaquePointer(bytes), release: { pointer in
            let bytes = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: UInt64.self)
            precondition(bytes.pointee == 0x5678_EFAB)
            bytes.deinitialize(count: 1)
            bytes.deallocate()
            recorder.released()
        })
        weak var weakLease = host
        var pending: (@Sendable () -> Void)? = completion(host!, recorder: recorder)
        host = nil // GameBridge.close detaches immediately without a GPU wait.
        precondition(weakLease != nil && recorder.count == 0)
        pending!()
        pending = nil
        precondition(weakLease == nil && recorder.count == 1)

        // Cancellation drops an unstarted operation and releases exactly once.
        let cancelled = Recorder()
        var lease: GameBridgeLease? = GameBridgeLease(pointer: OpaquePointer(bitPattern: 1)!, release: { _ in cancelled.released() })
        var queued: GameBridgeLease? = lease
        lease = nil
        precondition(cancelled.count == 0 && queued != nil)
        queued = nil
        precondition(cancelled.count == 1)
        print("PASS: detached bridge remains usable through pending work, releases once after completion, cancelled setup releases without blocking")
    }
}
