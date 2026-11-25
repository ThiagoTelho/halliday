//! Halliday's side of the bridge to a VR game running under Wine (see `halliday-bridge` for the
//! format and `halliday-vrclient` for the game's side).
//!
//! Halliday creates `halliday-bridge.shm` in its OpenVR runtime folder, maps it, writes the
//! headset's configuration, publishes the head and controllers every display frame, and takes the
//! game's newest frame when there is one. The file holds the game's frames while Halliday runs and
//! is removed when it stops.

use halliday_bridge::{self as bridge, Header, State};
use std::ffi::c_void;
use std::fs::OpenOptions;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

unsafe extern "C" {
    fn mmap(
        addr: *mut c_void,
        len: usize,
        prot: i32,
        flags: i32,
        fd: i32,
        offset: i64,
    ) -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> i32;
}
const PROT_READ: i32 = 1;
const PROT_WRITE: i32 = 2;
const MAP_SHARED: i32 = 1;

/// What the game should render: per-eye size, refresh rate, IPD and field of view.
#[derive(Clone, Copy, Debug)]
pub struct Config {
    pub eye_width: u32,
    pub eye_height: u32,
    pub display_hz: f32,
    pub ipd: f32,
    /// Per eye: tangents of the left, right, up and down edges (left and down negative).
    pub tangents: [[f32; 4]; 2],
}

/// A frame of the game's, claimed for reading.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FrameInfo {
    pub slot: usize,
    pub width: u32,
    pub height: u32,
    pub bottom_up: bool,
    pub bgra: bool,
    /// The picture's alpha is meant: the room may show where it is clear.
    pub see_through: bool,
    pub bounds: [[f32; 4]; 2],
    pub pose: bridge::Pose,
    pub frame_index: u64,
    /// Byte offsets of each eye's image in the file.
    pub offsets: [usize; 2],
}

/// The game's side, as last seen.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Client {
    pub frames: u64,
    pub calls: u64,
    pub pid: u32,
    pub name: [u8; 64],
    /// Beats about every 250 ms while the runtime is loaded in a game.
    pub heartbeat: u64,
    /// Between the game's VR_Init and VR_Shutdown.
    pub initialized: bool,
    pub quit_acknowledged: u32,
}

/// A picture of the game's (an overlay's, the skybox) claimed for reading: release it with
/// [`GameBridge::release_picture`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PictureInfo {
    pub seq: u32,
    pub width: u32,
    pub height: u32,
    /// Byte offset of its first row in the file (rows of `width * 4` bytes, RGBA, premultiplied).
    pub offset: usize,
}

/// Which picture: an overlay's (0 ..< OVERLAYS) or the skybox.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PictureId {
    Overlay(usize),
    Skybox,
}

pub struct GameBridge {
    path: PathBuf,
    base: *mut u8,
}

// SAFETY: the mapping is shared memory; every access goes through the bridge's atomics or plain
// copies that the format allows to race (sequence locks, slot hand-off).
unsafe impl Send for GameBridge {}
unsafe impl Sync for GameBridge {}

