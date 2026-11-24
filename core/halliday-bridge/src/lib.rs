//! The memory Halliday shares with a VR game running under Wine (ROADMAP W14).
//!
//! Halliday.app creates one file, `halliday-bridge.shm`, next to its OpenVR runtime
//! (`Application Support/Halliday/OpenVR/`), and maps it. The game loads Halliday's
//! `vrclient_x64.dll` (crate `halliday-vrclient`), which maps the same file through Wine: Wine backs
//! a Windows file mapping of a real file with the host's `mmap`, so both sides see the same pages
//! and no socket or network is involved.
//!
//! - Halliday writes the configuration once (render size, field of view, refresh rate), then every
//!   display frame the head and controller state under a sequence lock and bumps `vsync_count`.
//! - The game side writes each frame's two eye images into one of [`SLOTS`] slots, with the head
//!   pose it rendered from, and publishes the slot in `latest`. It never writes the slot Halliday
//!   marks in `reading`, nor the one in `latest`.
//! - The game side also describes what SteamVR's compositor would show besides its frames: up to
//!   [`OVERLAYS`] overlays (loading screens, menus), a skybox for while it loads, and fades; and
//!   it beats a heartbeat while it runs. Halliday asks it to quit, tells it when Halliday's own
//!   interface is over it, and reports how often its frames came late.
//! - Frames may also come another way, without the copy into this file (W14.9,
//!   docs/research/zero-copy-frames.md): the game side presents them to a window on a display
//!   Halliday made for that ([`Header::present_origin`]), [`PRESENT_BAND`] rows of frame number
//!   above the image, and Halliday captures the window. The number finds the frame's pose in
//!   [`Header::present_frames`].
//!
//! Both sides are little-endian and agree on `repr(C)` layout: the Windows side is x86_64 (under
//! Rosetta), Halliday arm64. Types here have the same size and alignment on both.

#![no_std]

pub mod focus;
pub mod glsl;
pub mod haptics;
pub mod math;
pub mod motion;
pub mod frame_timing;
pub mod producer_lease;
pub mod panels;
pub mod picture;
pub mod projection;

use core::sync::atomic::{AtomicU32, AtomicU64, Ordering, fence};

/// "HLBR".
pub const MAGIC: u32 = u32::from_le_bytes(*b"HLBR");
/// Bumped on any change to the layout below.
pub const VERSION: u32 = 6;
/// `Frame::texture_type` keeps its historical API in the low byte. Optional per-eye
/// transfer tags use previously unused upper bits, without changing the v6 layout.
pub const FRAME_TEXTURE_API_MASK: u32 = 0xff;
/// The exact projection geometry must be read before showing this frame.
pub const FRAME_PROJECTION_GEOMETRY: u32 = 1 << 16;
/// Ordered layers, source alpha or an explicit empty frame require their batch.
pub const FRAME_LAYER_BATCH: u32 = 1 << 17;
/// Optional paired producer timing. Failure invalidates timing, never the real pixels.
pub const FRAME_SOURCE_TIMING: u32 = 1 << 18;
pub const FRAME_COLOR_LEGACY: u32 = 0;
pub const FRAME_COLOR_LINEAR: u32 = 1;
pub const FRAME_COLOR_SRGB: u32 = 2;

pub const fn frame_texture_metadata(api: u32, left: u32, right: u32) -> u32 {
    (api & FRAME_TEXTURE_API_MASK) | ((left & 3) << 8) | ((right & 3) << 10)
}

/// Unknown tags are treated like old untagged producers, rather than guessing a curve.
pub const fn frame_color_space(metadata: u32, eye: usize) -> u32 {
    if eye > 1 {
        return FRAME_COLOR_LEGACY;
    }
    let value = (metadata >> (8 + eye * 2)) & 3;
    if value <= FRAME_COLOR_SRGB {
        value
    } else {
        FRAME_COLOR_LEGACY
    }
}
/// The shared file's name, in the runtime folder (the parent of the DLL's `bin` folder).
pub const FILE_NAME: &str = "halliday-bridge.shm";

/// Largest side of an image a slot takes (RGBA8); its area is limited by [`EYE_BYTES`].
pub const MAX_IMAGE_SIDE: u32 = 4096;
/// Frames in flight: one being written, one being read, one ready.
pub const SLOTS: usize = 3;
/// Bytes of one eye's image area (2560 × 2560 RGBA8; a multiple of the 16 KiB page). A game that
/// renders both eyes into one texture (the OpenGL game: 2880 × 1468) fits in one area.
pub const EYE_BYTES: usize = 2560 * 2560 * 4;

/// An image both eyes share (one texture, side by side) may also take the right eye's area, which
/// follows the left's: twice the room.
pub const fn fits_shared(width: u32, height: u32) -> bool {
    width > 0
        && height > 0
        && width <= MAX_IMAGE_SIDE
        && height <= MAX_IMAGE_SIDE
        && (width as usize) * (height as usize) * 4 <= 2 * EYE_BYTES
}

/// An image of `width` × `height` RGBA8 fits in one eye's area.
pub const fn fits(width: u32, height: u32) -> bool {
    width > 0
        && height > 0
        && width <= MAX_IMAGE_SIDE
        && height <= MAX_IMAGE_SIDE
        && (width as usize) * (height as usize) * 4 <= EYE_BYTES
}
/// Bytes before the first image (the header, padded to whole pages).
pub const HEADER_BYTES: usize = 64 * 1024;

