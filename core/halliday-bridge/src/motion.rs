//! Optional per-component velocity validity, associated with one exact v6 state.
use crate::Header;
use core::sync::atomic::{AtomicU32, Ordering};
pub const OFFSET: usize = 64640;
pub const MAGIC: u32 = u32::from_le_bytes(*b"HLVM");
pub const VERSION: u32 = 1;
pub const ALL: u32 = 0x3f;
pub const EXPLICIT: u32 = 1;
#[repr(C)]
pub struct Extension {
    pub magic: u32,
    pub version: u32,
    pub state_sequence: AtomicU32,
    pub mask: AtomicU32,
    pub flags: AtomicU32,
    pub reserved: [u32; 3],
}
const _: () = assert!(core::mem::size_of::<Extension>() == 32);
const _: () = assert!(core::mem::offset_of!(Extension, state_sequence) == 8);
const _: () = assert!(core::mem::offset_of!(Extension, mask) == 12);
const _: () = assert!(OFFSET + core::mem::size_of::<Extension>() <= crate::HEADER_BYTES);
/// # Safety
/// The caller maps the complete v6 header, including reserved bytes.
pub unsafe fn extension<'a>(header: *const Header) -> &'a Extension {
    unsafe { &*header.cast::<u8>().add(OFFSET).cast::<Extension>() }
}
/// # Safety
/// The host initializes its own private zeroed mapping before publishing it.
pub unsafe fn initialize(header: *mut Header) {
    let ext = unsafe { header.cast::<u8>().add(OFFSET).cast::<Extension>() };
    unsafe {
        (*ext).version = VERSION;
        (*ext).magic = MAGIC;
    }
}
impl Extension {
    pub fn available(&self) -> bool {
        self.magic == MAGIC && self.version == VERSION
    }
    /// Called while the ordinary state sequence is odd, before its final release.
    pub fn publish(&self, final_sequence: u32, mask: Option<u32>) {
        if !self.available() {
            return;
        }
        self.mask
            .store(mask.unwrap_or(ALL) & ALL, Ordering::Relaxed);
        self.flags
            .store(if mask.is_some() { EXPLICIT } else { 0 }, Ordering::Relaxed);
        self.state_sequence.store(final_sequence, Ordering::Relaxed);
    }
    /// Missing/legacy metadata preserves the original contract. An explicit
    /// tag for another state never upgrades unknown motion to legacy validity.
    pub fn read(&self, sequence: u32) -> u32 {
        if !self.available() || self.flags.load(Ordering::Relaxed) & EXPLICIT == 0 {
            return ALL;
        }
        if self.state_sequence.load(Ordering::Relaxed) != sequence {
            return 0;
        }
        self.mask.load(Ordering::Relaxed) & ALL
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validity_is_associated_with_the_complete_state_and_legacy_writers_remain_usable() {
        let mut memory = [0u64; crate::HEADER_BYTES / 8];
        let h = memory.as_mut_ptr().cast::<Header>();
        let mut state = crate::State::default();
        state.head.velocity = [1., 2., 3.];
        unsafe {
            crate::publish_with_motion(h, &state, false, Some(0));
            assert_eq!(
                crate::read_state_with_motion(h).unwrap().1,
                ALL,
                "old host has no validity capability"
            );
            initialize(h);
            for (index, mask) in [0, 1, 2, 3, 4, 8, 16, 32, ALL, 0xffff]
                .into_iter()
                .enumerate()
            {
                state.controllers[0].packet = index as u32;
                crate::publish_with_motion(h, &state, false, Some(mask));
                let (actual, validity) = crate::read_state_with_motion(h).unwrap();
                assert_eq!(actual, state);
                assert_eq!(validity, mask & ALL);
            }
            let ext = extension(h);
            ext.state_sequence.fetch_add(2, Ordering::Relaxed);
            assert_eq!(
                crate::read_state_with_motion(h).unwrap().1,
                0,
                "mismatched explicit metadata cannot claim legacy validity"
            );
            crate::publish_with_motion(h, &state, false, None);
            assert_eq!(
                crate::read_state_with_motion(h).unwrap().1,
                ALL,
                "old producer deliberately uses the legacy contract"
            );
            (*h).state_seq.store(u32::MAX - 1, Ordering::Relaxed);
            crate::publish_with_motion(h, &state, false, Some(17));
            assert_eq!((*h).state_seq.load(Ordering::Relaxed), 0);
            assert_eq!(
                crate::read_state_with_motion(h).unwrap().1,
                17,
                "wrapped sequence zero remains a complete state"
            );
            (*h).state_seq.store(1, Ordering::Relaxed);
            assert!(
                crate::read_state_with_motion(h).is_none(),
                "odd/incomplete state never returns a metadata snapshot"
            );
        }
    }
}
