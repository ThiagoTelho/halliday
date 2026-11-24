@main struct ControllerPointerPolicyTests {
    static func main() {
        for physical in [false, true] {
            for controllers in [false, true] {
                for game in [false, true] {
                    let policy = ControllerPointerPolicy(physicalHeadset: physical,
                        realControllersAvailable: controllers, gamePresenting: game)
                    // A real controller press reaches its first VR target; it
                    // must never be consumed to acquire a desktop mouse first.
                    precondition(!policy.capturesMouse(for: .sense))
                    // A deliberate preview mouse click retains the old mouse
                    // fallback, including when controllers are also connected.
                    precondition(policy.capturesMouse(for: .desktopMouse))
                    precondition(policy.allowsCapture(.explicitDesktopMouse))
                    precondition(policy.activationCapture(explicitPending: true) == .explicitDesktopMouse)
                    if physical && (controllers || game) {
                        precondition(!policy.allowsAutomaticReclaim)
                        precondition(!policy.allowsCapture(.automatic))
                        precondition(policy.activationCapture(explicitPending: false) == nil)
                    } else {
                        precondition(policy.allowsAutomaticReclaim)
                        precondition(policy.allowsCapture(.automatic))
                        precondition(policy.activationCapture(explicitPending: false) == .automatic)
                    }
                }
            }
        }
        let controllerMenu = ControllerPointerPolicy(physicalHeadset: true,
            realControllersAvailable: true, gamePresenting: false)
        let pausedGameMenu = ControllerPointerPolicy(physicalHeadset: true,
            realControllersAvailable: true, gamePresenting: true)
        let wheelGame = ControllerPointerPolicy(physicalHeadset: true,
            realControllersAvailable: false, gamePresenting: true)
        for menu in [controllerMenu, pausedGameMenu, wheelGame] {
            precondition(!menu.allowsAutomaticReclaim)
            precondition(!menu.allowsCapture(.automatic))
            precondition(menu.allowsCapture(.explicitDesktopMouse))
            // Delayed activation honors one explicit preview request; after
            // consumption, resignation, unlock or Sense use clears that request,
            // the same callback is no longer permission to recapture.
            precondition(menu.activationCapture(explicitPending: true) == .explicitDesktopMouse)
            precondition(menu.activationCapture(explicitPending: false) == nil)
        }
        // Parking is for otherwise inaccessible headset/virtual displays, not
        // an active Mac-window interaction or an explicitly captured mouse.
        precondition(ControllerPointerPolicy.shouldParkCursor(locked: false,
            macWindowInteraction: false, inUnavailableDisplay: true))
        precondition(!ControllerPointerPolicy.shouldParkCursor(locked: true,
            macWindowInteraction: false, inUnavailableDisplay: true))
        precondition(!ControllerPointerPolicy.shouldParkCursor(locked: false,
            macWindowInteraction: true, inUnavailableDisplay: true))
        precondition(!ControllerPointerPolicy.shouldParkCursor(locked: false,
            macWindowInteraction: false, inUnavailableDisplay: false))
        print("PASS: Sense first click bypasses desktop capture; physical controller/game UI cannot auto reclaim; explicit mouse fallback and delayed activation retained in 8 contexts; cleared request cannot recapture; cursor parking respects explicit Mac-window interaction")
    }
}