impl GameBridge {
    /// Creates (or replaces) the file at `path` and maps it.
    pub fn create(path: &Path, config: Config) -> std::io::Result<GameBridge> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)?;
        file.set_len(bridge::FILE_BYTES as u64)?;
        // SAFETY: a fresh shared mapping of the whole file.
        let base = unsafe {
            mmap(
                std::ptr::null_mut(),
                bridge::FILE_BYTES,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if base as isize == -1 {
            return Err(std::io::Error::last_os_error());
        }
        let b = GameBridge {
            path: path.to_path_buf(),
            base: base.cast(),
        };
        let h = b.header();
        // SAFETY: the mapping is ours and zeroed; nobody else has it yet.
        unsafe {
            (*h).version = bridge::VERSION;
            (*h).eye_width = config.eye_width.min(2560);
            (*h).eye_height = config.eye_height.min(2560);
            (*h).display_hz = config.display_hz;
            (*h).ipd = config.ipd;
            (*h).tangents = config.tangents;
            (*h).halliday_alive.store(1, Ordering::SeqCst);
            // Last: a game seeing the magic sees a complete header.
            std::ptr::write_volatile(std::ptr::addr_of_mut!((*h).magic), bridge::MAGIC);
        }
        Ok(b)
    }

    fn header(&self) -> *mut Header {
        self.base.cast()
    }

    /// The start of the mapping (page-aligned, `FILE_BYTES` long), for wrapping it in a GPU buffer.
    pub fn base(&self) -> *mut u8 {
        self.base
    }

    pub fn publish(&self, state: &State) {
        // SAFETY: our mapping.
        unsafe { bridge::publish(self.header(), state) };
    }

    /// Pose/input publication stays at the physical display rate; only selected
    /// display targets wake a game running at a lower render cadence.
    pub fn publish_frame(&self, state: &State, notify_game: bool) {
        // SAFETY: our mapping, with the same single-writer contract as publish.
        unsafe { bridge::publish_with_notification(self.header(), state, notify_game) };
    }

    /// Claims the game's newest frame; release it with [`GameBridge::end_read`].
    pub fn begin_read(&self) -> Option<FrameInfo> {
        let h = self.header();
        // SAFETY: our mapping.
        let slot = unsafe { bridge::begin_read(h) }?;
        // SAFETY: the slot is claimed; the game side doesn't write it now.
        let f = unsafe { &(*h).frames[slot] };
        let fits = if f.shared != 0 {
            bridge::fits_shared(f.width, f.height)
        } else {
            bridge::fits(f.width, f.height)
        };
        if f.seq.load(Ordering::SeqCst) & 1 == 1 || !fits {
            self.end_read();
            return None;
        }
        Some(FrameInfo {
            slot,
            width: f.width,
            height: f.height,
            bottom_up: f.bottom_up != 0,
            bgra: f.bgra != 0,
            see_through: f.see_through != 0,
            bounds: f.bounds,
            pose: f.pose,
            frame_index: f.frame_index,
            offsets: [
                bridge::image_offset(slot, 0),
                bridge::image_offset(slot, if f.shared != 0 { 0 } else { 1 }),
            ],
        })
    }

    pub fn end_read(&self) {
        // SAFETY: our mapping.
        unsafe { bridge::end_read(self.header()) };
    }

    pub fn client(&self) -> Client {
        let h = self.header();
        // SAFETY: our mapping; plain reads of values the game writes.
        unsafe {
            Client {
                frames: (*h).client_frames.load(Ordering::SeqCst),
                calls: (*h).client_calls.load(Ordering::SeqCst),
                pid: std::ptr::read_volatile(std::ptr::addr_of!((*h).client_pid)),
                name: std::ptr::read_volatile(std::ptr::addr_of!((*h).app_name)),
                heartbeat: (*h).client_heartbeat.load(Ordering::SeqCst),
                initialized: (*h).client_initialized.load(Ordering::SeqCst) != 0,
                quit_acknowledged: (*h).quit_acknowledged.load(Ordering::SeqCst),
            }
        }
    }

    /// What the game asked the compositor to show besides its frames, and its overlays.
    pub fn scene(&self) -> Option<(bridge::Scene, [bridge::Overlay; bridge::OVERLAYS])> {
        // SAFETY: our mapping.
        unsafe { bridge::read_scene(self.header()) }
    }

    fn picture(&self, id: PictureId) -> Option<(&bridge::Picture, usize)> {
        let h = self.header();
        // SAFETY: our mapping; pictures are shared through their atomics.
        unsafe {
            match id {
                PictureId::Overlay(i) if i < bridge::OVERLAYS => {
                    Some((&(*h).overlay_pictures[i], bridge::overlay_offset(i)))
                }
                PictureId::Overlay(_) => None,
                PictureId::Skybox => Some((&(*h).skybox_picture, bridge::skybox_offset())),
            }
        }
    }

    /// Claims a picture that changed since `seen` (its last `seq`), if it is complete.
    pub fn claim_picture(&self, id: PictureId, seen: u32) -> Option<PictureInfo> {
        let (p, offset) = self.picture(id)?;
        let (seq, width, height) = bridge::claim_picture(p, seen)?;
        let side = if id == PictureId::Skybox {
            bridge::SKYBOX_WIDTH
        } else {
            bridge::OVERLAY_SIDE
        };
        if width == 0 || height == 0 || width > side || height > side {
            p.reading.store(0, Ordering::SeqCst);
            return None;
        }
        Some(PictureInfo {
            seq,
            width,
            height,
            offset,
        })
    }

    pub fn release_picture(&self, id: PictureId) {
        if let Some((p, _)) = self.picture(id) {
            p.reading.store(0, Ordering::SeqCst);
        }
    }

    /// Halliday's measured display period.
    pub fn set_frame_interval(&self, ns: u64) {
        // SAFETY: our mapping.
        unsafe {
            (*self.header())
                .frame_interval_ns
                .store(ns, Ordering::SeqCst)
        };
    }

    /// A display frame showed an older game frame again.
    pub fn count_late_vsync(&self) {
        // SAFETY: our mapping.
        unsafe { (*self.header()).late_vsyncs.fetch_add(1, Ordering::SeqCst) };
    }

    /// Asks the game to quit (it gets OpenVR's `VREvent_Quit`).
    pub fn request_quit(&self) {
        // SAFETY: our mapping.
        unsafe {
            (*self.header())
                .quit_requests
                .fetch_add(1, Ordering::SeqCst)
        };
    }

    /// Halliday's own interface is over the game (SteamVR's dashboard), or no longer.
    pub fn set_dashboard(&self, shown: bool) {
        // SAFETY: our mapping.
        unsafe {
            (*self.header())
                .dashboard
                .store(shown as u32, Ordering::SeqCst)
        };
    }

    /// Tells the game where to put a window of frames (Windows' screen coordinates), or that
    /// Halliday can't capture one (`origin` None): it then copies its frames into the bridge.
    pub fn set_present(&self, origin: Option<(i32, i32)>) {
        let h = self.header();
        // SAFETY: our mapping; the origin is written before it is enabled.
        unsafe {
            if let Some((x, y)) = origin {
                std::ptr::write_volatile(std::ptr::addr_of_mut!((*h).present_origin), [x, y]);
            }
            (*h).present_enabled
                .store(origin.is_some() as u32, Ordering::SeqCst);
        }
    }

    /// Where a hand points at an overlay that takes the mouse (`overlay` 0: none).
    pub fn set_pointer(&self, p: &bridge::PointerState) {
        // SAFETY: our mapping.
        unsafe { bridge::write_pointer(self.header(), p) }
    }

    /// Overlay `i`'s height in meters as Halliday shows it.
    pub fn set_overlay_height(&self, i: usize, meters: f32) {
        if i < bridge::OVERLAYS {
            // SAFETY: our mapping; an atomic.
            unsafe { (*self.header()).overlay_heights[i].store(meters.to_bits(), Ordering::SeqCst) }
        }
    }

    /// The game side's window of frames: its state (`halliday_bridge::present`) and size.
    pub fn present_status(&self) -> (u32, u32, u32) {
        let h = self.header();
        // SAFETY: our mapping.
        unsafe {
            (
                (*h).present_state.load(Ordering::SeqCst),
                (*h).present_width.load(Ordering::SeqCst),
                (*h).present_height.load(Ordering::SeqCst),
            )
        }
    }

    /// The pose and size of window frame `number`, if it is still in the ring.
    pub fn present_frame(&self, number: u32) -> Option<bridge::PresentInfo> {
        // SAFETY: our mapping.
        unsafe { bridge::read_present_frame(self.header(), number) }
    }

    /// Halliday captured window frame `number`.
    pub fn present_seen(&self, number: u32) {
        // SAFETY: our mapping.
        unsafe {
            (*self.header())
                .present_seen
                .store(number, Ordering::SeqCst)
        };
    }
}

