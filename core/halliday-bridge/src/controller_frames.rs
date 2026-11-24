//! Optional orientation-frame declaration paired with one host state publication.
//!
//! This candidate is isolated and has not been deployed. An undeclared/legacy pose is
//! passed through exactly. Only an explicitly tagged Sense AIM orientation may
//! receive the source-derived OpenXR GRIP rotation. Positions and world-space
//! velocities never change, and the existing OpenVR output remains unchanged.

use crate::{HEADER_BYTES, Header, Pose, math};
use core::sync::atomic::{AtomicU32, Ordering, fence};

pub const OFFSET: usize = 65480;
pub const MAGIC: u32 = u32::from_le_bytes(*b"HLCF");
pub const VERSION: u32 = 1;

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameKind {
    Legacy = 0,
    /// The existing common Sense game pose: IMU * Rx(49.8703 degrees).
    SenseAim = 1,
}

impl FrameKind {
    pub const fn from_wire(value: u32) -> Option<Self> {
        match value {
            0 => Some(Self::Legacy),
            1 => Some(Self::SenseAim),
            _ => None,
        }
    }
}

pub const LEGACY: [FrameKind; 2] = [FrameKind::Legacy; 2];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    OpenXrAim,
    OpenXrGrip,
    /// Preserve the established OpenVR/native-Alyx reference exactly.
    LegacyOpenVr,
}

/// Monado 2069b76b: AIM -39.4 degrees, GRIP +20.6 degrees in one root.
/// Their orientation difference is +60 degrees about local X. This is an API
/// coordinate-frame conversion, not a measured anatomical wrist adjustment.
pub fn orientation(kind: FrameKind, target: Target, q: [f32; 4]) -> [f32; 4] {
    if kind == FrameKind::SenseAim && target == Target::OpenXrGrip {
        math::quat_mul(q, [0.5, 0.0, 0.0, 0.866_025_4])
    } else {
        q
    }
}

pub fn pose(kind: FrameKind, target: Target, mut source: Pose) -> Pose {
    source.orientation = orientation(kind, target, source.orientation);
    source
}

#[repr(C)]
pub struct Extension {
    pub magic: u32,
    pub version: u32,
    pub bytes: u32,
    pub hands: u32,
    pub sequence: AtomicU32,
    pub state_sequence: AtomicU32,
    pub kinds: [AtomicU32; 2],
}

const _: () = assert!(core::mem::size_of::<Extension>() == 32);
const _: () = assert!(core::mem::offset_of!(Extension, sequence) == 16);
const _: () = assert!(core::mem::offset_of!(Extension, kinds) == 24);
const _: () = assert!(OFFSET + core::mem::size_of::<Extension>() <= HEADER_BYTES);
const _: () = assert!(
    OFFSET == crate::frame_timing::OFFSET + core::mem::size_of::<crate::frame_timing::Extension>()
);

/// # Safety
/// The complete header is mapped and a single host owns initialization.
pub unsafe fn initialize(header: *mut Header) {
    let destination = unsafe { header.cast::<u8>().add(OFFSET).cast::<Extension>() };
    unsafe {
        destination.write(Extension {
            magic: MAGIC,
            version: VERSION,
            bytes: 32,
            hands: 2,
            sequence: AtomicU32::new(0),
            state_sequence: AtomicU32::new(0),
            kinds: [AtomicU32::new(0), AtomicU32::new(0)],
        })
    };
}

/// # Safety
/// The complete header, including optional reserved bytes, is mapped.
pub unsafe fn extension(header: *const Header) -> Option<&'static Extension> {
    let value = unsafe { &*header.cast::<u8>().add(OFFSET).cast::<Extension>() };
    (value.magic == MAGIC && value.version == VERSION && value.bytes == 32 && value.hands == 2)
        .then_some(value)
}

/// The caller owns the outer odd state sequence. The metadata commits before
/// the corresponding even state becomes visible. Invalid/missing capability
/// cannot modify existing state or old readers.
/// # Safety
/// Single host publisher and a complete live mapped header.
pub unsafe fn write(header: *mut Header, next_state_sequence: u32, kinds: [FrameKind; 2]) -> bool {
    let Some(value) = (unsafe { extension(header) }) else {
        return false;
    };
    if next_state_sequence & 1 != 0
        || unsafe { (*header).state_seq.load(Ordering::Acquire) }
            != next_state_sequence.wrapping_sub(1)
    {
        return false;
    }
    let odd = value.sequence.load(Ordering::Relaxed) | 1;
    value.sequence.store(odd, Ordering::SeqCst);
    value
        .state_sequence
        .store(next_state_sequence, Ordering::Relaxed);
    for (destination, kind) in value.kinds.iter().zip(kinds) {
        destination.store(kind as u32, Ordering::Relaxed);
    }
    value
        .sequence
        .store(odd.wrapping_add(1).max(2), Ordering::Release);
    true
}

