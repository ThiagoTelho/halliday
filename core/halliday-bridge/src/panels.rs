//! Optional per-frame OpenXR panel metadata in unused v6 header bytes.
//! Pixels use the existing picture pool; sequence and epoch tie them to a frame.
use crate::{HEADER_BYTES, Header, OVERLAYS, Pose, SLOTS};
use core::sync::atomic::{AtomicU32, AtomicU64, Ordering, fence};

pub const OFFSET: usize = 61568;
pub const MAGIC: u32 = u32::from_le_bytes(*b"HLQP");
pub const VERSION: u32 = 1;
pub const NONE: u32 = u32::MAX;
pub const SOURCE_ALPHA: u32 = 1;
pub const UNPREMULTIPLIED: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Panel {
    pub pose: Pose,
    pub width_m: f32,
    pub height_m: f32,
    /// 0 both, 1 left, 2 right.
    pub eye_visibility: u32,
    pub flags: u32,
    pub order: u32,
    pub picture_index: u32,
    pub picture_seq: u32,
    pub color_space: u32,
    pub bgra: u32,
    /// 0 in host floor coordinates, 1 relative to the viewer's head.
    pub anchor: u32,
}
const WORDS: usize = 26;
#[repr(C)]
pub struct Batch {
    sequence: AtomicU32,
    count: AtomicU32,
    frame_index: AtomicU64,
    epoch: AtomicU64,
    projection_order: AtomicU32,
    projection_flags: AtomicU32,
    panels: [[AtomicU32; WORDS]; OVERLAYS],
}
#[repr(C)]
pub struct Extension {
    magic: u32,
    version: u32,
    _reserved: [u32; 2],
    batches: [Batch; SLOTS],
}
#[derive(Clone, Copy, Debug)]
pub struct Snapshot {
    pub epoch: u64,
    pub frame_index: u64,
    pub count: usize,
    pub projection_order: u32,
    pub projection_flags: u32,
    pub panels: [Panel; OVERLAYS],
}
const _: () = assert!(core::mem::size_of::<Panel>() == 104);
const _: () = assert!(core::mem::offset_of!(Header, overlay_pictures) == 4460);
const _: () = assert!(core::mem::size_of::<Batch>() == 864);
const _: () = assert!(core::mem::size_of::<Extension>() == 2608);
const _: () = assert!(OFFSET >= crate::haptics::OFFSET + 112);
const _: () = assert!(OFFSET + core::mem::size_of::<Extension>() <= HEADER_BYTES);