/// Overlays a game may have at once (OpenVR's `IVROverlay`: loading screens, menus).
pub const OVERLAYS: usize = 8;
/// Largest side of an overlay's picture: a larger texture is scaled down as it is copied.
pub const OVERLAY_SIDE: u32 = 2048;
/// Bytes of one overlay's picture area.
pub const OVERLAY_BYTES: usize = (OVERLAY_SIDE * OVERLAY_SIDE * 4) as usize;
/// The skybox (`IVRCompositor::SetSkyboxOverride`) as one equirectangular picture per eye,
/// [`SKYBOX_WIDTH`] × [`SKYBOX_WIDTH`] / 2, the right eye's under the left's when it differs.
pub const SKYBOX_WIDTH: u32 = 2048;
pub const SKYBOX_BYTES: usize = (SKYBOX_WIDTH * SKYBOX_WIDTH * 4) as usize;

/// The whole file (sparse: pages nobody writes take no room).
pub const FILE_BYTES: usize =
    HEADER_BYTES + SLOTS * 2 * EYE_BYTES + OVERLAYS * OVERLAY_BYTES + SKYBOX_BYTES;

/// Where one eye's image of one slot starts in the file.
pub const fn image_offset(slot: usize, eye: usize) -> usize {
    HEADER_BYTES + (slot * 2 + eye) * EYE_BYTES
}

/// Where overlay `i`'s picture starts in the file.
pub const fn overlay_offset(i: usize) -> usize {
    HEADER_BYTES + SLOTS * 2 * EYE_BYTES + i * OVERLAY_BYTES
}

/// Where the skybox's picture starts in the file.
pub const fn skybox_offset() -> usize {
    HEADER_BYTES + SLOTS * 2 * EYE_BYTES + OVERLAYS * OVERLAY_BYTES
}

/// A pose in Halliday's (and OpenVR's standing) space: meters, +y up, -z forward, the floor at
/// y = 0. Orientation as a quaternion (x, y, z, w).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Pose {
    pub position: [f32; 3],
    pub valid: u32,
    pub orientation: [f32; 4],
    pub velocity: [f32; 3],
    pub _pad0: f32,
    pub angular_velocity: [f32; 3],
    /// Halliday's number for the state this pose came from (the head's, counting from 1, mod
    /// 2^24 so that an `f32` holds it exactly); the game side passes it through, so Halliday can
    /// tell how old a frame's pose is when it shows the frame. 0: none.
    pub stamp: f32,
}

/// A controller as OpenVR's legacy input sees it (`VRControllerState_t` plus a pose).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Controller {
    pub pose: Pose,
    /// Bit `1 << EVRButtonId`.
    pub pressed: u64,
    pub touched: u64,
    /// Axis 0: touchpad (x, y in -1..1); axis 1: trigger (x in 0..1).
    pub axes: [[f32; 2]; 5],
    pub connected: u32,
    /// Changes whenever the state does (OpenVR's `unPacketNum`).
    pub packet: u32,
}

/// What changes every display frame, written by Halliday.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct State {
    pub head: Pose,
    /// 0: left hand, 1: right hand.
    pub controllers: [Controller; 2],
}

/// One frame of the game's, written by the game side.
#[repr(C)]
#[derive(Debug)]
pub struct Frame {
    /// Odd while the game side writes the slot.
    pub seq: AtomicU32,
    /// Size of each eye's image in the slot (pixels; rows of `width * 4` bytes).
    pub width: u32,
    pub height: u32,
    /// 1: rows bottom-up (an OpenGL texture), 0: top-down.
    pub bottom_up: u32,
    /// Each eye's part of its image (u min, v min, u max, v max, as OpenVR's `VRTextureBounds_t`).
    pub bounds: [[f32; 4]; 2],
    /// The head pose the frame was rendered from.
    pub pose: Pose,
    pub frame_index: u64,
    /// Low byte: OpenVR texture type (0: D3D11, 1: OpenGL, 4: D3D12).
    /// Bits 8..9 / 10..11: left/right transfer tag; 0 legacy, 1 linear, 2 sRGB.
    /// Untagged OpenVR and native producers retain their historical appearance.
    pub texture_type: u32,
    /// 1: both eyes were submitted from the same texture, copied once into the left eye's area
    /// (the bounds tell the halves apart).
    pub shared: u32,
    /// 1: pixels are B, G, R, A (Direct3D's BGRA formats); 0: R, G, B, A.
    pub bgra: u32,
    /// 1: the picture's alpha is meant (premultiplied): where it is clear the application wants
    /// the room to show, not black (an OpenXR application's passthrough under its scene).
    pub see_through: u32,
}

/// A picture the game side replaces now and then (an overlay's, the skybox): RGBA8, rows
/// top-down, `width * 4` bytes each, premultiplied alpha.
///
/// The game side makes `seq` odd, waits while Halliday has `reading` set, writes, and makes `seq`
/// even again ([`begin_picture`], [`end_picture`]). Halliday reads a picture only between those:
/// it sets `reading`, checks `seq` is the even value it saw, copies, and clears `reading`.
#[repr(C)]
#[derive(Debug)]
pub struct Picture {
    pub seq: AtomicU32,
    pub reading: AtomicU32,
    pub width: AtomicU32,
    pub height: AtomicU32,
}

