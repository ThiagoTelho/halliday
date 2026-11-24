//! Optional complete projection geometry, associated with one exact v6 frame.
//! Canonical tangents describe the pixels after any producer-side view mirroring.
use crate::{HEADER_BYTES, Header, SLOTS};
use core::sync::atomic::{AtomicU32, AtomicU64, Ordering, fence};

pub const OFFSET: usize = 64256;
pub const MAGIC: u32 = u32::from_le_bytes(*b"HLPG");
pub const VERSION: u32 = 1;
pub const VALID: u32 = 1;
const WORDS: usize = 11;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct View {
    pub position: [f32; 3],
    /// Quaternion in x,y,z,w order, in the host's floor-aligned coordinates.
    pub orientation: [f32; 4],
    /// Left, right, up, down; these may be asymmetric or all on one side.
    pub tangents: [f32; 4],
}
#[repr(C)]
pub struct Record {
    pub sequence: AtomicU32,
    pub flags: AtomicU32,
    pub frame_index: AtomicU64,
    pub epoch: AtomicU64,
    pub views: [[AtomicU32; WORDS]; 2],
}
#[repr(C)]
pub struct Extension {
    pub magic: u32,
    pub version: u32,
    pub record_bytes: u32,
    pub slots: u32,
    pub records: [Record; SLOTS],
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Snapshot {
    pub epoch: u64,
    pub frame_index: u64,
    pub views: [View; 2],
}
const _: () = assert!(core::mem::size_of::<View>() == 44);
const _: () = assert!(core::mem::size_of::<Record>() == 112);
const _: () = assert!(core::mem::offset_of!(Record, views) == 24);
const _: () = assert!(core::mem::size_of::<Extension>() == 352);
const _: () = assert!(core::mem::size_of::<Snapshot>() == 104);
const _: () =
    assert!(OFFSET >= crate::focus::OFFSET + core::mem::size_of::<crate::focus::Extension>());
const _: () = assert!(OFFSET + core::mem::size_of::<Extension>() <= HEADER_BYTES);

impl View {
    pub fn valid(&self) -> bool {
        self.position.iter().all(|v| v.is_finite())
            && self.orientation.iter().all(|v| v.is_finite())
            && (0.98..=1.02).contains(&self.orientation.iter().map(|v| v * v).sum::<f32>())
            && self.tangents.iter().all(|v| v.is_finite())
            && self.tangents[1] > self.tangents[0]
            && self.tangents[2] > self.tangents[3]
            && (self.tangents[1] - self.tangents[0]).is_finite()
            && (self.tangents[2] - self.tangents[3]).is_finite()
    }
}

/// # Safety
/// `header` maps the entire v6 header, including its reserved bytes.
pub unsafe fn extension<'a>(header: *const Header) -> &'a Extension {
    unsafe { &*header.cast::<u8>().add(OFFSET).cast::<Extension>() }
}
/// # Safety
/// Only the host initializes its fresh, unpublished mapping.
pub unsafe fn initialize(header: *mut Header) {
    let ext = unsafe { header.cast::<u8>().add(OFFSET).cast::<Extension>() };
    unsafe {
        (*ext).version = VERSION;
        (*ext).record_bytes = core::mem::size_of::<Record>() as u32;
        (*ext).slots = SLOTS as u32;
        (*ext).magic = MAGIC;
    }
}
impl Extension {
    pub fn available(&self) -> bool {
        self.magic == MAGIC
            && self.version == VERSION
            && self.record_bytes == core::mem::size_of::<Record>() as u32
            && self.slots == SLOTS as u32
    }
    pub fn write(&self, slot: usize, epoch: u64, frame_index: u64, views: &[View; 2]) -> bool {
        if !self.available()
            || slot >= SLOTS
            || epoch == 0
            || frame_index == 0
            || views.iter().any(|v| !v.valid())
        {
            return false;
        }
        let record = &self.records[slot];
        let odd = record.sequence.load(Ordering::Relaxed) | 1;
        record.sequence.store(odd, Ordering::SeqCst);
        record.flags.store(VALID, Ordering::Relaxed);
        record.frame_index.store(frame_index, Ordering::Relaxed);
        record.epoch.store(epoch, Ordering::Relaxed);
        for (target, source) in record.views.iter().zip(views) {
            // View consists only of eleven f32 words, without padding.
            let words: [u32; WORDS] = unsafe { core::mem::transmute(*source) };
            for (target, value) in target.iter().zip(words) {
                target.store(value, Ordering::Relaxed);
            }
        }
        record
            .sequence
            .store(odd.wrapping_add(1).max(2), Ordering::Release);
        true
    }
    pub fn read(&self, slot: usize, epoch: u64, frame_index: u64) -> Option<Snapshot> {
        if !self.available() || epoch == 0 || frame_index == 0 {
            return None;
        }
        let record = self.records.get(slot)?;
        for _ in 0..8 {
            let sequence = record.sequence.load(Ordering::Acquire);
            if sequence == 0 || sequence & 1 != 0 {
                continue;
            }
            let flags = record.flags.load(Ordering::Relaxed);
            let mut out = Snapshot {
                epoch: record.epoch.load(Ordering::Relaxed),
                frame_index: record.frame_index.load(Ordering::Relaxed),
                views: [View::default(); 2],
            };
            for (target, source) in out.views.iter_mut().zip(&record.views) {
                let words =
                    core::array::from_fn::<u32, WORDS, _>(|i| source[i].load(Ordering::Relaxed));
                *target = unsafe { core::mem::transmute::<[u32; WORDS], View>(words) };
            }
            fence(Ordering::Acquire);
            if sequence == record.sequence.load(Ordering::Relaxed) {
                if flags != VALID
                    || out.epoch != epoch
                    || out.frame_index != frame_index
                    || out.views.iter().any(|v| !v.valid())
                {
                    return None;
                }
                return Some(out);
            }
        }
        None
    }
}
