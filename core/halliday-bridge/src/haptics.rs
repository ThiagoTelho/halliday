//! Optional haptic mailbox in v6's reserved header area. Old producers ignore it.
//! Atomics keep all payload reads defined while a producer replaces a command.
use crate::Header;
use core::sync::atomic::{AtomicU32, AtomicU64, Ordering};

pub const OFFSET: usize = 60 * 1024;
pub const MAGIC: u32 = u32::from_le_bytes(*b"HLHP");
pub const VERSION: u32 = 1;
#[repr(C)]
pub struct Mailbox {
    pub sequence: AtomicU32,
    pub amplitude: AtomicU32,
    pub frequency: AtomicU32,
    pub pad: AtomicU32,
    pub duration_ns: AtomicU64,
    pub issued_ns: AtomicU64,
    pub epoch: AtomicU64,
}
#[repr(C)]
pub struct Extension {
    pub magic: u32,
    pub version: u32,
    pub clock_ns: AtomicU64,
    pub client_epoch: AtomicU64,
    pub owner_pid: AtomicU32,
    /// Host increments only when its published reference coordinates change.
    pub space_epoch: AtomicU32,
    pub hands: [Mailbox; 2],
}
#[derive(Clone, Copy, Debug)]
pub struct Request {
    pub sequence: u32,
    pub amplitude: f32,
    pub frequency: f32,
    pub duration_ns: u64,
    pub issued_ns: u64,
    pub epoch: u64,
}
const _: () = assert!(core::mem::size_of::<Extension>() == 112);
const _: () = assert!(core::mem::offset_of!(Extension, space_epoch) == 28);
const _: () = assert!(core::mem::offset_of!(Extension, hands) == 32);
const _: () = assert!(core::mem::offset_of!(Mailbox, duration_ns) == 16);
const _: () = assert!(core::mem::offset_of!(Mailbox, issued_ns) == 24);
const _: () = assert!(core::mem::offset_of!(Mailbox, epoch) == 32);
const _: () = assert!(core::mem::size_of::<Header>() <= OFFSET);
const _: () = assert!(OFFSET + core::mem::size_of::<Extension>() <= crate::HEADER_BYTES);

/// # Safety
/// `header` maps the whole v6 bridge, including its reserved header bytes.
pub unsafe fn extension<'a>(header: *const Header) -> &'a Extension {
    unsafe { &*header.cast::<u8>().add(OFFSET).cast::<Extension>() }
}
/// # Safety
/// The host exclusively initializes a zeroed bridge before publishing its magic.
pub unsafe fn initialize(header: *mut Header, now: u64) {
    let ext = unsafe { header.cast::<u8>().add(OFFSET).cast::<Extension>() };
    unsafe {
        (*ext).version = VERSION;
        (*ext).clock_ns.store(now.max(1), Ordering::SeqCst);
        (*ext).magic = MAGIC;
    }
}
impl Extension {
    pub fn available(&self) -> bool {
        self.magic == MAGIC && self.version == VERSION
    }
    pub fn begin(&self, pid: u32, epoch: u64) -> bool {
        if !self.available() || epoch == 0 {
            return false;
        }
        self.client_epoch.store(0, Ordering::SeqCst);
        self.owner_pid.store(pid, Ordering::SeqCst);
        for slot in &self.hands {
            slot.sequence.store(0, Ordering::SeqCst);
            slot.epoch.store(0, Ordering::SeqCst);
        }
        self.client_epoch.store(epoch, Ordering::SeqCst);
        true
    }
    pub fn end(&self, epoch: u64) {
        let _ = self
            .client_epoch
            .compare_exchange(epoch, 0, Ordering::SeqCst, Ordering::SeqCst);
    }
    pub fn write(
        &self,
        epoch: u64,
        hand: usize,
        duration: u64,
        frequency: f32,
        amplitude: f32,
    ) -> bool {
        self.write_tagged(epoch, hand, duration, frequency, amplitude, None)
    }
    pub fn write_tagged(
        &self,
        epoch: u64,
        hand: usize,
        duration: u64,
        frequency: f32,
        amplitude: f32,
        focus: Option<(&crate::focus::Extension, u32)>,
    ) -> bool {
        if !self.available()
            || hand > 1
            || epoch == 0
            || self.client_epoch.load(Ordering::SeqCst) != epoch
            || !amplitude.is_finite()
            || !(0.0..=1.0).contains(&amplitude)
            || !frequency.is_finite()
            || frequency < 0.0
            || duration > i64::MAX as u64
        {
            return false;
        }
        let now = self.clock_ns.load(Ordering::SeqCst);
        if now == 0 && duration != 0 && amplitude != 0.0 {
            return false;
        }
        let slot = &self.hands[hand];
        let seq = slot.sequence.load(Ordering::Acquire);
        if seq & 1 != 0
            || slot
                .sequence
                .compare_exchange(
                    seq,
                    seq.wrapping_add(1),
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_err()
        {
            return false;
        }
        slot.amplitude.store(amplitude.to_bits(), Ordering::Relaxed);
        slot.frequency.store(frequency.to_bits(), Ordering::Relaxed);
        slot.duration_ns.store(duration, Ordering::Relaxed);
        slot.issued_ns.store(now, Ordering::Relaxed);
        slot.epoch.store(epoch, Ordering::Relaxed);
        if let Some((focus, generation)) = focus {
            focus.tag(epoch, hand, seq.wrapping_add(2), generation);
        }
        slot.sequence.store(seq.wrapping_add(2), Ordering::Release);
        true
    }
    pub fn read(&self, hand: usize) -> Option<Request> {
        let slot = self.hands.get(hand)?;
        for _ in 0..8 {
            let seq = slot.sequence.load(Ordering::Acquire);
            if seq & 1 != 0 {
                continue;
            }
            let request = Request {
                sequence: seq,
                amplitude: f32::from_bits(slot.amplitude.load(Ordering::Relaxed)),
                frequency: f32::from_bits(slot.frequency.load(Ordering::Relaxed)),
                duration_ns: slot.duration_ns.load(Ordering::Relaxed),
                issued_ns: slot.issued_ns.load(Ordering::Relaxed),
                epoch: slot.epoch.load(Ordering::Relaxed),
            };
            core::sync::atomic::fence(Ordering::Acquire);
            if seq == slot.sequence.load(Ordering::Relaxed) {
                return Some(request);
            }
        }
        None
    }
}