/// One of the game's overlays: a flat picture in the room, or following the head or a hand.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Overlay {
    /// 1: the game created it.
    pub used: u32,
    pub visible: u32,
    /// 0: placed in the room (standing space); 1: relative to tracked device `device` (0 the
    /// head, 1 the left hand, 2 the right).
    pub relative: u32,
    pub device: u32,
    /// Higher is drawn over lower.
    pub sort_order: u32,
    /// 1: it takes the mouse (`VROverlayInputMethod_Mouse`): Halliday points at it with the
    /// hands ([`Header::pointer`]).
    pub input: u32,
    /// The overlay's pose, rows of a 3 × 4 matrix (OpenVR's `HmdMatrix34_t`): the picture lies in
    /// its x-y plane, centered, its front facing +z.
    pub transform: [[f32; 4]; 3],
    pub width_m: f32,
    pub alpha: f32,
    /// Tint, multiplied in.
    pub color: [f32; 3],
    /// Width / height of one texel (1: square).
    pub texel_aspect: f32,
    /// The picture's part shown (u min, v min, u max, v max).
    pub bounds: [f32; 4],
    /// The game's name for it (`SetOverlayKey`'s key), for logs; UTF-8, NUL-padded.
    pub key: [u8; 64],
    /// A file to show instead of the picture (`SetOverlayFromFile`): a Unix path, UTF-8,
    /// NUL-padded; empty: none.
    pub file: [u8; 256],
}

impl Overlay {
    pub const NONE: Overlay = Overlay {
        used: 0,
        visible: 0,
        relative: 0,
        device: 0,
        sort_order: 0,
        input: 0,
        transform: [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
        ],
        width_m: 1.0,
        alpha: 1.0,
        color: [1.0; 3],
        texel_aspect: 1.0,
        bounds: [0.0, 0.0, 1.0, 1.0],
        key: [0; 64],
        file: [0; 256],
    };
}

/// What SteamVR's compositor shows besides the game's frames, as the game asked for it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Scene {
    /// `FadeToColor`: the color over the game's frames (premultiplied: alpha 0 is no fade) and how
    /// long to get there; with `bBackground`, over the compositor's place (skybox, grid) instead.
    /// Overlays are never faded (a game shows its loading screen over a faded scene).
    pub fade_color: [f32; 4],
    pub background_color: [f32; 4],
    pub fade_seconds: f32,
    pub background_seconds: f32,
    /// `FadeGrid`: 1 shows the compositor's own place (Halliday's) instead of the game's frames.
    pub grid: u32,
    pub grid_seconds: f32,
    /// `SuspendRendering(true)`: the game stopped drawing on purpose.
    pub suspended: u32,
    /// 0: no skybox; 1: one picture for both eyes; 2: a stereo pair (left over right).
    pub skybox: u32,
    pub _pad: u32,
}

/// Rows above a window frame's image holding its number: 32 squares of
/// [`PRESENT_BAND`] × [`PRESENT_BAND`] pixels from the left, bit 0 first, white for 1.
pub const PRESENT_BAND: u32 = 8;
/// Frames whose pose Halliday can still look up by number.
pub const PRESENT_RING: usize = 16;
/// The title of the window frames are presented to, followed by the game's process id.
pub const PRESENT_TITLE: &str = "Halliday frames ";

/// `Header::present_state`.
pub mod present {
    /// The game side doesn't present frames to a window.
    pub const OFF: u32 = 0;
    /// It does, and copies them into the bridge too, until Halliday captures the window.
    pub const STARTING: u32 = 1;
    /// Frames only through the window.
    pub const ON: u32 = 2;
    /// It tried and gave up (the reason is in its log): copies only.
    pub const FAILED: u32 = 3;
}

/// A frame presented to the window: what Halliday needs besides its pixels. The image below the
/// band is both eyes side by side, each `eye_width` × `eye_height`, rows top-down.
#[repr(C)]
#[derive(Debug)]
pub struct PresentFrame {
    /// The frame's number in the band (from 1); [`PRESENT_BUSY`] while the record is written.
    pub number: AtomicU32,
    pub eye_width: u32,
    pub eye_height: u32,
    /// 1: the image is upside down (Halliday flips it when it shows it).
    pub flipped: u32,
    /// The same counter as [`Frame::frame_index`].
    pub frame_index: u64,
    /// OpenVR texture type the game submitted (0: Direct3D 11, 1: OpenGL).
    pub texture_type: u32,
    pub _pad: u32,
    pub pose: Pose,
}

pub const PRESENT_BUSY: u32 = u32::MAX;

/// The values of a [`PresentFrame`].
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PresentInfo {
    pub number: u32,
    pub eye_width: u32,
    pub eye_height: u32,
    pub flipped: bool,
    pub frame_index: u64,
    pub texture_type: u32,
    pub pose: Pose,
}

/// The start of the file.
#[repr(C)]
#[derive(Debug)]
pub struct Header {
    pub magic: u32,
    pub version: u32,
    /// Size the game should render each eye at.
    pub eye_width: u32,
    pub eye_height: u32,
    pub display_hz: f32,
    pub ipd: f32,
    /// Per eye: tangents of the left, right, up and down edges (OpenXR signs: left and down negative).
    pub tangents: [[f32; 4]; 2],

    /// Set while Halliday runs with the file mapped.
    pub halliday_alive: AtomicU32,
    /// Sequence lock over `state` (odd while Halliday writes it).
    pub state_seq: AtomicU32,
    /// One more every display frame.
    pub vsync_count: AtomicU64,
    pub state: State,

