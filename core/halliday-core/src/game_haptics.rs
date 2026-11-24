//! Commands delivered from a game's output transport to a physical controller.

/// One latest command per hand, shared by Rust and the C ABI. `duration_ns` is
/// the remaining duration at consumption, so polling never extends a pulse.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GameHapticCommand {
    pub hand: u32,
    pub sequence: u32,
    pub stop: u32,
    pub _pad: u32,
    pub amplitude: f32,
    pub frequency_hz: f32,
    pub duration_ns: u64,
}

#[cfg(test)]
mod tests {
    use super::GameHapticCommand;
    use std::mem::{align_of, offset_of, size_of};

    #[test]
    fn c_command_layout_is_stable() {
        assert_eq!(size_of::<GameHapticCommand>(), 32);
        assert_eq!(align_of::<GameHapticCommand>(), 8);
        assert_eq!(offset_of!(GameHapticCommand, hand), 0);
        assert_eq!(offset_of!(GameHapticCommand, sequence), 4);
        assert_eq!(offset_of!(GameHapticCommand, stop), 8);
        assert_eq!(offset_of!(GameHapticCommand, _pad), 12);
        assert_eq!(offset_of!(GameHapticCommand, amplitude), 16);
        assert_eq!(offset_of!(GameHapticCommand, frequency_hz), 20);
        assert_eq!(offset_of!(GameHapticCommand, duration_ns), 24);
    }
}
