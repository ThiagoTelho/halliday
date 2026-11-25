@main struct GameProducerStateTests {
    static func main() {
        var state = GameProducerState()
        precondition(!state.observe(ready: false, pid: 0, epoch: 0, frames: 0))
        precondition(state.observe(ready: true, pid: 42, epoch: 100, frames: 0))
        let first = state.revision
        precondition(!state.observe(ready: true, pid: 42, epoch: 100, frames: 900))
        precondition(state.accepts(first))

        // No disconnected tick, no process change. A recreated XR session starts
        // frame indices at one and must retire a capture from the previous one.
        precondition(state.observe(ready: true, pid: 42, epoch: 101, frames: 0))
        precondition(!state.accepts(first))
        let next = state.revision
        precondition(!state.observe(ready: true, pid: 42, epoch: 101, frames: 1))
        precondition(state.accepts(next))
        precondition(state.observe(ready: false, pid: 42, epoch: 0, frames: 1))
        precondition(!state.accepts(next))
        let stopped = state.revision
        precondition(!state.observe(ready: false, pid: 42, epoch: 0, frames: 1))
        precondition(state.accepts(stopped))

        // Legacy producers remain stable without the optional epoch extension.
        precondition(state.observe(ready: true, pid: 43, epoch: 0, frames: 8))
        let legacy = state.revision
        precondition(!state.observe(ready: true, pid: 43, epoch: 0, frames: 9))
        precondition(state.accepts(legacy))
        precondition(state.observe(ready: true, pid: 44, epoch: 0, frames: 10))
        precondition(!state.accepts(legacy))
        precondition(state.observe(ready: true, pid: 44, epoch: 0, frames: 0))
        let reset = state.revision
        precondition(!state.observe(ready: true, pid: 44, epoch: 0, frames: 1))
        precondition(state.accepts(reset))

        // Registration may expose an epoch-zero transitional observation before
        // publishing its optional control extension. Treat that handoff safely.
        precondition(state.observe(ready: true, pid: 44, epoch: 102, frames: 0))
        let pending = state.revision
        state.invalidateCallbacks()
        precondition(!state.accepts(pending))
        precondition(!state.observe(ready: true, pid: 44, epoch: 102, frames: 0))
        print("PASS: same-PID session recreation, frame-counter reset, first frame, disconnect, legacy producer, backend retirement and stale callback tokens")
    }
}