    /// Written by the game side: one more every submitted frame.
    pub client_frames: AtomicU64,
    /// One more on every call the game makes into the runtime (a sign of life while it loads).
    pub client_calls: AtomicU64,
    pub client_pid: u32,
    /// Slot + 1 of the newest complete frame (0: none yet).
    pub latest: AtomicU32,
    /// Slot + 1 Halliday is copying from (0: none).
    pub reading: AtomicU32,
    pub _pad: u32,
    /// The game's executable name (UTF-8, NUL-padded).
    pub app_name: [u8; 64],
    pub frames: [Frame; SLOTS],

    // --- Halliday → game ---
    /// Halliday's display period, measured (ns; 0: not known yet).
    pub frame_interval_ns: AtomicU64,
    /// Display frames that showed an older game frame again because no new one had come.
    pub late_vsyncs: AtomicU64,
    /// One more each time Halliday asks the game to quit (its own quit, the user's choice).
    pub quit_requests: AtomicU32,
    /// 1 while Halliday's own interface is over the game (SteamVR's dashboard).
    pub dashboard: AtomicU32,

    // --- game → Halliday ---
    /// One more about every 250 ms while the runtime is loaded in a game (while it loads too).
    pub client_heartbeat: AtomicU64,
    /// 1 between the game's VR_Init and VR_Shutdown.
    pub client_initialized: AtomicU32,
    /// One more when the game acknowledged a quit request.
    pub quit_acknowledged: AtomicU32,
    /// Sequence lock over `scene` and `overlays` (odd while the game side writes them).
    pub scene_seq: AtomicU32,
    pub _pad2: u32,
    pub scene: Scene,
    pub overlays: [Overlay; OVERLAYS],
    pub overlay_pictures: [Picture; OVERLAYS],
    pub skybox_picture: Picture,

    // --- frames through a window (W14.9) ---
    /// Halliday → game: 1 while Halliday can capture a window of frames (its display is up and it
    /// may record the screen).
    pub present_enabled: AtomicU32,
    /// Halliday → game: the number of the newest window frame Halliday captured.
    pub present_seen: AtomicU32,
    /// Halliday → game: where the window goes, in Windows' screen coordinates (Wine's: the Mac's
    /// global points, the main display's top-left at 0, 0).
    pub present_origin: [i32; 2],
    /// Game → Halliday: [`present`]'s values.
    pub present_state: AtomicU32,
    /// Game → Halliday: the window's size in pixels (band included); 0 before it exists.
    pub present_width: AtomicU32,
    pub present_height: AtomicU32,
    pub _pad3: u32,
    /// Game → Halliday: the latest window frames, at `number % PRESENT_RING`.
    pub present_frames: [PresentFrame; PRESENT_RING],

    // --- pointing at the game's overlays (W14.11) ---
    /// Halliday → game: where a hand points at an overlay that takes the mouse.
    pub pointer: Pointer,
    /// Halliday → game: each overlay's height in meters as Halliday shows it (`f32` bits; 0:
    /// unknown), for `ComputeOverlayIntersection`.
    pub overlay_heights: [AtomicU32; OVERLAYS],
}

/// Halliday → game: a hand pointing at an overlay that takes the mouse (each field its own
/// atomic: a torn read is at worst a frame's mix of two positions).
#[repr(C)]
#[derive(Debug)]
pub struct Pointer {
    /// The overlay's index + 1; 0: none.
    pub overlay: AtomicU32,
    /// The hand: OpenVR's device index (1 left, 2 right).
    pub device: AtomicU32,
    /// Bit 0: the trigger is held.
    pub buttons: AtomicU32,
    /// Where on the overlay's picture, `f32` bits, 0…1 from its top left.
    pub u: AtomicU32,
    pub v: AtomicU32,
    /// Scroll so far, in hundredths of a notch (an `i32`, wrapping); the game side sends the
    /// difference.
    pub scroll: AtomicU32,
}

/// [`Pointer`]'s values.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PointerState {
    pub overlay: u32,
    pub device: u32,
    pub buttons: u32,
    pub u: f32,
    pub v: f32,
    pub scroll: i32,
}

/// Halliday: where a hand points.
///
/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn write_pointer(h: *mut Header, p: &PointerState) {
    // SAFETY: `h` is valid (caller); atomics.
    unsafe {
        let r = &(*h).pointer;
        r.u.store(p.u.to_bits(), Ordering::SeqCst);
        r.v.store(p.v.to_bits(), Ordering::SeqCst);
        r.device.store(p.device, Ordering::SeqCst);
        r.buttons.store(p.buttons, Ordering::SeqCst);
        r.scroll.store(p.scroll as u32, Ordering::SeqCst);
        r.overlay.store(p.overlay, Ordering::SeqCst);
    }
}

/// The game side: where a hand points.
///
/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn read_pointer(h: *const Header) -> PointerState {
    // SAFETY: `h` is valid (caller); atomics.
    unsafe {
        let r = &(*h).pointer;
        PointerState {
            overlay: r.overlay.load(Ordering::SeqCst),
            device: r.device.load(Ordering::SeqCst),
            buttons: r.buttons.load(Ordering::SeqCst),
            u: f32::from_bits(r.u.load(Ordering::SeqCst)),
            v: f32::from_bits(r.v.load(Ordering::SeqCst)),
            scroll: r.scroll.load(Ordering::SeqCst) as i32,
        }
    }
}

const _: () = assert!(core::mem::size_of::<Header>() <= HEADER_BYTES);
const _: () = assert!(EYE_BYTES % 16384 == 0 && HEADER_BYTES % 16384 == 0);

