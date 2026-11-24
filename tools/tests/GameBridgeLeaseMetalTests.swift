import Foundation
import Metal
import Darwin
import CHallidayCore

private final class ReleaseCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func released() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@main struct GameBridgeLeaseMetalTests {
    static func main() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let gate = device.makeSharedEvent() else { fatalError("No Metal device/queue/event") }
        let released = ReleaseCount()
        let done = DispatchSemaphore(value: 0)
        autoreleasepool {
            let size = Int(getpagesize())
            var allocation: UnsafeMutableRawPointer?
            precondition(posix_memalign(&allocation, size, size) == 0)
            let memory = allocation!
            memset(memory, 0x5A, size)
            var host: GameBridgeLease? = GameBridgeLease(pointer: OpaquePointer(memory), release: { pointer in
                free(UnsafeMutableRawPointer(pointer)); released.released()
            })
            guard let source = device.makeBuffer(bytesNoCopy: memory, length: size, options: .storageModeShared, deallocator: nil),
                  let target = device.makeBuffer(length: size, options: .storageModeShared),
                  let cb = queue.makeCommandBuffer() else { fatalError("Could not allocate copy fixture") }
            cb.encodeWaitForEvent(gate, value: 1)
            guard let blit = cb.makeBlitCommandEncoder() else { fatalError("Could not make copy encoder") }
            blit.copy(from: source, sourceOffset: 0, to: target, destinationOffset: 0, size: size)
            blit.endEncoding()
            cb.addCompletedHandler { [lease = host!] command in
                precondition(command.status == .completed)
                precondition(UnsafeMutableRawPointer(lease.pointer).load(as: UInt8.self) == 0x5A)
                done.signal()
            }
            cb.commit()
            host = nil
            precondition(released.count == 0, "Host close freed a mapping still owned by its GPU copy")
            gate.signaledValue = 1
            precondition(done.wait(timeout: .now() + 10) == .success, "GPU copy timed out")
            cb.waitUntilCompleted()
            let bytes = target.contents().assumingMemoryBound(to: UInt8.self)
            precondition((0..<size).allSatisfy { bytes[$0] == 0x5A }, "Copied pixels changed after host detach")
        }
        precondition(released.count == 1, "Mapping was not released exactly once after GPU completion")
        print("PASS: real Metal copy delayed behind a GPU event, host detach before execution, exact page bytes and one final mapping release")
        retiredHostCopy(device: device, queue: queue)
    }

    /// Real bridge publication retires before a deliberately pending GPU copy,
    /// while delayed final unmap must not remove a replacement host's path.
    static func retiredHostCopy(device: MTLDevice, queue: MTLCommandQueue) {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("halliday-retire-metal-\(UUID().uuidString).shm")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: path.deletingLastPathComponent().appendingPathComponent("." + path.lastPathComponent + ".lock"))
        }
        var config = HallidayBridgeConfig(eye_width: 8, eye_height: 8, display_hz: 72, ipd: 0.064,
            tangents: ((-1,1,1,-1),(-1,1,1,-1)))
        let released = ReleaseCount(), done = DispatchSemaphore(value: 0)
        var replacement: OpaquePointer?
        defer { halliday_bridge_close(replacement) }
        autoreleasepool {
            guard let pointer = halliday_bridge_open(path.path, &config), let base = halliday_bridge_base(pointer),
                  let gate = device.makeSharedEvent(), let cb = queue.makeCommandBuffer() else { fatalError("Bridge/event allocation") }
            let page = Int(getpagesize()), sourceOffset = 65536
            memset(base.advanced(by: sourceOffset), 0xA6, page)
            var host: GameBridgeLease? = GameBridgeLease(pointer: pointer, release: { p in halliday_bridge_close(p); released.released() })
            guard let source = device.makeBuffer(bytesNoCopy: base, length: Int(halliday_bridge_file_size()),
                options: .storageModeShared, deallocator: nil), let target = device.makeBuffer(length: page, options: .storageModeShared)
            else { fatalError("Bridge copy allocation") }
            cb.encodeWaitForEvent(gate, value: 1)
            guard let blit = cb.makeBlitCommandEncoder() else { fatalError("Bridge copy encoder") }
            blit.copy(from: source, sourceOffset: sourceOffset, to: target, destinationOffset: 0, size: page); blit.endEncoding()
            cb.addCompletedHandler { [lease = host!] command in
                precondition(command.status == .completed)
                precondition(halliday_bridge_base(lease.pointer) != nil)
                done.signal()
            }
            cb.commit()
            halliday_bridge_retire(pointer)
            host = nil
            let retiredBeforeCopy = !FileManager.default.fileExists(atPath: path.path) && released.count == 0
            replacement = halliday_bridge_open(path.path, &config)
            // Always release the event before checking retirement assertions.
            gate.signaledValue = 1
            precondition(done.wait(timeout: .now() + 10) == .success, "Retired-host copy timed out")
            cb.waitUntilCompleted()
            precondition(retiredBeforeCopy, "Retirement was deferred until GPU completion")
            precondition(replacement != nil, "Replacement host could not publish")
            let bytes = target.contents().assumingMemoryBound(to: UInt8.self)
            precondition((0..<page).allSatisfy { bytes[$0] == 0xA6 }, "Retirement invalidated pending GPU pixels")
        }
        precondition(released.count == 1, "Old mapping must release once after GPU completion")
        precondition(FileManager.default.fileExists(atPath: path.path), "Late old-map cleanup deleted the replacement")
        print("PASS: real bridge retires/unlinks before blocked GPU copy; pixels remain valid; one delayed unmap preserves replacement host")
    }
}
