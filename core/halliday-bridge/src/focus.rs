//! Optional focus-edge and haptic request association in unused v6 header bytes.
use crate::Header;
use core::sync::atomic::{AtomicU64, Ordering};

pub const OFFSET: usize = 64176;
pub const MAGIC: u32 = u32::from_le_bytes(*b"HLFC");
pub const VERSION: u32 = 1;
#[repr(C)]
pub struct Extension {
    pub magic: u32,
    pub version: u32,
    /// Upper 32 bits: nonzero generation. Bit zero: dashboard is shown.
    pub state: AtomicU64,
    pub producer_epoch: AtomicU64,
    /// Upper 32 bits: exact mailbox sequence; lower 32 bits: focus generation.
    /// The producer updates this under the corresponding mailbox seqlock.
    pub requests: [AtomicU64; 2],
}
const _: () = assert!(core::mem::size_of::<Extension>() == 40);
const _: () = assert!(core::mem::offset_of!(Extension, state) == 8);
const _: () = assert!(core::mem::offset_of!(Extension, producer_epoch) == 16);
const _: () = assert!(core::mem::offset_of!(Extension, requests) == 24);
const _: () =
    assert!(OFFSET >= crate::panels::OFFSET + core::mem::size_of::<crate::panels::Extension>());
const _: () = assert!(OFFSET + core::mem::size_of::<Extension>() <= crate::HEADER_BYTES);

/// # Safety
/// `header` maps the complete v6 bridge including reserved header bytes.
pub unsafe fn extension<'a>(header: *const Header) -> &'a Extension {
    unsafe { &*header.cast::<u8>().add(OFFSET).cast::<Extension>() }
}
/// # Safety
/// The host initializes a private zeroed bridge before publishing it.
pub unsafe fn initialize(header: *mut Header) {
    let ext = unsafe { header.cast::<u8>().add(OFFSET).cast::<Extension>() };
    unsafe {
        (*ext).version = VERSION;
        (*ext).state.store(1u64 << 32, Ordering::SeqCst);
        (*ext).magic = MAGIC;
    }
}
impl Extension {
    pub fn available(&self) -> bool {
        self.magic == MAGIC && self.version == VERSION
    }
    pub fn generation(&self) -> u32 {
        if self.available() {
            (self.state.load(Ordering::SeqCst) >> 32) as u32
        } else {
            0
        }
    }
    pub fn shown(&self) -> bool {
        self.available() && self.state.load(Ordering::SeqCst) & 1 != 0
    }
    pub fn set_dashboard(&self, shown: bool) {
        if !self.available() {
            return;
        }
        let _ = self
            .state
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |old| {
                if (old & 1 != 0) == shown {
                    return None;
                }
                let generation = ((old >> 32) as u32).wrapping_add(1).max(1);
                Some((u64::from(generation) << 32) | u64::from(shown))
            });
    }
    pub fn claim(&self, epoch: u64) {
        if !self.available() {
            return;
        }
        self.producer_epoch.store(0, Ordering::SeqCst);
        for tag in &self.requests {
            tag.store(0, Ordering::SeqCst);
        }
        self.producer_epoch.store(epoch, Ordering::SeqCst);
    }
    pub fn tag(&self, epoch: u64, hand: usize, sequence: u32, generation: u32) {
        if self.available() && hand < 2 && self.producer_epoch.load(Ordering::SeqCst) == epoch {
            self.requests[hand].store(
                (u64::from(sequence) << 32) | u64::from(generation),
                Ordering::Relaxed,
            );
        }
    }
    /// None preserves compatibility with a host or producer without HLFC.
    pub fn matches(&self, epoch: u64, hand: usize, sequence: u32, generation: u32) -> Option<bool> {
        if !self.available() || hand >= 2 || self.producer_epoch.load(Ordering::SeqCst) != epoch {
            return None;
        }
        Some(
            self.generation() == generation
                && self.requests[hand].load(Ordering::Acquire)
                    == ((u64::from(sequence) << 32) | u64::from(generation)),
        )
    }
}