impl Drop for GameBridge {
    fn drop(&mut self) {
        // SAFETY: our mapping, unmapped once.
        unsafe {
            (*self.header()).halliday_alive.store(0, Ordering::SeqCst);
            munmap(self.base.cast(), bridge::FILE_BYTES);
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

/// The game's side of the bridge, for tests and `halliday-probe game-sim`: what
/// `halliday-vrclient` does inside Wine, done natively.
pub struct GameSide {
    base: *mut u8,
    last_vsync: u64,
    frame_index: u64,
    /// Said of the frames submitted from now on: their alpha is meant, and the room may show
    /// where they are clear (`Frame::see_through`).
    pub see_through: bool,
}

// SAFETY: as GameBridge.
unsafe impl Send for GameSide {}

impl GameSide {
    /// Maps a bridge file Halliday created, as the game: writes its process id and name.
    pub fn open(path: &Path) -> std::io::Result<GameSide> {
        Self::open_as(path, "game-sim.exe")
    }

    /// [`GameSide::open`] under the name Halliday shows for the game (its executable's, as a
    /// Windows game's is).
    pub fn open_as(path: &Path, app: &str) -> std::io::Result<GameSide> {
        let g = Self::map(path)?;
        let mut name = [0u8; 64];
        let n = app.len().min(63);
        name[..n].copy_from_slice(&app.as_bytes()[..n]);
        // SAFETY: plain writes into the game's fields of the header.
        unsafe {
            (*g.header()).client_pid = std::process::id();
            (*g.header()).app_name = name;
        }
        Ok(g)
    }

    /// Maps a bridge file without writing anything (to look at a running game's frames).
    pub fn view(path: &Path) -> std::io::Result<GameSide> {
        Self::map(path)
    }

    fn map(path: &Path) -> std::io::Result<GameSide> {
        let file = OpenOptions::new().read(true).write(true).open(path)?;
        if file.metadata()?.len() < bridge::FILE_BYTES as u64 {
            return Err(std::io::Error::other("the bridge file is too short"));
        }
        // SAFETY: a shared mapping of the whole file.
        let base = unsafe {
            mmap(
                std::ptr::null_mut(),
                bridge::FILE_BYTES,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if base as isize == -1 {
            return Err(std::io::Error::last_os_error());
        }
        let h = base as *const Header;
        // SAFETY: the mapping just made.
        if unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*h).magic)) } != bridge::MAGIC {
            // SAFETY: unmapping what was mapped.
            unsafe { munmap(base, bridge::FILE_BYTES) };
            return Err(std::io::Error::other(
                "not a Halliday bridge file (or from another version)",
            ));
        }
        Ok(GameSide {
            base: base.cast(),
            last_vsync: 0,
            frame_index: 0,
            see_through: false,
        })
    }

    fn header(&self) -> *mut Header {
        self.base.cast()
    }

    /// The render size and per-eye tangents Halliday asks for.
    pub fn config(&self) -> Config {
        let h = self.header();
        // SAFETY: our mapping; Halliday wrote these before publishing the magic.
        unsafe {
            Config {
                eye_width: (*h).eye_width,
                eye_height: (*h).eye_height,
                display_hz: (*h).display_hz,
                ipd: (*h).ipd,
                tangents: (*h).tangents,
            }
        }
    }

    pub fn halliday_alive(&self) -> bool {
        // SAFETY: our mapping.
        unsafe { (*self.header()).halliday_alive.load(Ordering::SeqCst) != 0 }
    }

    /// Waits (at most `timeout`) for Halliday's next display frame; its state.
    pub fn wait_frame(&mut self, timeout: std::time::Duration) -> Option<State> {
        let h = self.header();
        let start = std::time::Instant::now();
        loop {
            // SAFETY: our mapping.
            let v = unsafe { (*h).vsync_count.load(Ordering::SeqCst) };
            if v != self.last_vsync {
                self.last_vsync = v;
                break;
            }
            if start.elapsed() > timeout {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        // SAFETY: our mapping.
        unsafe { bridge::read_state(h) }
    }

    /// Halliday's state if a display frame has passed since the last call, without waiting.
    pub fn poll_frame(&mut self) -> Option<State> {
        let h = self.header();
        // SAFETY: our mapping.
        let v = unsafe { (*h).vsync_count.load(Ordering::SeqCst) };
        if v == self.last_vsync {
            return None;
        }
        self.last_vsync = v;
        // SAFETY: our mapping.
        unsafe { bridge::read_state(h) }
    }

    /// Writes a frame: `fill(eye, pixels)` paints each eye's RGBA8 rows, bottom row first (as
    /// OpenGL hands them over), at the configured size. `pose` is the head pose it was drawn from.
    pub fn submit(&mut self, pose: bridge::Pose, fill: impl FnMut(usize, &mut [u8])) {
        let c = self.config();
        self.submit_as(pose, (c.eye_width, c.eye_height), true, false, fill);
    }

    /// [`GameSide::submit`] for pictures of another size (each eye `size`, which must fit a
    /// slot), with rows top-down when `bottom_up` is false and bytes in BGRA order when `bgra`.
    pub fn submit_as(
        &mut self,
        pose: bridge::Pose,
        size: (u32, u32),
        bottom_up: bool,
        bgra: bool,
        mut fill: impl FnMut(usize, &mut [u8]),
    ) {
        let h = self.header();
        let (w, ht) = size;
        assert!(bridge::fits(w, ht));
        // SAFETY: our mapping; the slot is ours to write until published.
        unsafe {
            let slot = bridge::free_slot(h);
            let f = &mut *std::ptr::addr_of_mut!((*h).frames[slot]);
            f.seq.fetch_or(1, Ordering::SeqCst);
            for eye in 0..2 {
                let pixels = std::slice::from_raw_parts_mut(
                    self.base.add(bridge::image_offset(slot, eye)),
                    (w * ht * 4) as usize,
                );
                fill(eye, pixels);
            }
            self.frame_index += 1;
            f.width = w;
            f.height = ht;
            f.bottom_up = u32::from(bottom_up);
            f.bounds = [[0.0, 0.0, 1.0, 1.0]; 2];
            f.pose = pose;
            f.frame_index = self.frame_index;
            f.texture_type = 1;
            f.shared = 0;
            f.bgra = u32::from(bgra);
            f.see_through = u32::from(self.see_through);
            let s = f.seq.load(Ordering::SeqCst);
            f.seq.store((s | 1).wrapping_add(1), Ordering::SeqCst);
            (*h).latest.store(slot as u32 + 1, Ordering::SeqCst);
            (*h).client_frames.fetch_add(1, Ordering::SeqCst);
            (*h).client_calls.fetch_add(1, Ordering::Relaxed);
        }
    }
}

impl GameSide {
    /// Shows overlay `i` (for tests and `game-sim`): its description, and a picture of `w` × `h`
    /// RGBA rows top-down painted by `fill`.
    pub fn set_overlay(
        &self,
        i: usize,
        overlay: bridge::Overlay,
        w: u32,
        h: u32,
        fill: impl FnOnce(&mut [u8]),
    ) {
        let hd = self.header();
        // SAFETY: our mapping; the picture follows its protocol, the scene its sequence lock.
        unsafe {
            let p = &(*hd).overlay_pictures[i];
            bridge::begin_picture(
                p,
                w,
                h,
                || std::thread::sleep(std::time::Duration::from_millis(1)),
                50,
            );
            fill(std::slice::from_raw_parts_mut(
                self.base.add(bridge::overlay_offset(i)),
                (w * h * 4) as usize,
            ));
            bridge::end_picture(p);
            bridge::write_scene(hd, |_, overlays| overlays[i] = overlay);
        }
    }

    /// Changes the scene (fades, the grid, the skybox's kind), for tests and `game-sim`.
    pub fn set_scene(&self, f: impl FnOnce(&mut bridge::Scene)) {
        // SAFETY: our mapping.
        unsafe { bridge::write_scene(self.header(), |scene, _| f(scene)) };
    }

    /// The game's overlays, as last written.
    pub fn overlays(&self) -> [bridge::Overlay; bridge::OVERLAYS] {
        // SAFETY: our mapping.
        unsafe { bridge::read_scene(self.header()) }
            .map_or([bridge::Overlay::NONE; bridge::OVERLAYS], |(_, o)| o)
    }

    /// Overlay `i`'s picture (`None`: the skybox's), RGBA rows top-down; read without claiming it,
    /// for a look.
    pub fn peek_picture(&self, i: Option<usize>) -> Option<(u32, u32, Vec<u8>)> {
        let h = self.header();
        // SAFETY: our mapping; plain reads.
        unsafe {
            let (p, offset) = match i {
                Some(i) if i < bridge::OVERLAYS => {
                    (&(*h).overlay_pictures[i], bridge::overlay_offset(i))
                }
                Some(_) => return None,
                None => (&(*h).skybox_picture, bridge::skybox_offset()),
            };
            let (w, ht) = (
                p.width.load(Ordering::SeqCst),
                p.height.load(Ordering::SeqCst),
            );
            if w == 0
                || ht == 0
                || (w * ht * 4) as usize > bridge::OVERLAY_BYTES.max(bridge::SKYBOX_BYTES)
            {
                return None;
            }
            let px = std::slice::from_raw_parts(self.base.add(offset), (w * ht * 4) as usize);
            Some((w, ht, px.to_vec()))
        }
    }

    /// Halliday's requests: (quit requests so far, its interface over the game, late vsyncs).
    pub fn requests(&self) -> (u32, bool, u64) {
        let h = self.header();
        // SAFETY: our mapping.
        unsafe {
            (
                (*h).quit_requests.load(Ordering::SeqCst),
                (*h).dashboard.load(Ordering::SeqCst) != 0,
                (*h).late_vsyncs.load(Ordering::SeqCst),
            )
        }
    }

    /// The newest frame's left and right images, as RGBA rows top-down whatever the game sent (for `halliday-probe
    /// game-peek`). Reads without claiming the slot: a frame may be torn, which is fine for a look.
    pub fn peek(&self) -> Option<(u32, u32, Vec<u8>, Vec<u8>)> {
        let h = self.header();
        // SAFETY: our mapping; plain reads of a published slot.
        unsafe {
            let latest = (*h).latest.load(Ordering::SeqCst);
            if latest == 0 {
                return None;
            }
            let slot = latest as usize - 1;
            let f = &(*h).frames[slot];
            let (w, ht) = (f.width, f.height);
            if !(if f.shared != 0 {
                bridge::fits_shared(w, ht)
            } else {
                bridge::fits(w, ht)
            }) {
                return None;
            }
            let row = w as usize * 4;
            let (bottom_up, bgra) = (f.bottom_up != 0, f.bgra != 0);
            let image = |eye: usize| {
                let src = std::slice::from_raw_parts(
                    self.base.add(bridge::image_offset(slot, eye)),
                    row * ht as usize,
                );
                let mut out = Vec::with_capacity(src.len());
                for r in 0..ht as usize {
                    let r = if bottom_up { ht as usize - 1 - r } else { r };
                    out.extend_from_slice(&src[r * row..(r + 1) * row]);
                }
                if bgra {
                    for px in out.chunks_exact_mut(4) {
                        px.swap(0, 2);
                    }
                }
                out
            };
            let left = image(0);
            let right = if f.shared != 0 {
                left.clone()
            } else {
                image(1)
            };
            Some((w, ht, left, right))
        }
    }
}

impl Drop for GameSide {
    fn drop(&mut self) {
        // SAFETY: our mapping, unmapped once.
        unsafe { munmap(self.base.cast(), bridge::FILE_BYTES) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> Config {
        Config {
            eye_width: 1440,
            eye_height: 1468,
            display_hz: 90.0,
            ipd: 0.063,
            tangents: [[-1.8, 0.95, 1.33, -1.33]; 2],
        }
    }

    #[test]
    fn lower_game_cadence_keeps_fresh_poses_and_coalesces_wakes() {
        let path =
            std::env::temp_dir().join(format!("halliday-cadence-test-{}.shm", std::process::id()));
        let b = GameBridge::create(
            &path,
            Config {
                display_hz: 60.0,
                ..config()
            },
        )
        .unwrap();
        let h = b.header();
        let mut game = GameSide::open(&path).unwrap();
        assert_eq!(game.config().display_hz, 60.0);
        let mut state = State::default();
        state.head.stamp = 1.0;
        b.publish_frame(&state, true);
        assert_eq!(game.poll_frame().unwrap().head.stamp, 1.0);
        state.head.stamp = 2.0;
        b.publish_frame(&state, false);
        assert!(game.poll_frame().is_none());
        assert_eq!(unsafe { bridge::read_state(h) }.unwrap().head.stamp, 2.0);
        // A late consumer sees the latest state once, not a burst of pending game frames.
        for stamp in 3..=6 {
            state.head.stamp = stamp as f32;
            b.publish_frame(&state, true);
        }
        assert_eq!(game.poll_frame().unwrap().head.stamp, 6.0);
        assert!(game.poll_frame().is_none());
        assert_eq!(unsafe { (*h).state_seq.load(Ordering::SeqCst) }, 12);
        assert_eq!(unsafe { (*h).vsync_count.load(Ordering::SeqCst) }, 5);
    }

    #[test]
    fn a_frame_written_by_the_game_side_is_read_back() {
        let path =
            std::env::temp_dir().join(format!("halliday-bridge-test-{}.shm", std::process::id()));
        let b = GameBridge::create(&path, config()).unwrap();
        let h = b.header();
        let mut game = GameSide::open(&path).unwrap();
        assert_eq!(game.config().eye_width, 1440);
        assert_eq!(unsafe { (*h).magic }, bridge::MAGIC);
        assert!(b.begin_read().is_none());

        // The game side, as halliday-vrclient does it.
        unsafe {
            let slot = bridge::free_slot(h);
            let f = &mut *std::ptr::addr_of_mut!((*h).frames[slot]);
            f.seq.fetch_or(1, Ordering::SeqCst);
            *b.base().add(bridge::image_offset(slot, 1)) = 0xAB;
            f.width = 1440;
            f.height = 1468;
            f.bottom_up = 1;
            f.bounds = [[0.0, 0.0, 1.0, 1.0]; 2];
            f.frame_index = 7;
            let s = f.seq.load(Ordering::SeqCst);
            f.seq.store(s + 1, Ordering::SeqCst);
            (*h).latest.store(slot as u32 + 1, Ordering::SeqCst);
        }
        let info = b.begin_read().unwrap();
        assert_eq!(
            (info.width, info.height, info.frame_index, info.bottom_up),
            (1440, 1468, 7, true)
        );
        assert_eq!(unsafe { *b.base().add(info.offsets[1]) }, 0xAB);
        assert_ne!(unsafe { bridge::free_slot(h) }, info.slot);
        b.end_read();

        let mut state = State::default();
        state.head.valid = 1;
        b.publish(&state);
        assert_eq!(unsafe { bridge::read_state(h) }.unwrap().head.valid, 1);
        let seen = game
            .wait_frame(std::time::Duration::from_millis(50))
            .unwrap();
        assert_eq!(seen.head.valid, 1);

        // GameSide::submit, as the probe's game-sim uses it.
        game.submit(seen.head, |eye, px| px[0] = eye as u8 + 1);
        let info = b.begin_read().unwrap();
        assert_eq!(info.frame_index, 1);
        assert_eq!(unsafe { *b.base().add(info.offsets[1]) }, 2);
        b.end_read();

        // An overlay and the scene.
        assert!(b.claim_picture(PictureId::Overlay(1), 0).is_none());
        let mut o = bridge::Overlay::NONE;
        o.used = 1;
        o.visible = 1;
        o.width_m = 1.5;
        game.set_overlay(1, o, 4, 2, |px| px[0] = 0x7F);
        game.set_scene(|s| s.grid = 1);
        let (scene, overlays) = b.scene().unwrap();
        assert_eq!(
            (scene.grid, overlays[1].visible, overlays[1].width_m),
            (1, 1, 1.5)
        );
        let pic = b.claim_picture(PictureId::Overlay(1), 0).unwrap();
        assert_eq!((pic.width, pic.height), (4, 2));
        assert_eq!(unsafe { *b.base().add(pic.offset) }, 0x7F);
        b.release_picture(PictureId::Overlay(1));
        assert!(
            b.claim_picture(PictureId::Overlay(1), pic.seq).is_none(),
            "unchanged"
        );

        // Halliday's requests.
        b.request_quit();
        b.set_dashboard(true);
        b.count_late_vsync();
        assert_eq!(game.requests(), (1, true, 1));

        drop(game);
        drop(b);
        assert!(!path.exists());
    }
}
