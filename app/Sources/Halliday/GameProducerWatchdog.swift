/// A producer lease expires only after continuous, normally ticking host
/// observation without any producer activity. No native/Wine PID lookup is used.
struct GameProducerWatchdog {
    struct Sample: Equatable {
        let status: UInt32
        let pid: UInt32
        let epoch: UInt64
        let heartbeat: UInt64
        let frames: UInt64
        let calls: UInt64
    }

    static let timeout = 5.0
    static let maximumHostGap = 0.5
    private var previous: Sample?
    private var lastTick: Double?
    private var unchangedSince = 0.0
    private var requested: Sample?

    mutating func reset() { self = Self() }

    /// True once per expired lease. An initializing producer has status
    /// UInt32.max, so a crash before readiness can be recovered as well.
    mutating func observe(_ sample: Sample?, at now: Double) -> Bool {
        guard now.isFinite, let sample, sample.status != 0 else {
            reset()
            return false
        }
        let continuous = lastTick.map { now >= $0 && now - $0 <= Self.maximumHostGap } ?? false
        if !continuous || previous != sample {
            unchangedSince = now
            requested = nil
        }
        previous = sample
        lastTick = now
        guard requested == nil, now - unchangedSince >= Self.timeout else { return false }
        requested = sample
        return true
    }

    /// Revalidate immediately before queued host recreation. A resumed/new
    /// producer, or a delayed host callback, receives an entirely fresh grace.
    mutating func confirm(_ sample: Sample?, at now: Double) -> Bool {
        guard let requested, sample == requested, now.isFinite,
              let lastTick, now >= lastTick, now - lastTick <= Self.maximumHostGap else {
            reset()
            return false
        }
        return true
    }
}
