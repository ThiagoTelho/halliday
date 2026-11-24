/// Controller rays and desktop input have independent ownership. A real VR
/// menu can be operated without activating its Mac app or capturing the mouse.
struct ControllerPointerPolicy {
    enum ClickSource { case desktopMouse, sense }
    enum CaptureIntent { case automatic, explicitDesktopMouse }

    let physicalHeadset: Bool
    let realControllersAvailable: Bool
    let gamePresenting: Bool

    var allowsAutomaticReclaim: Bool {
        !gamePresenting && (!physicalHeadset || !realControllersAvailable)
    }

    /// Includes Halliday's dashboard over a running game. Its panels consume
    /// the controller ray locally; they are never a Mac mouse interaction.
    var allowsNativeControllerEvents: Bool { !gamePresenting }

    func allowsCapture(_ intent: CaptureIntent) -> Bool {
        !gamePresenting && (intent == .explicitDesktopMouse || allowsAutomaticReclaim)
    }

    func capturesMouse(for source: ClickSource) -> Bool { !gamePresenting && source == .desktopMouse }

    /// AppKit may deliver activation after the explicit preview click. That
    /// one pending request survives the callback without permitting later
    /// automatic controller/game focus reclamation.
    func activationCapture(explicitPending: Bool) -> CaptureIntent? {
        if explicitPending && !gamePresenting { return .explicitDesktopMouse }
        return allowsAutomaticReclaim ? .automatic : nil
    }

    static func shouldParkCursor(locked: Bool, macWindowInteraction: Bool, inUnavailableDisplay: Bool,
                                 gamePresenting: Bool = false) -> Bool {
        !gamePresenting && !locked && !macWindowInteraction && inUnavailableDisplay
    }
}

/// Lifetime of synthetic desktop events, separate from VR panel button state.
/// A delayed press from a previous ownership epoch must never arrive in a game
/// or a newly focused app. Only buttons whose downs were posted need cleanup.
struct NativeMouseEventSequence {
    enum Button: CaseIterable, Hashable { case left, right }
    private(set) var generation: UInt64 = 0
    private(set) var active = false
    private var down: Set<Button> = []

    mutating func begin() {
        guard !active else { return }
        generation &+= 1
        active = true
        down.removeAll()
    }

    func accepts(_ token: UInt64) -> Bool { active && token == generation }

    mutating func posted(_ button: Button, isDown: Bool) {
        if isDown { down.insert(button) } else { down.remove(button) }
    }

    mutating func end() -> [Button] {
        let releases = Button.allCases.filter { down.contains($0) }
        active = false
        generation &+= 1
        down.removeAll()
        return releases
    }
}