// The header lives in memory another process writes at the same time, so it is only ever reached
// through raw pointers (never `&mut Header`); the atomics are safe to share.

/// Halliday: publishes this frame's state and counts a vsync.
///
/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn publish(h: *mut Header, state: &State) {
    // SAFETY: the caller provides a valid mapping.
    unsafe { publish_with_notification(h, state, true) };
}

/// Publishes fresh head/input state independently of the game's render cadence.
/// `notify_game` advances the existing v6 wake counter; false still updates the
/// state sequence lock, so asynchronous pose/input reads remain current.
///
/// # Safety
/// `h` points to a mapped bridge file with a single state writer.
pub unsafe fn publish_with_notification(h: *mut Header, state: &State, notify_game: bool) {
    unsafe { publish_with_motion(h, state, notify_game, None) };
}

/// Publishes state and optional per-component velocity validity under one seqlock.
/// # Safety
/// Same complete mapping/single-writer requirements as `publish_with_notification`.
pub unsafe fn publish_with_motion(
    h: *mut Header,
    state: &State,
    notify_game: bool,
    mask: Option<u32>,
) {
    // SAFETY: `h` is valid (caller); the atomics may be shared.
    let (seq, vsync) = unsafe { (&(*h).state_seq, &(*h).vsync_count) };
    let s = seq.load(Ordering::Relaxed) | 1;
    seq.store(s, Ordering::Relaxed);
    fence(Ordering::Release);
    // SAFETY: Halliday is the only writer of `state`; readers retry on a torn read.
    unsafe { core::ptr::write_volatile(core::ptr::addr_of_mut!((*h).state), *state) };
    unsafe { motion::extension(h) }.publish(s.wrapping_add(1), mask);
    seq.store(s.wrapping_add(1), Ordering::Release);
    if notify_game {
        vsync.fetch_add(1, Ordering::SeqCst);
    }
}

/// The game side: the latest state, or `None` if it kept changing while read.
///
/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn read_state(h: *const Header) -> Option<State> {
    unsafe { read_state_with_motion(h) }.map(|(state, _)| state)
}

/// Reads velocity validity and all head/controller state from the exact same publication.
/// # Safety
/// The caller maps the complete v6 bridge header, including reserved bytes.
pub unsafe fn read_state_with_motion(h: *const Header) -> Option<(State, u32)> {
    // SAFETY: `h` is valid (caller).
    let seq = unsafe { &(*h).state_seq };
    for _ in 0..64 {
        let a = seq.load(Ordering::Acquire);
        if a & 1 == 1 {
            core::hint::spin_loop();
            continue;
        }
        // SAFETY: a copy, validated by the sequence check below.
        let s = unsafe { core::ptr::read_volatile(core::ptr::addr_of!((*h).state)) };
        let mask = unsafe { motion::extension(h) }.read(a);
        fence(Ordering::Acquire);
        if seq.load(Ordering::Relaxed) == a {
            return Some((s, mask));
        }
    }
    None
}

/// The game side: a slot that is neither the newest frame nor the one Halliday is reading.
///
/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn free_slot(h: *const Header) -> usize {
    // SAFETY: `h` is valid (caller).
    let (latest, reading) = unsafe { (&(*h).latest, &(*h).reading) };
    let (l, r) = (
        latest.load(Ordering::SeqCst),
        reading.load(Ordering::SeqCst),
    );
    (0..SLOTS)
        .find(|&i| i as u32 + 1 != l && i as u32 + 1 != r)
        .unwrap_or(0)
}

/// Halliday: claims the newest frame for reading; its slot, or `None` if there is none yet.
/// Release it with [`end_read`] once the copy is done.
///
/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn begin_read(h: *const Header) -> Option<usize> {
    // SAFETY: `h` is valid (caller).
    let (latest, reading) = unsafe { (&(*h).latest, &(*h).reading) };
    for _ in 0..8 {
        let l = latest.load(Ordering::SeqCst);
        if l == 0 {
            return None;
        }
        reading.store(l, Ordering::SeqCst);
        // The game side may have published a newer frame between the two loads: if so, the slot
        // claimed may already be taken for writing; claim the newer one instead.
        if latest.load(Ordering::SeqCst) == l {
            return Some(l as usize - 1);
        }
    }
    None
}

/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn end_read(h: *const Header) {
    // SAFETY: `h` is valid (caller).
    unsafe { (*h).reading.store(0, Ordering::SeqCst) };
}

/// The game side: changes the scene and overlays under their sequence lock.
///
/// # Safety
/// `h` points to a mapped bridge file; one thread of the game side at a time (the runtime
/// serializes its calls).
pub unsafe fn write_scene(h: *mut Header, f: impl FnOnce(&mut Scene, &mut [Overlay; OVERLAYS])) {
    // SAFETY: `h` is valid (caller); the game side is the only writer.
    unsafe {
        let seq = &(*h).scene_seq;
        let s = seq.load(Ordering::Relaxed) | 1;
        seq.store(s, Ordering::Relaxed);
        fence(Ordering::Release);
        let mut scene = core::ptr::read_volatile(core::ptr::addr_of!((*h).scene));
        let mut overlays = core::ptr::read_volatile(core::ptr::addr_of!((*h).overlays));
        f(&mut scene, &mut overlays);
        core::ptr::write_volatile(core::ptr::addr_of_mut!((*h).scene), scene);
        core::ptr::write_volatile(core::ptr::addr_of_mut!((*h).overlays), overlays);
        seq.store(s.wrapping_add(1), Ordering::Release);
    }
}

