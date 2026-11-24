@main struct GameProducerWatchdogTests {
    typealias Sample = GameProducerWatchdog.Sample

    static func sample(status: UInt32 = 1, pid: UInt32 = 42, epoch: UInt64 = 100,
                       heartbeat: UInt64 = 1, frames: UInt64 = 0, calls: UInt64 = 0) -> Sample {
        Sample(status: status, pid: pid, epoch: epoch, heartbeat: heartbeat, frames: frames, calls: calls)
    }

    static func run(_ watchdog: inout GameProducerWatchdog, sample: Sample,
                    from start: Double, through end: Double) -> Int {
        var requests = 0
        let ticks = Int(((end - start) * 10).rounded())
        for tick in 0...ticks {
            if watchdog.observe(sample, at: start + Double(tick) / 10) { requests += 1 }
        }
        return requests
    }

    static func main() {
        let stopped = sample()
        var watchdog = GameProducerWatchdog()
        precondition(run(&watchdog, sample: stopped, from: 0, through: 4.9) == 0)
        precondition(watchdog.observe(stopped, at: 5))
        precondition(watchdog.confirm(stopped, at: 5.01))
        precondition(!watchdog.observe(stopped, at: 5.1), "request must be queued once")

        // A loading game need not submit images or call XR: the runtime's
        // independent heartbeat keeps its valid session for arbitrarily long.
        watchdog.reset()
        for tick in 0...200 {
            precondition(!watchdog.observe(sample(heartbeat: UInt64(tick / 2 + 1)), at: Double(tick) / 10))
        }
        for activity in [sample(frames: 1), sample(calls: 1), sample(heartbeat: 2),
                         sample(pid: 43), sample(epoch: 101), sample(status: UInt32.max)] {
            watchdog.reset()
            precondition(run(&watchdog, sample: stopped, from: 0, through: 4.9) == 0)
            precondition(!watchdog.observe(activity, at: 5), "activity/identity/status grants a fresh grace")
            precondition(run(&watchdog, sample: activity, from: 5.1, through: 9.9) == 0)
            precondition(watchdog.observe(activity, at: 10))
        }

        // Host/OS suspension cannot be counted as observed producer silence.
        watchdog.reset()
        precondition(run(&watchdog, sample: stopped, from: 0, through: 4.9) == 0)
        precondition(!watchdog.observe(stopped, at: 60))
        precondition(run(&watchdog, sample: stopped, from: 60.1, through: 64.9) == 0)
        precondition(watchdog.observe(stopped, at: 65))
        precondition(!watchdog.confirm(stopped, at: 66), "late callback must not retire a resumed producer")

        // A queued callback may run after another session claimed the route,
        // including the same OS PID with a new session epoch.
        for changed in [sample(epoch: 101), sample(pid: 43), sample(heartbeat: 2),
                        sample(frames: 1), sample(calls: 1), sample(status: 0)] {
            watchdog.reset()
            precondition(run(&watchdog, sample: stopped, from: 0, through: 5) == 1)
            precondition(!watchdog.confirm(changed, at: 5.01))
            precondition(!watchdog.observe(changed, at: 5.02))
        }
        watchdog.reset()
        let initializing = sample(status: UInt32.max, pid: 0, epoch: 0, heartbeat: 0)
        precondition(run(&watchdog, sample: initializing, from: 0, through: 5) == 1)
        precondition(watchdog.confirm(initializing, at: 5.01))
        watchdog.reset()
        precondition(!watchdog.observe(sample(status: 0), at: 100))
        precondition(!watchdog.observe(stopped, at: 101))
        precondition(!watchdog.observe(stopped, at: .nan))
        precondition(!watchdog.observe(stopped, at: 101.1))
        precondition(!watchdog.observe(stopped, at: 100), "clock reversal grants a fresh grace")
        print("PASS: stale/initializing lease, live loading heartbeat, activity/PID/epoch changes, host suspension, queued callback revalidation and one recovery request")
    }
}
