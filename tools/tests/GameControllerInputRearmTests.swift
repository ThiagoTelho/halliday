@main struct GameControllerInputRearmTests {
    typealias Gate = GameControllerInputRearm
    static let trigger: UInt64 = 1 << 33, grip: UInt64 = 1 << 2, stick: UInt64 = 1 << 32
    static func main() {
        var right = Gate(), left = Gate()
        let ordinary = Gate.Input(pressed: trigger | grip | stick | 128, touched: trigger | stick,
            stick: [0.31, -0.52], trigger: 0.74, grip: 1)
        precondition(right.filter(ordinary) == ordinary, "Focused input changed")
        right.setFocused(false); left.setFocused(false)
        precondition(right.filter(ordinary) == .neutral)
        // No dashboard tick is required for safety: focus loss and regain can
        // happen between two input publications (PS/keyboard resume).
        right.setFocused(true); left.setFocused(true)
        precondition(right.filter(ordinary) == .neutral, "Held controls leaked on resume")
        precondition(right.filter(ordinary) == .neutral, "A held control rearmed without release")
        precondition(left.filter(.neutral) == .neutral)
        let leftPress = Gate.Input(pressed: trigger, touched: trigger, trigger: 1)
        precondition(left.filter(leftPress) == leftPress, "Other hand was unnecessarily blocked")
        // A released trigger rearms without requiring the still-held grip,
        // stick or unrelated button to be released.
        var triggerUp = ordinary
        triggerUp.pressed &= ~trigger; triggerUp.trigger = 0.04
        _ = right.filter(triggerUp)
        let triggerAgain = right.filter(ordinary)
        precondition(triggerAgain.trigger == ordinary.trigger && triggerAgain.pressed & trigger != 0)
        precondition(triggerAgain.pressed & grip == 0 && triggerAgain.stick == .zero)
        // Analog release uses a neutral band; it does not require exact zero
        // and is not applied as a deadzone during ordinary gameplay.
        var centered = ordinary
        centered.stick = [0.05, -0.05]; centered.grip = 0
        centered.pressed &= ~(grip | stick | 128)
        _ = right.filter(centered)
        precondition(right.filter(ordinary) == ordinary, "Released controls failed to rearm")
        let slight = Gate.Input(stick: [0.01, -0.03], trigger: 0.02, grip: 0.01)
        precondition(right.filter(slight) == slight, "Normal analog input was clamped")
        // The Resume button fires on release, so a fully released hand need
        // not perform an extra release before its next genuine trigger press.
        right.setFocused(false); _ = right.filter(ordinary)
        right.setFocused(true); _ = right.filter(.neutral)
        precondition(right.filter(leftPress) == leftPress)
        // Repeated 'focused' notifications cannot suppress a fresh press.
        right.setFocused(true)
        precondition(right.filter(leftPress) == leftPress)
        // A second dashboard cycle independently captures its current held set.
        right.setFocused(false); right.setFocused(true)
        precondition(right.filter(leftPress) == .neutral)
        _ = right.filter(.neutral)
        precondition(right.filter(leftPress) == leftPress)
        print("PASS: unchanged normal input; neutral dashboard; PS/keyboard resume; both hands; per-control analog/digital release; no deadzone; trigger-release Resume; repeated focus and re-entry")
    }
}