/// Halliday: the scene and overlays, or `None` if they kept changing while read.
///
/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn read_scene(h: *const Header) -> Option<(Scene, [Overlay; OVERLAYS])> {
    // SAFETY: `h` is valid (caller).
    let seq = unsafe { &(*h).scene_seq };
    for _ in 0..64 {
        let a = seq.load(Ordering::Acquire);
        if a & 1 == 1 {
            core::hint::spin_loop();
            continue;
        }
        // SAFETY: copies, validated by the sequence check below.
        let copy = unsafe {
            (
                core::ptr::read_volatile(core::ptr::addr_of!((*h).scene)),
                core::ptr::read_volatile(core::ptr::addr_of!((*h).overlays)),
            )
        };
        fence(Ordering::Acquire);
        if seq.load(Ordering::Relaxed) == a {
            return Some(copy);
        }
    }
    None
}

/// The game side, before writing a picture's pixels: makes its `seq` odd and waits (up to about
/// `spins` tries of `wait`) while Halliday reads it. Then write, then [`end_picture`].
pub fn begin_picture(p: &Picture, width: u32, height: u32, mut wait: impl FnMut(), spins: u32) {
    let s = p.seq.load(Ordering::SeqCst) | 1;
    p.seq.store(s, Ordering::SeqCst);
    for _ in 0..spins {
        if p.reading.load(Ordering::SeqCst) == 0 {
            break;
        }
        wait();
    }
    p.width.store(width, Ordering::Relaxed);
    p.height.store(height, Ordering::Relaxed);
}

/// The game side: the picture is complete.
pub fn end_picture(p: &Picture) {
    let s = p.seq.load(Ordering::SeqCst);
    p.seq.store((s | 1).wrapping_add(1), Ordering::SeqCst);
}

/// Halliday: claims a picture whose `seq` is even and not `seen`; its `seq`, width and height.
/// Release it with `picture.reading` = 0 once copied.
pub fn claim_picture(p: &Picture, seen: u32) -> Option<(u32, u32, u32)> {
    let s = p.seq.load(Ordering::SeqCst);
    if s & 1 == 1 || s == seen || s == 0 {
        return None;
    }
    p.reading.store(1, Ordering::SeqCst);
    if p.seq.load(Ordering::SeqCst) != s {
        p.reading.store(0, Ordering::SeqCst);
        return None;
    }
    let (w, h) = (
        p.width.load(Ordering::Relaxed),
        p.height.load(Ordering::Relaxed),
    );
    Some((s, w, h))
}

/// The game side: records a window frame's pose and size before presenting it.
///
/// # Safety
/// `h` points to a mapped bridge file; one thread of the game side at a time.
pub unsafe fn write_present_frame(h: *mut Header, info: &PresentInfo) {
    // SAFETY: `h` is valid (caller); the game side is the only writer of the ring.
    unsafe {
        let r = core::ptr::addr_of_mut!((*h).present_frames[info.number as usize % PRESENT_RING]);
        (*r).number.store(PRESENT_BUSY, Ordering::SeqCst);
        core::ptr::addr_of_mut!((*r).eye_width).write_volatile(info.eye_width);
        core::ptr::addr_of_mut!((*r).eye_height).write_volatile(info.eye_height);
        core::ptr::addr_of_mut!((*r).flipped).write_volatile(info.flipped as u32);
        core::ptr::addr_of_mut!((*r).frame_index).write_volatile(info.frame_index);
        core::ptr::addr_of_mut!((*r).texture_type).write_volatile(info.texture_type);
        core::ptr::addr_of_mut!((*r).pose).write_volatile(info.pose);
        (*r).number.store(info.number, Ordering::SeqCst);
    }
}

/// Halliday: the record of window frame `number`, or `None` if it was overwritten or is being
/// written.
///
/// # Safety
/// `h` points to a mapped bridge file.
pub unsafe fn read_present_frame(h: *const Header, number: u32) -> Option<PresentInfo> {
    // 0: a record never written (frames are numbered from 1).
    if number == 0 || number == PRESENT_BUSY {
        return None;
    }
    // SAFETY: `h` is valid (caller); copies, validated by the number check after them.
    unsafe {
        let r = core::ptr::addr_of!((*h).present_frames[number as usize % PRESENT_RING]);
        if (*r).number.load(Ordering::SeqCst) != number {
            return None;
        }
        let info = PresentInfo {
            number,
            eye_width: core::ptr::addr_of!((*r).eye_width).read_volatile(),
            eye_height: core::ptr::addr_of!((*r).eye_height).read_volatile(),
            flipped: core::ptr::addr_of!((*r).flipped).read_volatile() != 0,
            frame_index: core::ptr::addr_of!((*r).frame_index).read_volatile(),
            texture_type: core::ptr::addr_of!((*r).texture_type).read_volatile(),
            pose: core::ptr::addr_of!((*r).pose).read_volatile(),
        };
        fence(Ordering::Acquire);
        ((*r).number.load(Ordering::SeqCst) == number).then_some(info)
    }
}

