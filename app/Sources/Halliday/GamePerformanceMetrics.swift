import Foundation

/// Optional, bounded software telemetry. The game counter measures completed
/// producer publications; it is independent of compositor repeats and framegen.
/// Metal callbacks may arrive on another thread, so every record is serialized.
final class GamePerformanceMetrics: @unchecked Sendable {
    struct Producer: Sendable, Equatable {
        let pid: UInt32
        let epoch: UInt64
        let revision: UInt64
    }
    struct PresentationContext: Sendable, Equatable {
        fileprivate let generation: UInt64
    }
    private struct Counter { let time: Double; let frames: UInt64 }
    private struct PoseStamp { let stamp: UInt32; let published: Double }
    private struct Image {
        let acquired: Double
        let posePublished: Double?
        var firstNativePresent: Double?
    }
    private struct Latency { let sequence: UInt64; let time: Double; let milliseconds: Double }
    private let lock = NSLock()
    private var enabled = false
    private var sourceActive = false
    private var generation: UInt64 = 1
    private var producer: Producer?
    private var counters: [Counter] = []
    private var lastAdvance: Double?
    private var clockAnchor: Double?
    private var poses: [PoseStamp?] = []
    private var images: [UInt64: Image] = [:]
    private var imageOrder: [UInt64] = []
    // GameBridge's source image identity is process-monotonic. Never allow an
    // old identity to be rebound after a producer/paused-state reset.
    private var highestImageSequence: UInt64 = 0
    private var presentedTimes: [Double] = []
    private var presentationEpoch: UInt64?
    private var latestPresented: Double?
    private var latencies: [Latency] = []
    private var history: [PerformanceHUDSample] = []
    private var cached = PerformanceHUDSnapshot.empty
    private var lastSnapshotAt: Double?

    static let historySeconds = 10.0
    static let sampleInterval = 0.2
    private static let averagingSeconds = 1.0
    private static let staleSeconds = 0.5 // Same source lifetime as GameBridge.framesArriving.
    private static let maximumImages = 256
    private static let maximumEvents = 512
    private static let poseSlots = 4096
    private static let maximumHistory = 51

    private func clearLocked() {
        counters.removeAll(keepingCapacity: true); lastAdvance = nil
        for i in poses.indices { poses[i] = nil }
        images.removeAll(keepingCapacity: true); imageOrder.removeAll(keepingCapacity: true)
        presentedTimes.removeAll(keepingCapacity: true); latencies.removeAll(keepingCapacity: true)
        history.removeAll(keepingCapacity: true); presentationEpoch = nil; latestPresented = nil
        cached = .empty; lastSnapshotAt = nil
        if generation < UInt64.max { generation += 1 }
        else { enabled = false } // No context-token reuse on theoretical wrap.
    }
    func setEnabled(_ value: Bool, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        guard value != enabled else { return }
        enabled = value; sourceActive = false; producer = nil; clearLocked()
        clockAnchor = validTime(now) ? now : nil
    }
    func sourceInactive(at now: Double) {
        lock.lock(); defer { lock.unlock() }
        if sourceActive || producer != nil { sourceActive = false; producer = nil; clearLocked() }
        if validTime(now) { clockAnchor = now }
    }
    private func validTime(_ t: Double) -> Bool { t.isFinite && t > 0 }

    /// Read only a stable, ready producer snapshot. `active=false` means pause,
    /// dashboard, stale/loading or no current projection; actual display feedback
    /// may still be collected under the new context while the HUD is visible.
    func observeProducer(_ identity: Producer, frames: UInt64, at now: Double, active: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        guard validTime(now) else { sourceActive = false; producer = nil; clearLocked(); return }
        clockAnchor = now
        guard active, identity.pid > 0 else {
            if sourceActive || producer != nil { sourceActive = false; producer = nil; clearLocked() }
            return
        }
        let previous = counters.last
        let discontinuity = producer != identity || !sourceActive || previous.map { frames < $0.frames || now < $0.time || now - $0.time > Self.staleSeconds } == true
        if discontinuity {
            clearLocked(); sourceActive = true; producer = identity
            counters.append(Counter(time: now, frames: frames)); lastAdvance = frames > 0 ? now : nil
            return
        }
        if let previous, now == previous.time { return }
        if let previous, frames > previous.frames { lastAdvance = now }
        counters.append(Counter(time: now, frames: frames))
        // Retain one observation before the one-second boundary, so counter
        // coalescing does not turn a missed consumer tick into a missed frame.
        while counters.count > 2 && counters[1].time < now - Self.averagingSeconds { counters.removeFirst() }
        if counters.count > Self.maximumEvents { counters.removeFirst(counters.count - Self.maximumEvents) }
    }

