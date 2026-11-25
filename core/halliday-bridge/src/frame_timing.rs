//! HLFT v1: per-image producer time; never a host-import timestamp.
use crate::{HEADER_BYTES, Header, PRESENT_RING, SLOTS};
use core::sync::atomic::{AtomicI64, AtomicU32, AtomicU64, Ordering, fence};
pub const OFFSET: usize = 64704;
pub const MAGIC: u32 = u32::from_le_bytes(*b"HLFT");
pub const VERSION: u32 = 1;
pub const VALID: u32 = 1;
pub const XR_DISPLAY_TIME_NS: u32 = 1;
pub const SUBMIT_MONOTONIC_NS: u32 = 2;
pub const RECORDS: usize = SLOTS + PRESENT_RING;
#[repr(C)]
pub struct Record {
    pub sequence: AtomicU32,
    pub flags: AtomicU32,
    pub frame_index: AtomicU64,
    pub epoch: AtomicU64,
    pub nanoseconds: AtomicI64,
    pub clock_kind: AtomicU32,
    pub reserved: AtomicU32,
}
#[repr(C)]
pub struct Extension {
    pub magic: u32,
    pub version: u32,
    pub record_bytes: u32,
    pub records: u32,
    pub entries: [Record; RECORDS],
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub epoch: u64,
    pub frame_index: u64,
    pub nanoseconds: i64,
    pub clock_kind: u32,
    pub reserved: u32,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Time {
    pub nanoseconds: i64,
    pub clock_kind: u32,
}
impl Time {
    pub fn valid(self) -> bool {
        self.nanoseconds > 0 && matches!(self.clock_kind, XR_DISPLAY_TIME_NS | SUBMIT_MONOTONIC_NS)
    }
}
const _: () = assert!(
    core::mem::size_of::<Record>() == 40 && core::mem::offset_of!(Record, nanoseconds) == 24
);
const _: () = assert!(
    core::mem::offset_of!(Record, clock_kind) == 32 && core::mem::size_of::<Extension>() == 776
);
const _: () = assert!(
    core::mem::size_of::<Snapshot>() == 32 && core::mem::offset_of!(Snapshot, clock_kind) == 24
);
const _: () =
    assert!(OFFSET >= crate::motion::OFFSET + core::mem::size_of::<crate::motion::Extension>());
const _: () = assert!(OFFSET + core::mem::size_of::<Extension>() <= HEADER_BYTES);
pub const fn present_index(number: u32) -> usize {
    SLOTS + number as usize % PRESENT_RING
}
/// # Safety
/// `header` maps the complete v6 reserved header for the returned lifetime.
pub unsafe fn extension<'a>(header: *const Header) -> &'a Extension {
    unsafe { &*header.cast::<u8>().add(OFFSET).cast::<Extension>() }
}
/// # Safety
/// Host initializes a private zeroed full mapping before publishing it.
pub unsafe fn initialize(header: *mut Header) {
    let p = unsafe { header.cast::<u8>().add(OFFSET).cast::<Extension>() };
    unsafe {
        (*p).version = VERSION;
        (*p).record_bytes = 40;
        (*p).records = RECORDS as u32;
        (*p).magic = MAGIC;
    }
}
impl Extension {
    pub fn available(&self) -> bool {
        self.magic == MAGIC
            && self.version == VERSION
            && self.record_bytes == 40
            && self.records == RECORDS as u32
    }
    pub fn clear(&self, index: usize) {
        if !self.available() {
            return;
        }
        let Some(r) = self.entries.get(index) else {
            return;
        };
        let odd = r.sequence.load(Ordering::Relaxed) | 1;
        r.sequence.store(odd, Ordering::SeqCst);
        r.flags.store(0, Ordering::Relaxed);
        r.sequence
            .store(odd.wrapping_add(1).max(2), Ordering::Release);
    }
    /// The caller owns the outer image publication and validates the producer lease.
    pub fn write(&self, index: usize, epoch: u64, frame_index: u64, time: Time) -> bool {
        if !self.available() {
            return false;
        }
        let Some(r) = self.entries.get(index) else {
            return false;
        };
        if epoch == 0 || frame_index == 0 || !time.valid() {
            self.clear(index);
            return false;
        }
        let odd = r.sequence.load(Ordering::Relaxed) | 1;
        r.sequence.store(odd, Ordering::SeqCst);
        r.flags.store(VALID, Ordering::Relaxed);
        r.epoch.store(epoch, Ordering::Relaxed);
        r.frame_index.store(frame_index, Ordering::Relaxed);
        r.nanoseconds.store(time.nanoseconds, Ordering::Relaxed);
        r.clock_kind.store(time.clock_kind, Ordering::Relaxed);
        r.reserved.store(0, Ordering::Relaxed);
        r.sequence
            .store(odd.wrapping_add(1).max(2), Ordering::Release);
        true
    }
    pub fn read(&self, index: usize, epoch: u64, frame_index: u64) -> Option<Snapshot> {
        if !self.available() || epoch == 0 || frame_index == 0 {
            return None;
        }
        let r = self.entries.get(index)?;
        for _ in 0..8 {
            let seq = r.sequence.load(Ordering::Acquire);
            if seq == 0 || seq & 1 != 0 {
                continue;
            }
            let flags = r.flags.load(Ordering::Relaxed);
            let s = Snapshot {
                epoch: r.epoch.load(Ordering::Relaxed),
                frame_index: r.frame_index.load(Ordering::Relaxed),
                nanoseconds: r.nanoseconds.load(Ordering::Relaxed),
                clock_kind: r.clock_kind.load(Ordering::Relaxed),
                reserved: r.reserved.load(Ordering::Relaxed),
            };
            fence(Ordering::Acquire);
            if seq == r.sequence.load(Ordering::Relaxed) {
                if flags != VALID
                    || s.epoch != epoch
                    || s.frame_index != frame_index
                    || s.reserved != 0
                    || !(Time {
                        nanoseconds: s.nanoseconds,
                        clock_kind: s.clock_kind,
                    })
                    .valid()
                {
                    return None;
                }
                return Some(s);
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    fn memory() -> std::boxed::Box<[u64; HEADER_BYTES / 8]> {
        std::boxed::Box::new([0; HEADER_BYTES / 8])
    }
    #[test]
    fn frame_timing_layout_reserved_area_and_legacy_absence() {
        let mut bytes = memory();
        let h = bytes.as_mut_ptr().cast::<Header>();
        assert!(!unsafe { extension(h) }.available());
        unsafe { initialize(h) };
        assert!(unsafe { extension(h) }.available());
        assert_eq!(present_index(16), SLOTS);
        assert!(unsafe { extension(h) }.read(0, 1, 1).is_none());
        assert_eq!(core::mem::offset_of!(Snapshot, nanoseconds), 16);
        assert_eq!(OFFSET + core::mem::size_of::<Extension>(), 65480);
    }
    #[test]
    fn frame_timing_exact_epoch_frame_clock_and_clear() {
        let mut bytes = memory();
        let h = bytes.as_mut_ptr().cast::<Header>();
        unsafe { initialize(h) };
        let e = unsafe { extension(h) };
        let t = Time {
            nanoseconds: 1_000_000_000,
            clock_kind: XR_DISPLAY_TIME_NS,
        };
        assert!(e.write(0, 11, 5, t));
        assert_eq!(e.read(0, 11, 5).unwrap().nanoseconds, t.nanoseconds);
        assert!(e.read(0, 12, 5).is_none());
        assert!(e.read(0, 11, 6).is_none());
        for time in [
            Time {
                nanoseconds: 0,
                ..t
            },
            Time {
                nanoseconds: -1,
                ..t
            },
            Time { clock_kind: 0, ..t },
            Time {
                clock_kind: 99,
                ..t
            },
        ] {
            assert!(!e.write(0, 11, 5, time));
            assert!(e.read(0, 11, 5).is_none());
            assert!(e.write(0, 11, 5, t));
        }
        e.clear(0);
        assert!(e.read(0, 11, 5).is_none());
        assert!(!e.write(RECORDS, 11, 5, t));
    }
    #[test]
    fn frame_timing_rejects_busy_corrupt_and_preserves_present_independence() {
        let mut bytes = memory();
        let h = bytes.as_mut_ptr().cast::<Header>();
        unsafe { initialize(h) };
        let e = unsafe { extension(h) };
        let t = Time {
            nanoseconds: 123,
            clock_kind: SUBMIT_MONOTONIC_NS,
        };
        assert!(e.write(0, 7, 1, t));
        assert!(e.write(present_index(3), 7, 9, t));
        let r = &e.entries[0];
        let sequence = r.sequence.load(Ordering::Relaxed);
        r.sequence.store(sequence | 1, Ordering::Relaxed);
        assert!(e.read(0, 7, 1).is_none());
        assert!(e.read(present_index(3), 7, 9).is_some());
        r.sequence.store(sequence, Ordering::Relaxed);
        r.reserved.store(1, Ordering::Relaxed);
        assert!(e.read(0, 7, 1).is_none());
        r.reserved.store(0, Ordering::Relaxed);
        r.sequence.store(u32::MAX, Ordering::Relaxed);
        assert!(e.write(0, 7, 2, t));
        assert!(e.read(0, 7, 2).is_some());
        assert!(e.write(present_index(19), 7, 10, t));
        assert!(e.read(present_index(3), 7, 9).is_none());
    }
}