/// Return declarations only for this exact, stable outer host state. Absence,
/// unknown versions/kinds, odd records and stale state identity return None;
/// callers keep legacy behavior rather than guessing a conversion.
/// # Safety
/// Complete mapped header remains live for the read.
pub unsafe fn read(header: *const Header, expected_state_sequence: u32) -> Option<[FrameKind; 2]> {
    if expected_state_sequence & 1 != 0 {
        return None;
    }
    let value = unsafe { extension(header) }?;
    let state = unsafe { &(*header).state_seq };
    for _ in 0..8 {
        if state.load(Ordering::Acquire) != expected_state_sequence {
            return None;
        }
        let before = value.sequence.load(Ordering::Acquire);
        if before == 0 || before & 1 != 0 {
            continue;
        }
        let identity = value.state_sequence.load(Ordering::Relaxed);
        let kinds = [
            value.kinds[0].load(Ordering::Relaxed),
            value.kinds[1].load(Ordering::Relaxed),
        ];
        fence(Ordering::Acquire);
        if before == value.sequence.load(Ordering::Relaxed)
            && identity == expected_state_sequence
            && state.load(Ordering::Relaxed) == expected_state_sequence
        {
            return Some([
                FrameKind::from_wire(kinds[0])?,
                FrameKind::from_wire(kinds[1])?,
            ]);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use std::boxed::Box;

    fn memory() -> Box<[u64; HEADER_BYTES / 8]> {
        Box::new([0; HEADER_BYTES / 8])
    }
    fn sample() -> Pose {
        Pose {
            position: [0.2, 1.1, -0.4],
            valid: 1,
            orientation: [0.0, 0.0, 0.0, 1.0],
            velocity: [0.4, -0.2, 0.3],
            angular_velocity: [-0.2, 1.4, 0.6],
            stamp: 73.0,
            ..Pose::default()
        }
    }
    fn rx(degrees: f32) -> [f32; 4] {
        let half = degrees.to_radians() * 0.5;
        [half.sin(), 0.0, 0.0, half.cos()]
    }
    fn near(a: [f32; 4], b: [f32; 4]) {
        let same: f32 = a.iter().zip(b).map(|(x, y)| (x - y) * (x - y)).sum();
        let flipped: f32 = a.iter().zip(b).map(|(x, y)| (x + y) * (x + y)).sum();
        assert!(same.min(flipped) < 1e-10, "{a:?} != {b:?}");
    }
    #[test]
    fn declaration_layout_does_not_overlap_timing_or_change_v6_state() {
        assert_eq!(OFFSET, 65480);
        assert_eq!(core::mem::size_of::<Extension>(), 32);
        assert_eq!(core::mem::offset_of!(Extension, state_sequence), 20);
        assert_eq!(core::mem::size_of::<Pose>(), 64);
        assert_eq!(core::mem::offset_of!(Header, state), 72);
        assert_eq!(OFFSET + core::mem::size_of::<Extension>(), 65512);
    }
    #[test]
    fn undeclared_legacy_old_host_new_reader_and_new_host_old_reader_matrix() {
        let mut bytes = memory();
        let h = bytes.as_mut_ptr().cast::<Header>();
        let mut state = crate::State::default();
        state.controllers[0].pose = sample();
        unsafe { crate::publish(h, &state) };
        assert!(unsafe { read(h, 2) }.is_none()); // old host / new reader
        unsafe {
            initialize(h);
            crate::publish_with_controller_frames(
                h,
                &state,
                true,
                None,
                [FrameKind::SenseAim, FrameKind::Legacy],
            );
        }
        assert_eq!(unsafe { crate::read_state(h) }, Some(state)); // new host / old reader
        assert_eq!(
            unsafe { read(h, 4) },
            Some([FrameKind::SenseAim, FrameKind::Legacy])
        );
        unsafe { crate::publish(h, &state) }; // old API must clear prior type tags
        assert_eq!(unsafe { read(h, 6) }, Some(LEGACY));
        for target in [Target::OpenXrAim, Target::OpenXrGrip, Target::LegacyOpenVr] {
            assert_eq!(pose(FrameKind::Legacy, target, sample()), sample());
        }
    }
    #[test]
    fn metadata_rejects_wrong_state_odd_unknown_kind_and_malformed_capability() {
        let mut bytes = memory();
        let h = bytes.as_mut_ptr().cast::<Header>();
        unsafe { initialize(h) };
        let e = unsafe { extension(h) }.unwrap();
        assert!(!unsafe { write(h, 2, [FrameKind::SenseAim; 2]) });
        unsafe { (*h).state_seq.store(1, Ordering::SeqCst) };
        assert!(unsafe { write(h, 2, [FrameKind::SenseAim; 2]) });
        assert!(unsafe { read(h, 2) }.is_none());
        unsafe { (*h).state_seq.store(2, Ordering::SeqCst) };
        assert_eq!(unsafe { read(h, 2) }, Some([FrameKind::SenseAim; 2]));
        assert!(unsafe { read(h, 4) }.is_none());
        e.sequence.store(3, Ordering::SeqCst);
        assert!(unsafe { read(h, 2) }.is_none());
        e.sequence.store(4, Ordering::SeqCst);
        e.kinds[1].store(8, Ordering::SeqCst);
        assert!(unsafe { read(h, 2) }.is_none());
        let raw = unsafe { h.cast::<u8>().add(OFFSET).cast::<Extension>() };
        unsafe { (*raw).version = 99 };
        assert!(unsafe { read(h, 2) }.is_none());
    }
    #[test]
    fn state_counter_wrap_and_real_controller_to_mouse_transition_are_exact() {
        let mut bytes = memory();
        let h = bytes.as_mut_ptr().cast::<Header>();
        unsafe {
            initialize(h);
            (*h).state_seq.store(u32::MAX - 1, Ordering::SeqCst);
        }
        let state = crate::State::default();
        unsafe {
            crate::publish_with_controller_frames(
                h,
                &state,
                false,
                None,
                [FrameKind::SenseAim, FrameKind::Legacy],
            );
        }
        assert_eq!(unsafe { (*h).state_seq.load(Ordering::SeqCst) }, 0);
        assert_eq!(
            unsafe { read(h, 0) },
            Some([FrameKind::SenseAim, FrameKind::Legacy])
        );
        unsafe {
            crate::publish_with_controller_frames(
                h,
                &state,
                false,
                None,
                [FrameKind::Legacy, FrameKind::SenseAim],
            );
        }
        assert_eq!(
            unsafe { read(h, 2) },
            Some([FrameKind::Legacy, FrameKind::SenseAim])
        );
        unsafe { crate::publish(h, &state) };
        assert_eq!(unsafe { read(h, 4) }, Some(LEGACY));
    }
    #[test]
    fn sense_conversion_matches_reference_for_both_hands_and_arbitrary_room_axes() {
        for _hand in 0..2 {
            for yaw in [-140.0_f32, -45.0, 0.0, 45.0, 140.0] {
                for roll in [-180.0_f32, -90.0, 0.0, 90.0, 180.0] {
                    for pitch in [-65.0_f32, 0.0, 65.0] {
                        let (y, r) = (yaw.to_radians() * 0.5, roll.to_radians() * 0.5);
                        let sensor = math::quat_mul(
                            math::quat_mul([0.0, y.sin(), 0.0, y.cos()], rx(pitch)),
                            [0.0, 0.0, r.sin(), r.cos()],
                        );
                        let aim = math::quat_mul(sensor, rx(49.8703));
                        let expected_grip = math::quat_mul(sensor, rx(109.8703));
                        near(
                            orientation(FrameKind::SenseAim, Target::OpenXrGrip, aim),
                            expected_grip,
                        );
                        assert_eq!(
                            orientation(FrameKind::SenseAim, Target::OpenXrAim, aim),
                            aim
                        );
                        assert_eq!(
                            orientation(FrameKind::SenseAim, Target::LegacyOpenVr, aim),
                            aim
                        );
                    }
                }
            }
        }
    }
    #[test]
    fn orientation_only_keeps_origin_world_velocities_flags_and_stamp() {
        let source = sample();
        let result = pose(FrameKind::SenseAim, Target::OpenXrGrip, source);
        assert_ne!(result.orientation, source.orientation);
        assert_eq!(result.position, source.position);
        assert_eq!(result.velocity, source.velocity);
        assert_eq!(result.angular_velocity, source.angular_velocity);
        assert_eq!(result.valid, source.valid);
        assert_eq!(result.stamp, source.stamp);
        let world_step = rx(3.0);
        near(
            math::quat_mul(world_step, result.orientation),
            orientation(
                FrameKind::SenseAim,
                Target::OpenXrGrip,
                math::quat_mul(world_step, source.orientation),
            ),
        );
    }
}