    func posePublished(stamp: UInt32, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, sourceActive, stamp > 0, stamp <= 0x00ff_ffff, validTime(now) else { return }
        if poses.isEmpty { poses = Array(repeating: nil, count: Self.poseSlots) }
        poses[Int(stamp) % Self.poseSlots] = PoseStamp(stamp: stamp, published: now)
    }
    func receivedImage(sequence: UInt64, poseStamp: Float, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, sourceActive, sequence > highestImageSequence, validTime(now) else { return }
        highestImageSequence = sequence
        var published: Double?
        if poseStamp.isFinite, poseStamp >= 1, poseStamp <= Float(0x00ff_ffff), poseStamp.rounded(.towardZero) == poseStamp,
           !poses.isEmpty {
            let stamp = UInt32(poseStamp)
            if let pose = poses[Int(stamp) % Self.poseSlots], pose.stamp == stamp,
               now >= pose.published, now - pose.published <= Self.averagingSeconds { published = pose.published }
        }
        images[sequence] = Image(acquired: now, posePublished: published, firstNativePresent: nil)
        imageOrder.append(sequence)
        if imageOrder.count > Self.maximumImages {
            images.removeValue(forKey: imageOrder.removeFirst())
        }
    }
    /// Capture this BEFORE asynchronous GPU/presentation work. A current-game
    /// lookup inside a callback could attach old feedback to a new producer.
    func presentationContext() -> PresentationContext? {
        lock.lock(); defer { lock.unlock() }
        return enabled ? PresentationContext(generation: generation) : nil
    }
    func presented(imageSequence: UInt64, generated: Bool, at shown: Double, epoch: UInt64,
                   context: PresentationContext) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, context.generation == generation, validTime(shown),
              let anchor = clockAnchor, abs(shown - anchor) <= Self.averagingSeconds else { return }
        // Epochs identify a presentation clock configuration, not game frames.
        // A callback from an older configuration cannot retire newer feedback.
        if presentationEpoch != epoch {
            if let latestPresented, shown <= latestPresented { return }
            presentedTimes.removeAll(keepingCapacity: true); latencies.removeAll(keepingCapacity: true)
            history.removeAll(keepingCapacity: true); cached = .empty; lastSnapshotAt = nil
            presentationEpoch = epoch
        }
        latestPresented = max(latestPresented ?? shown, shown)
        // Count actual physical outputs, including repeats/generated/menu
        // frames, but never count a duplicated callback timestamp twice.
        if !presentedTimes.contains(shown) {
            presentedTimes.append(shown); presentedTimes.sort()
            presentedTimes.removeAll { $0 < shown - Self.averagingSeconds }
            if presentedTimes.count > Self.maximumEvents { presentedTimes.removeFirst(presentedTimes.count - Self.maximumEvents) }
        }
        guard sourceActive, !generated, var image = images[imageSequence],
              shown >= image.acquired, shown - image.acquired <= Self.averagingSeconds,
              let published = image.posePublished, shown >= published,
              shown - published <= Self.averagingSeconds else { return }
        // One latency sample per native source image. If callback delivery is
        // reordered, retain its earliest ACTUAL native presentation, not the
        // first callback received. Framegen/repeats cannot bias this median.
        if let earlier = image.firstNativePresent, shown >= earlier { return }
        image.firstNativePresent = shown; images[imageSequence] = image
        latencies.removeAll { $0.sequence == imageSequence || $0.time < shown - Self.averagingSeconds }
        latencies.append(Latency(sequence: imageSequence, time: shown, milliseconds: (shown - published) * 1000))
        if latencies.count > Self.maximumImages { latencies.removeFirst(latencies.count - Self.maximumImages) }
    }

    /// Main-thread pull, safe from any thread. Repeated pulls within200ms return
    /// the same immutable small value; only this method samples the10s graph.
    func snapshot(now: Double) -> PerformanceHUDSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard enabled, validTime(now) else { return .empty }
        if let last = lastSnapshotAt, now < last {
            sourceActive = false; producer = nil; clearLocked(); clockAnchor = now; return .empty
        }
        clockAnchor = now
        if sourceActive, let advance = lastAdvance, now - advance > Self.staleSeconds {
            sourceActive = false; producer = nil; clearLocked()
        }
        if let last = lastSnapshotAt, now - last < Self.sampleInterval { return cached }
        let gameFPS: Double?
        if sourceActive, let first = counters.first, let last = counters.last,
           last.time - first.time >= Self.sampleInterval, last.frames > first.frames,
           let advance = lastAdvance, now >= advance, now - advance <= Self.staleSeconds {
            gameFPS = Double(last.frames - first.frames) / (last.time - first.time)
        } else { gameFPS = nil }
        let display = presentedTimes.filter { $0 <= now && $0 >= now - Self.averagingSeconds }
        let displayFPS: Double?
        if let first = display.first, let last = display.last, last - first >= Self.sampleInterval,
           now - last <= Self.staleSeconds { displayFPS = Double(display.count - 1) / (last - first) }
        else { displayFPS = nil }
        let latencyWindow = latencies.filter { $0.time <= now && $0.time >= now - Self.averagingSeconds }
        let poseToDisplayMs: Double?
        if sourceActive, let newest = latencyWindow.map(\.time).max(), now - newest <= Self.staleSeconds {
            let sorted = latencyWindow.map(\.milliseconds).sorted()
            let mid = sorted.count / 2
            poseToDisplayMs = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        } else { poseToDisplayMs = nil }
        if sourceActive {
            history.append(PerformanceHUDSample(time: now, gameFPS: gameFPS,
                gameFrameTimeMs: gameFPS.map { 1000 / $0 }, poseToDisplayMs: poseToDisplayMs))
            history.removeAll { $0.time < now - Self.historySeconds }
            if history.count > Self.maximumHistory { history.removeFirst(history.count - Self.maximumHistory) }
        } else { history.removeAll(keepingCapacity: true) }
        cached = PerformanceHUDSnapshot(gameFPS: gameFPS, displayFPS: displayFPS,
            poseToDisplayMs: poseToDisplayMs, history: history)
        lastSnapshotAt = now
        return cached
    }
}