/// The frame number a window frame's band holds, read from its top rows (`pixel(x, y)` gives
/// the green channel of a pixel); `None` if the band isn't clean black and white.
pub fn read_band(mut pixel: impl FnMut(u32, u32) -> u8) -> Option<u32> {
    let mut n = 0u32;
    let y = PRESENT_BAND / 2;
    for bit in 0..32 {
        let v = pixel(bit * PRESENT_BAND + PRESENT_BAND / 2, y);
        if v > 200 {
            n |= 1 << bit;
        } else if v > 55 {
            return None;
        }
    }
    Some(n)
}

/// The band's pixels for frame `number`: `PRESENT_BAND` rows of `32 * PRESENT_BAND` RGBA pixels
/// (gray, so the byte order doesn't matter).
pub fn fill_band(number: u32, out: &mut [u8; (32 * PRESENT_BAND * PRESENT_BAND * 4) as usize]) {
    let row = 32 * PRESENT_BAND as usize;
    for y in 0..PRESENT_BAND as usize {
        for x in 0..row {
            let v = if (number >> (x / PRESENT_BAND as usize)) & 1 == 1 {
                255
            } else {
                0
            };
            let i = (y * row + x) * 4;
            out[i..i + 4].copy_from_slice(&[v, v, v, 255]);
        }
    }
}

/// OpenVR's button ids used by the emulated controller (`EVRButtonId`).
pub mod button {
    pub const SYSTEM: u32 = 0;
    pub const APPLICATION_MENU: u32 = 1;
    pub const GRIP: u32 = 2;
    pub const TOUCHPAD: u32 = 32;
    pub const TRIGGER: u32 = 33;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn optional_per_eye_colour_keeps_the_v6_layout_and_legacy_api() {
        assert_eq!(VERSION, 6);
        assert_eq!(core::mem::size_of::<Frame>(), 136);
        for api in [0, 1, 4] {
            assert_eq!(frame_color_space(api, 0), FRAME_COLOR_LEGACY);
            assert_eq!(frame_color_space(api, 1), FRAME_COLOR_LEGACY);
            let metadata = frame_texture_metadata(api, FRAME_COLOR_LINEAR, FRAME_COLOR_SRGB);
            assert_eq!(metadata & FRAME_TEXTURE_API_MASK, api);
            assert_eq!(frame_color_space(metadata, 0), FRAME_COLOR_LINEAR);
            assert_eq!(frame_color_space(metadata, 1), FRAME_COLOR_SRGB);
        }
        assert_eq!(frame_color_space(frame_texture_metadata(0, 3, 3), 0), 0);
        assert_eq!(frame_color_space(u32::MAX, 2), 0);
    }

    #[test]
    fn layout_is_fixed() {
        // The two sides are built for different CPUs: these sizes are part of the format.
        assert_eq!(core::mem::size_of::<Pose>(), 64);
        assert_eq!(core::mem::size_of::<Controller>(), 64 + 8 + 8 + 40 + 8);
        assert_eq!(core::mem::size_of::<Frame>(), 4 * 4 + 32 + 64 + 8 + 8 + 8);
        assert_eq!(core::mem::align_of::<Header>(), 8);
        assert_eq!(image_offset(0, 0), HEADER_BYTES);
        assert_eq!(image_offset(2, 1) + EYE_BYTES, overlay_offset(0));
        assert_eq!(skybox_offset() + SKYBOX_BYTES, FILE_BYTES);
        assert_eq!(
            core::mem::size_of::<Overlay>(),
            6 * 4 + 48 + 4 + 4 + 12 + 4 + 16 + 64 + 256
        );
        assert_eq!(core::mem::size_of::<Scene>(), 60);
        assert_eq!(core::mem::size_of::<Picture>(), 16);
        assert_eq!(core::mem::size_of::<PresentFrame>(), 4 * 4 + 8 + 8 + 64);
        assert_eq!(overlay_offset(1) % 16384, 0);
    }

    #[test]
    fn scene_round_trips() {
        let mut b = header();
        let h = b.ptr();
        unsafe {
            write_scene(h, |scene, overlays| {
                *overlays = [Overlay::NONE; OVERLAYS];
                scene.grid = 1;
                overlays[2].used = 1;
                overlays[2].width_m = 2.5;
            })
        };
        let (scene, overlays) = unsafe { read_scene(h) }.unwrap();
        assert_eq!(scene.grid, 1);
        assert_eq!(overlays[2].used, 1);
        assert_eq!(overlays[2].width_m, 2.5);
        assert_eq!(overlays[0].alpha, 1.0);
        assert_eq!(unsafe { (*h).scene_seq.load(Ordering::SeqCst) } & 1, 0);
    }

    #[test]
    fn a_picture_is_claimed_once_complete_and_once_per_change() {
        let p = Picture {
            seq: AtomicU32::new(0),
            reading: AtomicU32::new(0),
            width: AtomicU32::new(0),
            height: AtomicU32::new(0),
        };
        assert_eq!(claim_picture(&p, 0), None, "never written");
        begin_picture(&p, 4, 2, || {}, 1);
        assert_eq!(claim_picture(&p, 0), None, "being written");
        end_picture(&p);
        let (s, w, h) = claim_picture(&p, 0).unwrap();
        assert_eq!((w, h), (4, 2));
        assert_eq!(p.reading.load(Ordering::SeqCst), 1);
        p.reading.store(0, Ordering::SeqCst);
        assert_eq!(claim_picture(&p, s), None, "already seen");
        begin_picture(&p, 8, 8, || {}, 1);
        end_picture(&p);
        assert!(claim_picture(&p, s).is_some());
    }

