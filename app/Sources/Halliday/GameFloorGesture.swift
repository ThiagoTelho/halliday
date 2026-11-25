/// The existing R1+vertical-stick floor adjustment is a pause-menu action.
/// A game's own pause state and desktop/window focus are not this authority.
enum GameFloorGesture {
    static func heightStick(gamePresenting: Bool, pauseMenuOpen: Bool, gamePaused: Bool,
                            rightGripHeld: Bool, stick: SIMD2<Float>) -> Float? {
        guard gamePresenting, pauseMenuOpen, gamePaused, rightGripHeld,
              abs(stick.y) > 0.25 else { return nil }
        return stick.y
    }
}