/// # Safety
/// `header` maps the entire v6 header.
pub unsafe fn extension<'a>(header: *const Header) -> &'a Extension {
    unsafe { &*header.cast::<u8>().add(OFFSET).cast::<Extension>() }
}
/// # Safety
/// Only the host initializes its fresh, unpublished mapping.
pub unsafe fn initialize(header: *mut Header) {
    let ptr = unsafe { header.cast::<u8>().add(OFFSET).cast::<Extension>() };
    unsafe {
        (*ptr).version = VERSION;
        (*ptr).magic = MAGIC;
    }
}
impl Panel {
    pub fn valid(&self) -> bool {
        self.width_m.is_finite()
            && self.width_m > 0.0
            && self.height_m.is_finite()
            && self.height_m > 0.0
            && self.eye_visibility <= 2
            && self.flags & !3 == 0
            && self.anchor <= 1
            && self.color_space <= 2
            && self.bgra <= 1
            && self.picture_index < OVERLAYS as u32
            && self.order < (OVERLAYS + 1) as u32
            && self.pose.position.iter().all(|v| v.is_finite())
            && self.pose.orientation.iter().all(|v| v.is_finite())
            && (0.98..=1.02).contains(&self.pose.orientation.iter().map(|v| v * v).sum::<f32>())
    }
}
impl Extension {
    pub fn available(&self) -> bool {
        self.magic == MAGIC && self.version == VERSION
    }
    pub fn write(
        &self,
        slot: usize,
        epoch: u64,
        frame_index: u64,
        projection_order: u32,
        projection_flags: u32,
        panels: &[Panel],
    ) -> bool {
        if !self.available()
            || slot >= SLOTS
            || epoch == 0
            || frame_index == 0
            || panels.len() > OVERLAYS
            || projection_flags & !3 != 0
            || (projection_order != NONE && projection_order > OVERLAYS as u32)
            || panels
                .iter()
                .any(|p| !p.valid() || p.picture_seq == 0 || p.picture_seq & 1 != 0)
        {
            return false;
        }
        let mut pictures = 0u32;
        let mut orders = if projection_order == NONE {
            0
        } else {
            1 << projection_order
        };
        for panel in panels {
            let picture = 1 << panel.picture_index;
            let order = 1 << panel.order;
            if pictures & picture != 0 || orders & order != 0 {
                return false;
            }
            pictures |= picture;
            orders |= order;
        }
        let batch = &self.batches[slot];
        let seq = batch.sequence.load(Ordering::Relaxed) | 1;
        batch.sequence.store(seq, Ordering::SeqCst);
        batch.count.store(panels.len() as u32, Ordering::Relaxed);
        batch.frame_index.store(frame_index, Ordering::Relaxed);
        batch.epoch.store(epoch, Ordering::Relaxed);
        batch
            .projection_order
            .store(projection_order, Ordering::Relaxed);
        batch
            .projection_flags
            .store(projection_flags, Ordering::Relaxed);
        for (target, source) in batch.panels.iter().zip(panels) {
            // All fields are f32/u32 without padding or invalid bit patterns.
            let words: [u32; WORDS] = unsafe { core::mem::transmute(*source) };
            for (target, word) in target.iter().zip(words) {
                target.store(word, Ordering::Relaxed);
            }
        }
        batch
            .sequence
            .store(seq.wrapping_add(1).max(2), Ordering::Release);
        true
    }
    pub fn read(&self, slot: usize, epoch: u64, frame_index: u64) -> Option<Snapshot> {
        if !self.available() || epoch == 0 || frame_index == 0 {
            return None;
        }
        let batch = self.batches.get(slot)?;
        for _ in 0..8 {
            let seq = batch.sequence.load(Ordering::Acquire);
            if seq == 0 || seq & 1 != 0 {
                continue;
            }
            let count = batch.count.load(Ordering::Relaxed) as usize;
            if count > OVERLAYS {
                return None;
            }
            let mut out = Snapshot {
                epoch: batch.epoch.load(Ordering::Relaxed),
                frame_index: batch.frame_index.load(Ordering::Relaxed),
                count,
                projection_order: batch.projection_order.load(Ordering::Relaxed),
                projection_flags: batch.projection_flags.load(Ordering::Relaxed),
                panels: [Panel::default(); OVERLAYS],
            };
            for (target, source) in out.panels.iter_mut().zip(&batch.panels).take(count) {
                let words =
                    core::array::from_fn::<u32, WORDS, _>(|i| source[i].load(Ordering::Relaxed));
                *target = unsafe { core::mem::transmute::<[u32; WORDS], Panel>(words) };
            }
            fence(Ordering::Acquire);
            if seq == batch.sequence.load(Ordering::Relaxed) {
                if out.epoch != epoch
                    || out.frame_index != frame_index
                    || out.projection_flags & !3 != 0
                    || (out.projection_order != NONE && out.projection_order > OVERLAYS as u32)
                {
                    return None;
                }
                let mut pictures = 0u32;
                let mut orders = if out.projection_order == NONE {
                    0
                } else {
                    1 << out.projection_order
                };
                for panel in &out.panels[..count] {
                    if !panel.valid() || panel.picture_seq == 0 || panel.picture_seq & 1 != 0 {
                        return None;
                    }
                    let picture = 1 << panel.picture_index;
                    let order = 1 << panel.order;
                    if pictures & picture != 0 || orders & order != 0 {
                        return None;
                    }
                    pictures |= picture;
                    orders |= order;
                }
                return Some(out);
            }
        }
        None
    }
}