    #[test]
    fn present_frames_are_found_by_number_until_overwritten() {
        let mut b = header();
        let h = b.ptr();
        let info = |n: u32| PresentInfo {
            number: n,
            eye_width: 2015,
            eye_height: 2054,
            flipped: n % 2 == 1,
            frame_index: n as u64 + 100,
            texture_type: 0,
            pose: Pose::default(),
        };
        assert_eq!(unsafe { read_present_frame(h, 0) }, None, "never written");
        unsafe { write_present_frame(h, &info(5)) };
        assert_eq!(unsafe { read_present_frame(h, 5) }, Some(info(5)));
        unsafe { write_present_frame(h, &info(5 + PRESENT_RING as u32)) };
        assert_eq!(unsafe { read_present_frame(h, 5) }, None, "overwritten");
        unsafe {
            (*h).present_frames[5 % PRESENT_RING]
                .number
                .store(PRESENT_BUSY, Ordering::SeqCst)
        };
        assert_eq!(unsafe { read_present_frame(h, PRESENT_BUSY) }, None);
    }

    #[test]
    fn the_band_reads_back_its_number() {
        let mut band = [0u8; (32 * PRESENT_BAND * PRESENT_BAND * 4) as usize];
        for n in [0u32, 1, 0x8000_0001, 123_456_789, u32::MAX - 1] {
            fill_band(n, &mut band);
            let row = 32 * PRESENT_BAND;
            let got = read_band(|x, y| band[((y * row + x) * 4 + 1) as usize]);
            assert_eq!(got, Some(n));
        }
        assert_eq!(read_band(|_, _| 128), None, "gray isn't a band");
    }

    #[test]
    fn the_pointer_reads_back() {
        let mut b = header();
        let h = b.ptr();
        // SAFETY: a zeroed header of the right size.
        assert_eq!(unsafe { read_pointer(h) }, PointerState::default());
        let p = PointerState {
            overlay: 3,
            device: 2,
            buttons: 1,
            u: 0.25,
            v: 0.75,
            scroll: -250,
        };
        unsafe { write_pointer(h, &p) };
        assert_eq!(unsafe { read_pointer(h) }, p);
    }

    fn header() -> alloc_free::Boxed {
        alloc_free::Boxed::new()
    }

    #[test]
    fn state_round_trips_and_counts_vsyncs() {
        let mut b = header();
        let h = b.ptr();
        let mut s = State::default();
        s.head.position = [0.0, 1.65, 0.0];
        s.controllers[1].pressed = 1 << button::TRIGGER;
        unsafe { publish(h, &s) };
        unsafe { publish(h, &s) };
        assert_eq!(unsafe { read_state(h) }, Some(s));
        assert_eq!(unsafe { (*h).vsync_count.load(Ordering::SeqCst) }, 2);
        assert_eq!(unsafe { (*h).state_seq.load(Ordering::SeqCst) } & 1, 0);
    }

    #[test]
    fn pose_publication_does_not_require_a_game_frame_notification() {
        let mut b = header();
        let h = b.ptr();
        let mut state = State::default();
        for tick in 0..120 {
            state.head.stamp = tick as f32;
            state.controllers[0].packet = tick;
            state.controllers[1].packet = tick + 1000;
            state.controllers[0].pose.position = [tick as f32, 1.0, -0.5];
            state.controllers[1].pose.position = [-(tick as f32), 1.2, -0.4];
            unsafe { publish_with_notification(h, &state, tick % 2 == 0) };
            assert_eq!(unsafe { read_state(h) }, Some(state));
        }
        assert_eq!(unsafe { (*h).vsync_count.load(Ordering::SeqCst) }, 60);
        assert_eq!(unsafe { (*h).state_seq.load(Ordering::SeqCst) }, 240);
        // Legacy callers retain their existing one-publication/one-wake behavior.
        unsafe { publish(h, &state) };
        assert_eq!(unsafe { (*h).vsync_count.load(Ordering::SeqCst) }, 61);
        assert_eq!(VERSION, 6);
    }

    #[test]
    fn writer_never_takes_the_newest_or_the_read_slot() {
        let mut b = header();
        let h = b.ptr();
        assert_eq!(unsafe { begin_read(h) }, None);
        for latest in 0..=SLOTS as u32 {
            for reading in 0..=SLOTS as u32 {
                unsafe {
                    (*h).latest.store(latest, Ordering::SeqCst);
                    (*h).reading.store(reading, Ordering::SeqCst);
                }
                let s = unsafe { free_slot(h) } as u32 + 1;
                assert!(
                    s != latest && s != reading,
                    "latest {latest} reading {reading} -> {s}"
                );
            }
        }
        unsafe { (*h).latest.store(2, Ordering::SeqCst) };
        assert_eq!(unsafe { begin_read(h) }, Some(1));
        assert_eq!(unsafe { (*h).reading.load(Ordering::SeqCst) }, 2);
        unsafe { end_read(h) };
        assert_eq!(unsafe { (*h).reading.load(Ordering::SeqCst) }, 0);
    }

    /// A zeroed header on the stack's heap-free stand-in (the crate is `no_std`).
    mod alloc_free {
        use super::super::Header;
        pub struct Boxed([u64; super::super::HEADER_BYTES / 8]);
        impl Boxed {
            pub fn new() -> Self {
                Boxed([0; super::super::HEADER_BYTES / 8])
            }
            pub fn ptr(&mut self) -> *mut Header {
                self.0.as_mut_ptr().cast()
            }
        }
    }
}
