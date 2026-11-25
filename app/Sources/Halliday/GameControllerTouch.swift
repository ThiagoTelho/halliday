import Foundation

/// Actual Sense capacitive contacts. Analog proximity remains analog; a pressed
/// button, moved stick or trigger travel does not invent a capacitive contact.
struct GameControllerTouch: Sendable, Equatable {
    let buttons: UInt32
    let triggerProximity: Float
    let gripProximity: Float
    var bridgeTouched: UInt64 {
        var value: UInt64 = 0
        for (source, target) in [(8, 33), (9, 2), (10, 32), (11, 7), (12, 1)] {
            if buttons & (UInt32(1) << source) != 0 { value |= UInt64(1) << target }
        }
        return value
    }
    var proximity: SIMD2<Float> {
        let clean: (Float) -> Float = { $0.isFinite ? min(1, max(0, $0)) : 0 }
        return SIMD2(clean(triggerProximity), clean(gripProximity))
    }
}
