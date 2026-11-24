@main struct ControllerPointerPolicyTests {
    static func main() {
        for physical in [false, true] {
            for controllers in [false, true] {
                for game in [false, true] {
                    let policy = ControllerPointerPolicy(physicalHeadset: physical,
                        realControllersAvailable: controllers, gamePresenting: game)
                    precondition(!policy.capturesMouse(for: .sense))
                    precondition(policy.capturesMouse(for: .desktopMouse) == !game)
                    precondition(policy.allowsCapture(.explicitDesktopMouse) == !game)
                    precondition(policy.allowsNativeControllerEvents == !game)
                    precondition(policy.activationCapture(explicitPending: true)
                        == (game ? nil : .explicitDesktopMouse))
                    let automatic = !game && (!physical || !controllers)
                    precondition(policy.allowsAutomaticReclaim == automatic)
                    precondition(policy.allowsCapture(.automatic) == automatic)
                    precondition(policy.activationCapture(explicitPending: false)
                        == (automatic ? .automatic : nil))
                }
            }
        }

        // Both gameplay and the local dashboard keep the producer presenting.
        // A late explicit preview capture cannot reacquire the OS mouse in either.
        for _ in ["gameplay", "paused dashboard"] {
            let context = ControllerPointerPolicy(physicalHeadset: true,
                realControllersAvailable: true, gamePresenting: true)
            precondition(!context.allowsNativeControllerEvents)
            precondition(context.activationCapture(explicitPending: true) == nil)
            precondition(!ControllerPointerPolicy.shouldParkCursor(locked: false,
                macWindowInteraction: false, inUnavailableDisplay: true, gamePresenting: true))
        }
        precondition(ControllerPointerPolicy.shouldParkCursor(locked: false,
            macWindowInteraction: false, inUnavailableDisplay: true))
        precondition(!ControllerPointerPolicy.shouldParkCursor(locked: true,
            macWindowInteraction: false, inUnavailableDisplay: true))
        precondition(!ControllerPointerPolicy.shouldParkCursor(locked: false,
            macWindowInteraction: true, inUnavailableDisplay: true))
        precondition(!ControllerPointerPolicy.shouldParkCursor(locked: false,
            macWindowInteraction: false, inUnavailableDisplay: false))

        // A pending down canceled by entering the game must not create either
        // a late click or an unmatched cleanup up, even after returning Home.
        var queue = NativeMouseEventSequence()
        queue.begin()
        let pendingDown = queue.generation
        precondition(queue.accepts(pendingDown))
        precondition(queue.end().isEmpty)
        precondition(!queue.accepts(pendingDown))
        queue.begin()
        precondition(!queue.accepts(pendingDown))
        let next = queue.generation
        queue.posted(.left, isDown: true)
        queue.posted(.right, isDown: true)
        precondition(Set(queue.end()) == Set([.left, .right]))
        precondition(!queue.accepts(next))
        precondition(queue.end().isEmpty)

        // A delivered up balances its own down; the transition releases only
        // the other held button once. Starting an existing interaction is stable.
        queue.begin()
        let stable = queue.generation
        queue.begin()
        precondition(queue.generation == stable)
        queue.posted(.left, isDown: true)
        queue.posted(.right, isDown: true)
        queue.posted(.left, isDown: false)
        precondition(queue.end() == [.right])
        precondition(queue.end().isEmpty)
        print("PASS: game/dashboard block OS capture, activation and cursor parking in all 8 contexts; pending native events cancel by epoch; only delivered downs receive one balanced cleanup release; Home/explicit desktop fallback remains available")
    }
}
