/// Keeps a mapped bridge alive until submitted GPU copies and capture setup have
/// finished, even after the host detaches it. The mapping is thread-safe; the
/// last pending operation releases it without blocking the display actor.
final class GameBridgeLease: @unchecked Sendable {
    let pointer: OpaquePointer
    private let release: @Sendable (OpaquePointer) -> Void

    init(pointer: OpaquePointer, release: @escaping @Sendable (OpaquePointer) -> Void) {
        self.pointer = pointer
        self.release = release
    }
    deinit { release(pointer) }
}
