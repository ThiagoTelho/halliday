/// Controller rays and desktop input have independent ownership. A real VR
/// menu can be operated without activating its Mac app or capturing the mouse.
struct ControllerPointerPolicy {
    enum ClickSource { case desktopMouse, sense }
    enum CaptureIntent { case automatic, explicitDesktopMouse }

    let physicalHeadset: Bool
    let realControllersAvailable: Bool
    let gamePresenting: Bool

    var allowsAutomaticReclaim: Bool {
        !physicalHeadset || (!realControllersAvailable && !gamePresenting)
    }

    func allowsCapture(_ intent: CaptureIntent) -> Bool {
        intent == .explicitDesktopMouse || allowsAutomaticReclaim
    }

    func capturesMouse(for source: ClickSource) -> Bool { source == .desktopMouse }

    /// AppKit may deliver activation after the explicit preview click. That
    /// one pending request survives the callback without permitting later
    /// automatic controller/game focus reclamation.
    func activationCapture(explicitPending: Bool) -> CaptureIntent? {
        if explicitPending { return .explicitDesktopMouse }
        return allowsAutomaticReclaim ? .automatic : nil
    }

    static func shouldParkCursor(locked: Bool, macWindowInteraction: Bool, inUnavailableDisplay: Bool) -> Bool {
        !locked && !macWindowInteraction && inUnavailableDisplay
    }
}
