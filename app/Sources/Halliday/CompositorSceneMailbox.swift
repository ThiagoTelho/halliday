import Foundation

/// GPU-independent lifetime model. One scene writer, one drawable waiter and
/// one lens command buffer are admitted. A display request replaces an older
/// request, while scene and lens leases survive retirement until completion.
struct CompositorScenePolicy: Sendable {
    struct Write: Equatable, Sendable { let id: UInt64; let epoch: UInt64; let slot: Int }
    struct Wait: Equatable, Sendable { let id: UInt64; let epoch: UInt64 }
    struct Read: Equatable, Sendable { let id: UInt64; let epoch: UInt64; let slot: Int; let scene: UInt64 }
    private struct Slot: Sendable { var writing: UInt64?; var readers = 0; var scene: UInt64 = 0 }
    private(set) var epoch: UInt64 = 1
    private var serial: UInt64 = 0
    private var slots: [Slot]
    private var writer: Write?
    private var waiter: Wait?
    private var reader: Read?
    private var latest: (slot: Int, scene: UInt64)?
    private var request = false
    init(slots: Int = 3) { precondition(slots >= 3); self.slots = Array(repeating: Slot(), count: slots) }
    private mutating func next() -> UInt64 { serial = max(1, serial &+ 1); return serial }
    var hasWriter: Bool { writer != nil }
    var hasLatest: Bool { latest != nil }
    var activeReaders: Int { slots.reduce(0) { $0 + $1.readers } }
    var isWaiting: Bool { waiter != nil }
    var hasRequest: Bool { request }
    mutating func reserveWrite() -> Write? {
        guard writer == nil, let slot = slots.indices.first(where: {
            slots[$0].writing == nil && slots[$0].readers == 0 && latest?.slot != $0
        }) else { return nil }
        let ticket = Write(id: next(), epoch: epoch, slot: slot)
        slots[slot].writing = ticket.id; writer = ticket
        return ticket
    }
    /// Returns true only when this successful GPU result becomes the latest.
    @discardableResult mutating func finishWrite(_ ticket: Write, success: Bool) -> Bool {
        guard writer == ticket, slots[ticket.slot].writing == ticket.id else { return false }
        writer = nil; slots[ticket.slot].writing = nil
        guard success, ticket.epoch == epoch else { return false }
        slots[ticket.slot].scene = ticket.id
        latest = (ticket.slot, ticket.id)
        return true
    }
    @discardableResult mutating func offer(epoch offered: UInt64) -> Bool {
        guard offered == epoch else { return false }
        request = true; return true
    }
    mutating func beginWait() -> Wait? {
        guard request, latest != nil, waiter == nil, reader == nil else { return nil }
        let ticket = Wait(id: next(), epoch: epoch); waiter = ticket; return ticket
    }
    /// Take the newest request AND newest successfully completed scene only
    /// after nextDrawable returns. No scene lease is held while it blocks.
    mutating func takeAfterDrawable(_ wait: Wait) -> Read? {
        guard waiter == wait else { return nil }
        waiter = nil
        guard wait.epoch == epoch, request, let latest, reader == nil else { return nil }
        request = false
        let ticket = Read(id: next(), epoch: epoch, slot: latest.slot, scene: latest.scene)
        slots[ticket.slot].readers += 1; reader = ticket
        return ticket
    }
    mutating func cancelWait(_ wait: Wait) { if waiter == wait { waiter = nil } }
    mutating func finishRead(_ ticket: Read) {
        guard reader == ticket, slots[ticket.slot].scene == ticket.scene else { return }
        precondition(slots[ticket.slot].readers > 0)
        slots[ticket.slot].readers -= 1; reader = nil
    }
    mutating func retire(to newEpoch: UInt64) {
        guard newEpoch != epoch else { return }
        epoch = newEpoch; latest = nil; request = false
        // Existing GPU work / blocked drawable wait must release its OWN old
        // ticket. Clearing those credits here would permit reuse too early.
    }
}

/// Thread-safe payload mailbox; it performs no graphics, timing or user-state
/// operations. GPU command-buffer callbacks can advance it without MainActor.
final class CompositorSceneMailbox<Scene: Sendable, Request: Sendable>: @unchecked Sendable {
    struct Work: Sendable {
        let lease: CompositorScenePolicy.Read
        let scene: Scene
        let request: Request
    }
    private let lock = NSLock()
    private var policy = CompositorScenePolicy()
    private var scenes: [Int: (id: UInt64, value: Scene)] = [:]
    private var request: Request?
    var epoch: UInt64 { lock.lock(); defer { lock.unlock() }; return policy.epoch }
    func reserveWrite() -> CompositorScenePolicy.Write? {
        lock.lock(); defer { lock.unlock() }; return policy.reserveWrite()
    }
    @discardableResult func finishWrite(_ ticket: CompositorScenePolicy.Write, scene: Scene?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard policy.finishWrite(ticket, success: scene != nil), let scene else { return false }
        scenes[ticket.slot] = (ticket.id, scene); return true
    }
    @discardableResult func offer(_ value: Request, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard policy.offer(epoch: epoch) else { return false }
        request = value; return true
    }
    func peekRequest(epoch: UInt64) -> Request? {
        lock.lock(); defer { lock.unlock() }; return policy.epoch == epoch ? request : nil
    }
    func beginWait() -> CompositorScenePolicy.Wait? {
        lock.lock(); defer { lock.unlock() }; return policy.beginWait()
    }
    func takeAfterDrawable(_ wait: CompositorScenePolicy.Wait) -> Work? {
        lock.lock(); defer { lock.unlock() }
        guard let read = policy.takeAfterDrawable(wait) else { return nil }
        guard let payload = scenes[read.slot], payload.id == read.scene, let request else {
            policy.finishRead(read); return nil
        }
        self.request = nil
        return Work(lease: read, scene: payload.value, request: request)
    }
    func cancelWait(_ wait: CompositorScenePolicy.Wait) {
        lock.lock(); defer { lock.unlock() }; policy.cancelWait(wait)
    }
    func finishRead(_ ticket: CompositorScenePolicy.Read) {
        lock.lock(); defer { lock.unlock() }; policy.finishRead(ticket)
    }
    func retire(to epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        policy.retire(to: epoch); request = nil
        // Payloads are bounded by the fixed slot count; do not drop a live
        // reader's owning reference before its command buffer has completed.
    }
}
