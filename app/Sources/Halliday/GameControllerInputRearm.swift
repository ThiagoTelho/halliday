/// A dashboard/resume transition must not turn already-held controls into a
/// fresh game action. Each control rearms independently on physical release;
/// poses and ordinary focused input are never delayed or altered.
struct GameControllerInputRearm {
    struct Input: Equatable {
        var pressed: UInt64 = 0
        var touched: UInt64 = 0
        var stick: SIMD2<Float> = .zero
        var trigger: Float = 0
        var grip: Float = 0
        static let neutral = Self()
    }

    private static let triggerBit: UInt64 = 1 << 33
    private static let gripBit: UInt64 = 1 << 2
    private static let stickBit: UInt64 = 1 << 32
    private var focused = true
    private var captureHeld = false
    private var blockedButtons: UInt64 = 0
    private var blockedTrigger = false
    private var blockedGrip = false
    private var blockedStick = false

    mutating func setFocused(_ value: Bool) {
        guard focused != value else { return }
        focused = value
        if !value { captureHeld = true }
    }

    mutating func filter(_ raw: Input) -> Input {
        guard focused else { return .neutral }
        if captureHeld {
            blockedButtons = raw.pressed
            blockedTrigger = raw.trigger > 0.15 || raw.pressed & Self.triggerBit != 0
            blockedGrip = raw.grip > 0.15 || raw.pressed & Self.gripBit != 0
            blockedStick = raw.stick.x * raw.stick.x + raw.stick.y * raw.stick.y > 0.15 * 0.15
            captureHeld = false
        }
        blockedButtons &= raw.pressed
        if raw.trigger <= 0.15 && raw.pressed & Self.triggerBit == 0 { blockedTrigger = false }
        if raw.grip <= 0.15 && raw.pressed & Self.gripBit == 0 { blockedGrip = false }
        if raw.stick.x * raw.stick.x + raw.stick.y * raw.stick.y <= 0.15 * 0.15 { blockedStick = false }
        var result = raw
        result.pressed &= ~blockedButtons
        result.touched &= ~blockedButtons
        if blockedTrigger {
            result.trigger = 0
            result.pressed &= ~Self.triggerBit
            result.touched &= ~Self.triggerBit
        }
        if blockedGrip {
            result.grip = 0
            result.pressed &= ~Self.gripBit
            result.touched &= ~Self.gripBit
        }
        if blockedStick {
            result.stick = .zero
            result.touched &= ~Self.stickBit
        }
        return result
    }
}
