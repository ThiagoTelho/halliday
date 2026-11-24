/// Identifies a public bridge producer independently of its process lifetime.
/// OpenXR can end and create a session in the same process between display ticks.
struct GameProducerState {
    private struct Identity: Equatable {
        let pid: UInt32
        let epoch: UInt64
    }

    private var identity: Identity?
    private var frames: UInt64 = 0
    private(set) var revision: UInt64 = 0

    /// Legacy OpenVR clients have epoch zero: preserve their PID/ready behavior,
    /// and also notice an explicitly reset frame counter.
    mutating func observe(ready: Bool, pid: UInt32, epoch: UInt64, frames: UInt64) -> Bool {
        let next = ready ? Identity(pid: pid, epoch: epoch) : nil
        let changed = next != identity || (next != nil && frames < self.frames)
        identity = next
        self.frames = frames
        if changed { invalidateCallbacks() }
        return changed
    }

    /// A stopped presentation or a switch to the other backend also retires work.
    mutating func invalidateCallbacks() { revision &+= 1 }
    func accepts(_ revision: UInt64) -> Bool { self.revision == revision }
}
