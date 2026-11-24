import Foundation
import CHallidayCore

/// A serial optical solver with one replaceable pending exposure. No headset/HID methods run
/// here; callers submit immutable camera/pose snapshots and apply results on their own actor.
final class HandTrackingWorker: @unchecked Sendable {
    struct Spot: Sendable {
        let x: Float, y: Float
        let area: UInt32, peak: UInt32
    }
    struct HandOrientation: Sendable {
        /// The core's order: zero is left, one is right.
        let index: Int
        let orientation: SIMD4<Float>
    }
    struct Frame: Sendable {
        let counter: Int
        let exposureHostNs: Int64
        let headOrientation: SIMD4<Float>
        let headPosition: SIMD3<Float>
        let heightLift: Float
        let handOrientations: [HandOrientation]
        /// Bottom left/right first, then optional top left/right, as in halliday_hand_update.
        let views: [[Spot]]
        let fisheyes: Bool
        /// Right tracking-camera-local rotation vector, radians; identity without a profile.
        var fisheyeAlignment: SIMD3<Float> = .zero
        /// Coherent head-tracker discontinuity token; zero is legacy/unknown.
        var trackingGeneration: UInt64 = 0
    }
    struct Fix: Sendable {
        let index: Int
        /// The same head-relative position returned by halliday_hand_update.
        let position: SIMD3<Float>
        let heading: Float
        let tilt: SIMD2<Float>
        let sightings: UInt32
        let rms: Float
    }
    struct Output: Sendable {
        let frame: Frame
        let fixes: [Fix]
        let generation: UInt64
    }
    /// Test injection. Hooks execute only on the serial worker queue, including cleanup.
    struct Solver: Sendable {
        let solve: @Sendable (Frame) -> [Fix]
        let reset: @Sendable () -> Void
        let close: @Sendable () -> Void
    }

    private struct Geometry: Equatable {
        let fisheyes: Bool
        let alignment: SIMD3<Float>
        var trackingGeneration: UInt64
        init?(_ frame: Frame) {
            let a = frame.fisheyes ? frame.fisheyeAlignment : .zero
            let limit = Float.pi / 36 // Same five-degree safety domain as the Core setter.
            guard a.x.isFinite, a.y.isFinite, a.z.isFinite,
                  a.x * a.x + a.y * a.y + a.z * a.z <= limit * limit else { return nil }
            fisheyes = frame.fisheyes
            alignment = a
            trackingGeneration = frame.trackingGeneration
        }
        mutating func retainKnownGeneration(from old: Geometry?) {
            if trackingGeneration == 0 { trackingGeneration = old?.trackingGeneration ?? 0 }
        }
        func changes(from old: Geometry) -> Bool {
            fisheyes != old.fisheyes || alignment != old.alignment ||
                (trackingGeneration != 0 && old.trackingGeneration != 0 &&
                 trackingGeneration != old.trackingGeneration)
        }
    }

    private let core: Core
    init(solver: Solver? = nil, onOutput: @escaping @Sendable (Output) -> Void) {
        core = Core(solver: solver, onOutput: onOutput)
    }
    deinit { core.close() }

    func submit(_ frame: Frame) { core.submit(frame) }
    /// Cancels pending work and invalidates outstanding results; cleanup is asynchronous.
    func reset() { core.reset() }
    /// Permanently closes submission. Does not wait for a running solve or queue cleanup.
    func close() { core.close() }
    /// Recheck after hopping to another actor: reset may happen while that callback is queued.
    func isCurrent(_ output: Output) -> Bool { core.isCurrent(output.generation) }

    /// Scheduled drains retain this lifetime owner, not the public wrapper. Dropping the wrapper
    /// can therefore enqueue cleanup without resurrecting an object during its deinitialization.
    private final class Core: @unchecked Sendable {
        private struct Request { let frame: Frame; let generation: UInt64 }
        private let lock = NSLock()
        private let queue: DispatchQueue
        private let solver: Solver
        private let onOutput: @Sendable (Output) -> Void
        // All fields below are accessed under lock, except solverGeneration (queue only).
        private var pending: Request?
        private var generation: UInt64 = 0
        private var scheduled = false
        private var closed = false
        private var solverGeneration: UInt64 = 0
        private var geometry: Geometry?

        init(solver: Solver?, onOutput: @escaping @Sendable (Output) -> Void) {
            let queue = DispatchQueue(label: "halliday.hands.optical", qos: .userInitiated)
            self.queue = queue
            self.onOutput = onOutput
            if let solver { self.solver = solver }
            else {
                let native = NativeSolver(queue: queue)
                self.solver = Solver(solve: { native.solve($0) }, reset: { native.reset() }, close: { native.reset() })
            }
        }

        func submit(_ frame: Frame) {
            guard var nextGeometry = Geometry(frame) else { reset(); return }
            lock.lock()
            guard !closed else { lock.unlock(); return }
            // Geometry belongs to a result's generation, even before solving.
            // A completed old result queued on another actor must also expire.
            nextGeometry.retainKnownGeneration(from: geometry)
            if let geometry, nextGeometry.changes(from: geometry) { generation &+= 1 }
            geometry = nextGeometry
            pending = Request(frame: frame, generation: generation)
            let start = !scheduled
            scheduled = true
            lock.unlock()
            if start { queue.async { self.drain() } }
        }
        func reset() {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            generation &+= 1
            pending = nil
            geometry = nil
            let start = !scheduled
            scheduled = true
            lock.unlock()
            if start { queue.async { self.drain() } }
        }
        func close() {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            closed = true
            generation &+= 1
            pending = nil
            let start = !scheduled
            scheduled = true
            lock.unlock()
            if start { queue.async { self.drain() } }
        }
        func isCurrent(_ value: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !closed && value == generation
        }
        private func drain() {
            dispatchPrecondition(condition: .onQueue(queue))
            while true {
                lock.lock()
                let ending = closed
                let currentGeneration = generation
                let request = pending
                pending = nil
                if ending || request == nil { scheduled = false }
                lock.unlock()
                if ending { solver.close(); return }
                if solverGeneration != currentGeneration {
                    solver.reset()
                    solverGeneration = currentGeneration
                }
                guard let request else { return }
                let fixes = solver.solve(request.frame)
                if isCurrent(request.generation) {
                    onOutput(Output(frame: request.frame, fixes: fixes, generation: request.generation))
                }
            }
        }
    }

    /// Handles and their temporal state never leave the worker queue.
    private final class NativeSolver: @unchecked Sendable {
        private let queue: DispatchQueue
        private var handle: OpaquePointer?
        private var geometry: Geometry?
        init(queue: DispatchQueue) { self.queue = queue }
        func reset() {
            dispatchPrecondition(condition: .onQueue(queue))
            if let handle { halliday_hand_pair_close(handle) }
            handle = nil
            geometry = nil
        }
        func solve(_ frame: Frame) -> [Fix] {
            dispatchPrecondition(condition: .onQueue(queue))
            guard frame.views.count >= 2, frame.exposureHostNs > 0 else { return [] }
            guard var nextGeometry = Geometry(frame) else { reset(); return [] }
            nextGeometry.retainKnownGeneration(from: geometry)
            if let geometry, nextGeometry.changes(from: geometry) { reset() }
            // One paired solve owns both temporal tracks and blob assignments.
            // A bad profile cannot leave one hand on a different geometry.
            if handle == nil {
                guard let opened = halliday_hand_pair_open() else { reset(); return [] }
                handle = opened
                halliday_hand_pair_set_fisheyes(opened, nextGeometry.fisheyes)
                let a = nextGeometry.alignment
                guard halliday_hand_pair_set_fisheye_alignment(opened, [a.x, a.y, a.z]) else { reset(); return [] }
            }
            guard let handle else { return [] }
            geometry = nextGeometry
            let views = (0..<4).map { i in
                (frame.views.indices.contains(i) ? frame.views[i] : []).map {
                    HallidayCameraSpot(x: $0.x, y: $0.y, area: $0.area, peak: $0.peak)
                }
            }
            let h = frame.headOrientation
            let head = [h.x, h.y, h.z, h.w]
            var controllers = [Float](repeating: 0, count: 8)
            var controllerMask: UInt32 = 0
            var visited: Set<Int> = []
            for hand in frame.handOrientations where (0...1).contains(hand.index) && visited.insert(hand.index).inserted {
                let q = hand.orientation
                for (axis, value) in [q.x, q.y, q.z, q.w].enumerated() { controllers[hand.index * 4 + axis] = value }
                controllerMask |= UInt32(1) << UInt32(hand.index)
            }
            let p = frame.headPosition
            var nativeFixes = [HallidayHandFix(), HallidayHandFix()]
            let accepted = halliday_hand_pair_update(handle, UInt64(frame.exposureHostNs), head,
                [p.x, p.y, p.z], controllers, controllerMask,
                views[0], UInt32(views[0].count), views[1], UInt32(views[1].count),
                views[2], UInt32(views[2].count), views[3], UInt32(views[3].count), &nativeFixes)
            return (0..<2).compactMap { hand in
                guard accepted & (UInt32(1) << UInt32(hand)) != 0 else { return nil }
                let fix = nativeFixes[hand]
                return Fix(index: hand, position: SIMD3(fix.position.0, fix.position.1, fix.position.2),
                    heading: fix.heading, tilt: SIMD2(fix.tilt.0, fix.tilt.1), sightings: fix.sightings, rms: fix.rms)
            }
        }
    }
}
