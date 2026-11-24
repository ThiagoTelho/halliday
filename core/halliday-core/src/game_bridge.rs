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
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

#[cfg(test)]
#[path = "game_panel_integrity_tests.rs"]
mod panel_integrity_tests;
#[cfg(test)]
#[path = "game_projection_tests.rs"]
mod projection_tests;
#[cfg(test)]
#[path = "game_retirement_tests.rs"]
mod retirement_tests;

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
    fn flock(fd: i32, operation: i32) -> i32;
}
const PROT_READ: i32 = 1;
const PROT_WRITE: i32 = 2;
const MAP_SHARED: i32 = 1;
const LOCK_EX: i32 = 2;
const LOCK_UN: i32 = 8;

/// Serialize public-path mutation across old and new host processes. Keep this
/// tiny lock file permanently: unlinking it would allow two different lock
/// inodes to protect the same path. Game clients need no lock to map the
/// atomically published, completely initialized bridge.
struct BridgePathLock(std::fs::File);
impl BridgePathLock {
    fn path(path: &Path) -> std::io::Result<PathBuf> {
        let name = path.file_name().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "bridge path has no file name",
            )
        })?;
        let mut lock_name = std::ffi::OsString::from(".");
        lock_name.push(name);
        lock_name.push(".lock");
        Ok(path.with_file_name(lock_name))
    }

    fn acquire(path: &Path) -> std::io::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(Self::path(path)?)?;
        loop {
            // SAFETY: an owned, live file descriptor; flock changes only its
            // advisory lock, never the mapping or the file contents.
            if unsafe { flock(file.as_raw_fd(), LOCK_EX) } == 0 {
                return Ok(Self(file));
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}
impl Drop for BridgePathLock {
    fn drop(&mut self) {
        // Closing the descriptor is also a fallback unlock if interrupted.
        unsafe {
            flock(self.0.as_raw_fd(), LOCK_UN);
        }
    }
}

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

/// One independently composited OpenXR quad, with cropped top-down RGBA/BGRA pixels.
pub struct PanelImage<'a> {
    pub pose: bridge::Pose,
    pub width_m: f32,
    pub height_m: f32,
    pub eye_visibility: u32,
    pub flags: u32,
    pub order: u32,
    pub anchor: u32,
    pub color_space: u32,
    pub bgra: bool,
    pub image_width: u32,
    pub image_height: u32,
    pub pixels: &'a [u8],
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
    file_id: (u64, u64),
    published: bool,
}

// SAFETY: the mapping is shared memory; every access goes through the bridge's atomics or plain
// copies that the format allows to race (sequence locks, slot hand-off).
unsafe impl Send for GameBridge {}
unsafe impl Sync for GameBridge {}

impl GameBridge {
    /// Publishes a fresh mapped file at `path`. Never truncate an older host's
    /// file: surviving clients may still have that inode mapped after a crash.
    pub fn create(path: &Path, config: Config) -> std::io::Result<GameBridge> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let name = path.file_name().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "bridge path has no file name",
            )
        })?;
        let mut temporary = std::ffi::OsString::from(".");
        temporary.push(name);
        temporary.push(format!(
            ".{}-{}-{}.tmp",
            std::process::id(),
            crate::time::host_time_ns(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let temporary = path.with_file_name(temporary);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        // Keep an existing regular file's access policy. New files are private
        // to this user, which includes the user's CrossOver child processes.
        let prepare = || -> std::io::Result<_> {
            if let Ok(metadata) = std::fs::symlink_metadata(path)
                && metadata.is_file()
            {
                file.set_permissions(metadata.permissions())?;
            }
            file.set_len(bridge::FILE_BYTES as u64)?;
            let metadata = file.metadata()?;
            Ok((metadata.dev(), metadata.ino()))
        };
        let file_id = match prepare() {
            Ok(id) => id,
            Err(error) => {
                let _ = std::fs::remove_file(&temporary);
                return Err(error);
            }
        };
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
            let error = std::io::Error::last_os_error();
            let _ = std::fs::remove_file(&temporary);
            return Err(error);
        }
        let mut b = GameBridge {
            path: temporary,
            base: base.cast(),
            file_id,
            published: false,
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
            bridge::haptics::initialize(h, crate::time::host_time_ns() as u64);
            bridge::panels::initialize(h);
            bridge::focus::initialize(h);
            bridge::motion::initialize(h);
            bridge::projection::initialize(h);
            (*h).halliday_alive.store(1, Ordering::SeqCst);
            // Last: a game seeing the magic sees a complete header.
            std::ptr::write_volatile(std::ptr::addr_of_mut!((*h).magic), bridge::MAGIC);
        }
        // Clients opening the public path see either the previous complete
        // bridge or this complete bridge, never a zero-length/half-built file.
        // Release the path lock before propagating an error: b's temporary-file
        // cleanup must never try to reacquire a lock owned by this stack frame.
        let publication =
            BridgePathLock::acquire(path).and_then(|_lock| std::fs::rename(&b.path, path));
        publication?;
        b.path = path.to_path_buf();
        b.published = true;
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

    pub fn publish_frame_with_motion(&self, state: &State, notify_game: bool, mask: u32) {
        unsafe { bridge::publish_with_motion(self.header(), state, notify_game, Some(mask)) };
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

    /// Optional transfer metadata of an eye in the slot currently claimed by this reader.
    pub fn frame_color_space(&self, slot: usize, eye: usize) -> u32 {
        if slot >= bridge::SLOTS || eye > 1 {
            return bridge::FRAME_COLOR_LEGACY;
        }
        let h = self.header();
        // SAFETY: a valid mapping; metadata stays immutable while the slot is claimed.
        unsafe {
            if (*h).reading.load(Ordering::SeqCst) != slot as u32 + 1 {
                return bridge::FRAME_COLOR_LEGACY;
            }
            bridge::frame_color_space((*h).frames[slot].texture_type, eye)
        }
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
                initialized: (*h).client_initialized.load(Ordering::SeqCst) == 1,
                quit_acknowledged: (*h).quit_acknowledged.load(Ordering::SeqCst),
            }
        }
    }

    /// Raw producer lease: zero is unowned, one is ready, UINT_MAX is an
    /// initializing owner. Exposed separately to keep the existing Client ABI.
    pub fn client_status(&self) -> u32 {
        unsafe { &*self.header() }
            .client_initialized
            .load(Ordering::SeqCst)
    }

    /// Generation of a ready independent producer, or zero for a legacy,
    /// uninitialized or changing producer. This optional v6 extension lets the
    /// host distinguish two sessions even if their OS process id is unchanged.
    pub fn client_epoch(&self) -> u64 {
        let h = unsafe { &*self.header() };
        if h.client_initialized.load(Ordering::SeqCst) != 1 {
            return 0;
        }
        let pid = unsafe { std::ptr::read_volatile(std::ptr::addr_of!(h.client_pid)) };
        let ext = unsafe { bridge::haptics::extension(self.header()) };
        if pid == 0 || !ext.available() {
            return 0;
        }
        let epoch = ext.client_epoch.load(Ordering::SeqCst);
        if epoch == 0 || ext.owner_pid.load(Ordering::SeqCst) != pid {
            return 0;
        }
        if ext.client_epoch.load(Ordering::SeqCst) != epoch
            || ext.owner_pid.load(Ordering::SeqCst) != pid
            || unsafe { std::ptr::read_volatile(std::ptr::addr_of!(h.client_pid)) } != pid
            || h.client_initialized.load(Ordering::SeqCst) != 1
        {
            return 0;
        }
        epoch
    }

    pub fn panels(&self, slot: usize, frame_index: u64) -> Option<bridge::panels::Snapshot> {
        self.checked_panels(slot, frame_index).ok().flatten()
    }

    /// Legacy frames may omit HLQP. A frame which explicitly depends on it must
    /// never fall back to an ordinary projection when the batch is unavailable.
    pub fn checked_panels(
        &self,
        slot: usize,
        frame_index: u64,
    ) -> Result<Option<bridge::panels::Snapshot>, ()> {
        if slot >= bridge::SLOTS || frame_index == 0 {
            return Err(());
        }
        let h = unsafe { &*self.header() };
        if h.reading.load(Ordering::SeqCst) != slot as u32 + 1 {
            return Err(());
        }
        let frame = &h.frames[slot];
        let sequence = frame.seq.load(Ordering::Acquire);
        if sequence == 0 || sequence & 1 != 0 || frame.frame_index != frame_index {
            return Err(());
        }
        let required = frame.texture_type & bridge::FRAME_LAYER_BATCH != 0;
        let epoch = self.client_epoch();
        let result =
            unsafe { bridge::panels::extension(self.header()) }.read(slot, epoch, frame_index);
        if frame.seq.load(Ordering::Acquire) != sequence || self.client_epoch() != epoch {
            return Err(());
        }
        if required && result.is_none() {
            return Err(());
        }
        Ok(result)
    }

    /// Exact geometry for the frame currently owned by this reader. A required
    /// record that is absent, busy, invalid or from another frame is an error;
    /// the compositor must retain its previous complete frame in that case.
    pub fn projection_geometry(
        &self,
        slot: usize,
        frame_index: u64,
    ) -> Result<Option<bridge::projection::Snapshot>, ()> {
        if slot >= bridge::SLOTS || frame_index == 0 {
            return Err(());
        }
        let h = unsafe { &*self.header() };
        if h.reading.load(Ordering::SeqCst) != slot as u32 + 1 {
            return Err(());
        }
        let frame = &h.frames[slot];
        let sequence = frame.seq.load(Ordering::Acquire);
        if sequence == 0 || sequence & 1 != 0 || frame.frame_index != frame_index {
            return Err(());
        }
        if frame.texture_type & bridge::FRAME_PROJECTION_GEOMETRY == 0 {
            return Ok(None);
        }
        let epoch = self.client_epoch();
        let result = unsafe { bridge::projection::extension(self.header()) }
            .read(slot, epoch, frame_index)
            .ok_or(())?;
        if frame.seq.load(Ordering::Acquire) != sequence || self.client_epoch() != epoch {
            return Err(());
        }
        Ok(Some(result))
    }

    pub fn claim_panel(&self, index: usize, sequence: u32) -> Option<PictureInfo> {
        if index >= bridge::OVERLAYS || sequence == 0 || sequence & 1 != 0 {
            return None;
        }
        let picture = unsafe { &(*self.header()).overlay_pictures[index] };
        if picture.seq.load(Ordering::SeqCst) != sequence
            || picture
                .reading
                .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
        {
            return None;
        }
        let width = picture.width.load(Ordering::Relaxed);
        let height = picture.height.load(Ordering::Relaxed);
        if picture.seq.load(Ordering::SeqCst) != sequence || !panel_fits(width, height) {
            picture.reading.store(0, Ordering::SeqCst);
            return None;
        }
        Some(PictureInfo {
            seq: sequence,
            width,
            height,
            offset: bridge::overlay_offset(index),
        })
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
        unsafe { bridge::focus::extension(self.header()) }.set_dashboard(shown);
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
    /// Stop accepting clients and retire this publication immediately, while
    /// retaining its mapping for any pending GPU/capture lease. Idempotent;
    /// delayed cleanup cannot unlink a newer host at the same public path.
    pub fn retire(&self) {
        unsafe {
            (*self.header()).halliday_alive.store(0, Ordering::SeqCst);
        }
        // A newer host may already have published its own file at this path.
        // Dropping this older mapping must not unlink the replacement.
        let unlink_owned = || {
            if std::fs::symlink_metadata(&self.path)
                .is_ok_and(|metadata| (metadata.dev(), metadata.ino()) == self.file_id)
            {
                let _ = std::fs::remove_file(&self.path);
            }
        };
        if !self.published {
            unlink_owned(); // A unique, unpublished temporary needs no path lock.
        } else if let Ok(_lock) = BridgePathLock::acquire(&self.path) {
            // Checking identity and unlinking must be one critical section:
            // otherwise a new host could rename its file between the two.
            unlink_owned();
        }
    }
}

impl Drop for GameBridge {
    fn drop(&mut self) {
        self.retire();
        // SAFETY: final owner; all submitted GPU/capture leases have released.
        unsafe {
            munmap(self.base.cast(), bridge::FILE_BYTES);
        }
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
        if unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*h).magic)) } != bridge::MAGIC
            || unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*h).version)) }
                != bridge::VERSION
        {
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

    /// The host's negotiated game interval, which can differ from the physical
    /// headset cadence (for example, half rate). Match the Windows peer's bounds.
    pub fn frame_interval_ns(&self) -> Option<u64> {
        let interval = unsafe { (*self.header()).frame_interval_ns.load(Ordering::Acquire) };
        (4_000_000..=50_000_000)
            .contains(&interval)
            .then_some(interval)
    }

    pub fn halliday_alive(&self) -> bool {
        // SAFETY: our mapping.
        unsafe { (*self.header()).halliday_alive.load(Ordering::SeqCst) != 0 }
    }

    /// Latest input without consuming the game's display-frame budget.
    pub fn state_snapshot(&self) -> Option<State> {
        unsafe { bridge::read_state(self.header()) }
    }
    pub fn state_snapshot_with_motion(&self) -> Option<(State, u32)> {
        unsafe { bridge::read_state_with_motion(self.header()) }
    }

    pub fn host_tick(&self) -> u64 {
        unsafe { (*self.header()).vsync_count.load(Ordering::SeqCst) }
    }

    pub fn acknowledge_quit(&self, request: u32) -> bool {
        let h = unsafe { &*self.header() };
        if h.client_pid != std::process::id()
            || h.client_initialized.load(Ordering::SeqCst) != 1
            || h.quit_requests.load(Ordering::SeqCst) != request
        {
            return false;
        }
        h.quit_acknowledged.store(request, Ordering::SeqCst);
        true
    }

    pub(crate) fn raw_header(&self) -> *mut Header {
        self.header()
    }

    pub fn space_epoch(&self) -> u32 {
        let ext = unsafe { bridge::haptics::extension(self.header()) };
        if ext.available() {
            ext.space_epoch.load(Ordering::SeqCst)
        } else {
            0
        }
    }

    pub fn supports_panels(&self) -> bool {
        unsafe { bridge::panels::extension(self.header()) }.available()
    }

    pub fn has_projection_geometry(&self) -> bool {
        unsafe { bridge::projection::extension(self.header()) }.available()
    }

    pub fn client_owner(&self) -> Option<u32> {
        let h = unsafe { &*self.header() };
        (h.client_initialized.load(Ordering::SeqCst) != 0).then_some(h.client_pid)
    }

    /// Claim before writing PID/name. UINT_MAX is a short initialization lease,
    /// respected by the independent Windows peer as well as native clients.
    pub fn register_client_as(&self, app: &str) -> bool {
        let h = unsafe { &*self.header() };
        if !self.halliday_alive()
            || h.client_initialized
                .compare_exchange(0, u32::MAX, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
        {
            return false;
        }
        // A new producer has not rendered yet. Do not expose the preceding
        // session's published slot/counter as its first picture. Keep `reading`:
        // the host GPU can still own that old slot until its copy completes.
        h.latest.store(0, Ordering::SeqCst);
        h.client_frames.store(0, Ordering::SeqCst);
        let mut name = [0u8; 64];
        let n = app.len().min(63);
        name[..n].copy_from_slice(&app.as_bytes()[..n]);
        unsafe {
            (*self.header()).client_pid = std::process::id();
            (*self.header()).app_name = name;
        }
        h.client_heartbeat.fetch_add(1, Ordering::SeqCst);
        h.client_initialized.store(1, Ordering::SeqCst);
        true
    }

    pub fn heartbeat(&self) -> bool {
        let h = unsafe { &*self.header() };
        if h.client_pid == std::process::id() && h.client_initialized.load(Ordering::SeqCst) == 1 {
            h.client_heartbeat.fetch_add(1, Ordering::SeqCst);
            return true;
        }
        false
    }

    pub fn unregister_client(&self) {
        let h = unsafe { &*self.header() };
        if h.client_pid == std::process::id() {
            h.client_initialized.store(0, Ordering::SeqCst);
        }
    }

    /// Claim output for this session only; a recreated session has a new epoch.
    pub fn begin_haptics(&self) -> u64 {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let epoch = (crate::time::host_time_ns() as u64)
            .wrapping_add((std::process::id() as u64) << 32)
            .wrapping_add(NEXT.fetch_add(1, Ordering::SeqCst))
            .max(1);
        let header = unsafe { &*self.header() };
        let ext = unsafe { bridge::haptics::extension(self.header()) };
        if ext.begin(header.client_pid, epoch) {
            unsafe { bridge::focus::extension(self.header()) }.claim(epoch);
            epoch
        } else {
            0
        }
    }

    pub fn end_haptics(&self, epoch: u64) {
        unsafe { bridge::haptics::extension(self.header()) }.end(epoch);
    }

    pub fn send_haptic(
        &self,
        epoch: u64,
        hand: usize,
        duration_ns: u64,
        frequency: f32,
        amplitude: f32,
    ) -> bool {
        let header = unsafe { &*self.header() };
        let ext = unsafe { bridge::haptics::extension(self.header()) };
        let focus = unsafe { bridge::focus::extension(self.header()) };
        let generation = focus.generation();
        let stopping = duration_ns == 0 || amplitude == 0.0;
        if (!stopping
            && (!self.halliday_alive()
                || header.client_initialized.load(Ordering::SeqCst) != 1
                || header.dashboard.load(Ordering::SeqCst) != 0
                || focus.shown()))
            || ext.owner_pid.load(Ordering::SeqCst) != header.client_pid
        {
            return false;
        }
        ext.write_tagged(
            epoch,
            hand,
            duration_ns,
            frequency,
            amplitude,
            focus.available().then_some((focus, generation)),
        )
    }

    pub fn focus_generation(&self) -> u32 {
        unsafe { bridge::focus::extension(self.header()) }.generation()
    }

    /// Waits (at most `timeout`) for Halliday's next display frame; its state.
    pub fn wait_frame(&mut self, timeout: std::time::Duration) -> Option<State> {
        self.wait_frame_with_motion(timeout).map(|(state, _)| state)
    }
    pub fn wait_frame_with_motion(&mut self, timeout: std::time::Duration) -> Option<(State, u32)> {
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
        unsafe { bridge::read_state_with_motion(h) }
    }

    /// Halliday's state if a display frame has passed since the last call, without waiting.
    pub fn poll_frame(&mut self) -> Option<State> {
        self.poll_frame_with_motion().map(|(state, _)| state)
    }
    pub fn poll_frame_with_motion(&mut self) -> Option<(State, u32)> {
        let h = self.header();
        // SAFETY: our mapping.
        let v = unsafe { (*h).vsync_count.load(Ordering::SeqCst) };
        if v == self.last_vsync {
            return None;
        }
        self.last_vsync = v;
        // SAFETY: our mapping.
        unsafe { bridge::read_state_with_motion(h) }
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
        fill: impl FnMut(usize, &mut [u8]),
    ) {
        self.submit_as_with_metadata(
            pose,
            size,
            bottom_up,
            bgra,
            1,
            [bridge::FRAME_COLOR_LEGACY; 2],
            fill,
        );
    }

    /// Explicit transfer metadata for native Vulkan/Metal producers, published atomically with
    /// the pixels and the pose. The low-byte API uses OpenVR ETextureType values.
    #[allow(clippy::too_many_arguments)]
    pub fn submit_as_with_metadata(
        &mut self,
        pose: bridge::Pose,
        size: (u32, u32),
        bottom_up: bool,
        bgra: bool,
        api: u32,
        color_spaces: [u32; 2],
        fill: impl FnMut(usize, &mut [u8]),
    ) {
        let flags = if self.see_through {
            bridge::panels::SOURCE_ALPHA
        } else {
            0
        };
        let _ = self.submit_layers_with_metadata(
            pose,
            size,
            bottom_up,
            bgra,
            api,
            color_spaces,
            Some(0),
            flags,
            &[],
            fill,
        );
    }

    /// Publishes all quad pictures and slot metadata before the stereo frame.
    /// A busy panel read drops the whole new frame without overwriting host-owned pixels.
    #[allow(clippy::too_many_arguments)]
    pub fn submit_layers_with_metadata(
        &mut self,
        pose: bridge::Pose,
        size: (u32, u32),
        bottom_up: bool,
        bgra: bool,
        api: u32,
        color_spaces: [u32; 2],
        projection_order: Option<u32>,
        projection_flags: u32,
        panels: &[PanelImage<'_>],
        fill: impl FnMut(usize, &mut [u8]),
    ) -> bool {
        self.submit_layers_with_geometry(
            pose,
            size,
            bottom_up,
            bgra,
            api,
            color_spaces,
            projection_order,
            projection_flags,
            None,
            panels,
            fill,
        )
    }

    /// Geometry and panels are committed under the same reserved frame slot.
    /// Legacy calls leave the required-geometry flag clear even if an old
    /// record remains in that slot from a previous frame.
    #[allow(clippy::too_many_arguments)]
    pub fn submit_layers_with_geometry(
        &mut self,
        pose: bridge::Pose,
        size: (u32, u32),
        bottom_up: bool,
        bgra: bool,
        api: u32,
        color_spaces: [u32; 2],
        projection_order: Option<u32>,
        projection_flags: u32,
        geometry: Option<&[bridge::projection::View; 2]>,
        panels: &[PanelImage<'_>],
        mut fill: impl FnMut(usize, &mut [u8]),
    ) -> bool {
        let h = self.header();
        let (w, ht) = size;
        if !bridge::fits(w, ht)
            || panels.len() > bridge::OVERLAYS
            || projection_flags & !3 != 0
            || projection_order.is_some_and(|v| v > bridge::OVERLAYS as u32)
        {
            return false;
        }
        let ext = unsafe { bridge::panels::extension(h) };
        let control = unsafe { bridge::haptics::extension(h) };
        let epoch = if control.available() {
            control.client_epoch.load(Ordering::SeqCst)
        } else {
            0
        };
        let projection = unsafe { bridge::projection::extension(h) };
        if let Some(views) = geometry {
            let header = unsafe { &*h };
            if projection_order.is_none()
                || !projection.available()
                || epoch == 0
                || header.client_initialized.load(Ordering::SeqCst) != 1
                || control.owner_pid.load(Ordering::SeqCst) != header.client_pid
                || header.halliday_alive.load(Ordering::SeqCst) == 0
                || views.iter().any(|v| !v.valid())
            {
                return false;
            }
        }
        let needs_batch =
            !panels.is_empty() || projection_order.is_none() || projection_flags & 1 != 0;
        // A truly old host can still show a zero-layer OPAQUE frame as black.
        // Alpha and ordered menus need the composition contract itself.
        if !panels.is_empty() || projection_flags & 1 != 0 {
            let header = unsafe { &*h };
            if !ext.available()
                || epoch == 0
                || header.client_initialized.load(Ordering::SeqCst) != 1
                || control.owner_pid.load(Ordering::SeqCst) != header.client_pid
                || header.halliday_alive.load(Ordering::SeqCst) == 0
            {
                return false;
            }
        }
        let mut records = Vec::with_capacity(panels.len());
        let mut orders = projection_order.map_or(0, |i| 1u32 << i);
        for (index, panel) in panels.iter().enumerate() {
            let record = bridge::panels::Panel {
                pose: panel.pose,
                width_m: panel.width_m,
                height_m: panel.height_m,
                eye_visibility: panel.eye_visibility,
                flags: panel.flags,
                order: panel.order,
                picture_index: index as u32,
                picture_seq: 0,
                color_space: panel.color_space,
                bgra: u32::from(panel.bgra),
                anchor: panel.anchor,
            };
            if !record.valid()
                || !panel_fits(panel.image_width, panel.image_height)
                || panel.pixels.len()
                    != panel.image_width as usize * panel.image_height as usize * 4
                || orders & (1 << panel.order) != 0
            {
                return false;
            }
            orders |= 1 << panel.order;
            records.push(record);
        }
        let mut reserved = Vec::with_capacity(panels.len());
        for i in 0..panels.len() {
            let picture = unsafe { &(*h).overlay_pictures[i] };
            let old = picture.seq.load(Ordering::SeqCst);
            // An abandoned odd sequence can be recovered only when no host owns its pixels.
            picture.seq.store(old | 1, Ordering::SeqCst);
            reserved.push((i, old));
            if picture.reading.load(Ordering::SeqCst) != 0 {
                for &(index, seq) in &reserved {
                    unsafe { &(*h).overlay_pictures[index] }
                        .seq
                        .store(seq, Ordering::SeqCst);
                }
                return false;
            }
        }
        for (i, panel) in panels.iter().enumerate() {
            let picture = unsafe { &(*h).overlay_pictures[i] };
            picture.width.store(panel.image_width, Ordering::Relaxed);
            picture.height.store(panel.image_height, Ordering::Relaxed);
            unsafe {
                std::ptr::copy_nonoverlapping(
                    panel.pixels.as_ptr(),
                    self.base.add(bridge::overlay_offset(i)),
                    panel.pixels.len(),
                );
            }
            let seq = (reserved[i].1 | 1).wrapping_add(1).max(2);
            picture.seq.store(seq, Ordering::Release);
            records[i].picture_seq = seq;
        }
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
            self.frame_index = self.frame_index.wrapping_add(1).max(1);
            f.width = w;
            f.height = ht;
            f.bottom_up = u32::from(bottom_up);
            f.bounds = [[0.0, 0.0, 1.0, 1.0]; 2];
            f.pose = pose;
            f.frame_index = self.frame_index;
            f.texture_type = bridge::frame_texture_metadata(api, color_spaces[0], color_spaces[1]);
            if let Some(views) = geometry {
                if control.client_epoch.load(Ordering::SeqCst) != epoch
                    || !projection.write(slot, epoch, self.frame_index, views)
                {
                    return false;
                }
                f.texture_type |= bridge::FRAME_PROJECTION_GEOMETRY;
            }
            f.shared = 0;
            f.bgra = u32::from(bgra);
            f.see_through = u32::from(self.see_through);
            if ext.available() && epoch != 0 {
                let written = ext.write(
                    slot,
                    epoch,
                    self.frame_index,
                    projection_order.unwrap_or(bridge::panels::NONE),
                    projection_flags,
                    &records,
                );
                if !written {
                    return false;
                }
                if needs_batch {
                    f.texture_type |= bridge::FRAME_LAYER_BATCH;
                }
            }
            let s = f.seq.load(Ordering::SeqCst);
            f.seq.store((s | 1).wrapping_add(1), Ordering::SeqCst);
            (*h).latest.store(slot as u32 + 1, Ordering::SeqCst);
            (*h).client_frames.fetch_add(1, Ordering::SeqCst);
            (*h).client_calls.fetch_add(1, Ordering::Relaxed);
        }
        true
    }
}

fn panel_fits(width: u32, height: u32) -> bool {
    width > 0
        && height > 0
        && width <= bridge::MAX_IMAGE_SIDE
        && height <= bridge::MAX_IMAGE_SIDE
        && width as usize * height as usize * 4 <= bridge::OVERLAY_BYTES
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

    #[test]
    fn panel_frame_is_atomic_with_pixels_and_respects_gpu_read_lease() {
        let path = std::env::temp_dir().join(format!(
            "halliday-panels-{}-{}.shm",
            std::process::id(),
            crate::time::host_time_ns()
        ));
        let host = GameBridge::create(&path, config()).unwrap();
        let mut game = GameSide::view(&path).unwrap();
        assert!(game.register_client_as("panels"));
        let epoch = game.begin_haptics();
        let pixels = [93u8; 4 * 4 * 4];
        let panel = PanelImage {
            pose: bridge::Pose {
                orientation: [0., 0., 0., 1.],
                valid: 1,
                ..Default::default()
            },
            width_m: 1.,
            height_m: 0.5,
            eye_visibility: 2,
            flags: 3,
            order: 1,
            anchor: 1,
            color_space: 2,
            bgra: false,
            image_width: 4,
            image_height: 4,
            pixels: &pixels,
        };
        let submit = |game: &mut GameSide, panels: &[PanelImage<'_>]| {
            game.submit_layers_with_metadata(
                bridge::Pose::default(),
                (8, 8),
                false,
                false,
                2,
                [1, 2],
                Some(0),
                0,
                panels,
                |_, p| p.fill(7),
            )
        };
        assert!(submit(&mut game, &[panel]));
        let frame = host.begin_read().unwrap();
        let batch = host.panels(frame.slot, frame.frame_index).unwrap();
        assert_eq!(
            (batch.epoch, batch.count, batch.projection_order),
            (epoch, 1, 0)
        );
        assert_eq!(
            (
                batch.panels[0].eye_visibility,
                batch.panels[0].anchor,
                batch.panels[0].flags
            ),
            (2, 1, 3)
        );
        let picture = host.claim_panel(0, batch.panels[0].picture_seq).unwrap();
        assert!(
            host.claim_panel(0, batch.panels[0].picture_seq).is_none(),
            "a second claim cannot steal an existing GPU lease"
        );
        assert_eq!(
            unsafe { &(*host.header()).overlay_pictures[0] }
                .reading
                .load(Ordering::SeqCst),
            1
        );
        assert_eq!(unsafe { *host.base().add(picture.offset) }, 93);
        let replacement_pixels = [17u8; 64];
        let replacement = PanelImage {
            pixels: &replacement_pixels,
            pose: batch.panels[0].pose,
            width_m: 1.,
            height_m: 0.5,
            eye_visibility: 0,
            flags: 0,
            order: 1,
            anchor: 0,
            color_space: 1,
            bgra: false,
            image_width: 4,
            image_height: 4,
        };
        assert!(
            !submit(&mut game, &[replacement]),
            "busy GPU picture drops the entire new frame"
        );
        assert_eq!(host.client().frames, 1);
        assert_eq!(
            unsafe { *host.base().add(picture.offset) },
            93,
            "pending read pixels never overwritten"
        );
        host.release_picture(PictureId::Overlay(0));
        host.end_read();
        assert!(submit(&mut game, &[]));
        let next = host.begin_read().unwrap();
        assert_eq!(
            host.panels(next.slot, next.frame_index).unwrap().count,
            0,
            "empty batch clears old quads"
        );
        assert!(
            host.panels(next.slot, frame.frame_index).is_none(),
            "metadata tied to exact projection frame"
        );
        host.end_read();
        game.end_haptics(epoch);
        assert!(
            host.panels(frame.slot, frame.frame_index).is_none(),
            "retired epoch cannot leak panels"
        );
    }

    #[test]
    fn panel_stale_pixel_sequences_and_invalid_metadata_are_rejected() {
        let path = std::env::temp_dir().join(format!(
            "halliday-panel-sequence-{}-{}.shm",
            std::process::id(),
            crate::time::host_time_ns()
        ));
        let host = GameBridge::create(&path, config()).unwrap();
        let mut game = GameSide::view(&path).unwrap();
        assert!(game.register_client_as("panel sequence"));
        game.begin_haptics();
        let data = [42u8; 16];
        let mut panel = PanelImage {
            pose: bridge::Pose {
                orientation: [0., 0., 0., 1.],
                ..Default::default()
            },
            width_m: 1.,
            height_m: 1.,
            eye_visibility: 0,
            flags: 0,
            order: 0,
            anchor: 0,
            color_space: 1,
            bgra: false,
            image_width: 2,
            image_height: 2,
            pixels: &data,
        };
        panel.width_m = f32::NAN;
        assert!(!game.submit_layers_with_metadata(
            Default::default(),
            (8, 8),
            false,
            false,
            2,
            [1, 1],
            None,
            0,
            &[panel],
            |_, _| {}
        ));
        assert_eq!(host.client().frames, 0);
        let make_panel = || PanelImage {
            pose: bridge::Pose {
                orientation: [0., 0., 0., 1.],
                ..Default::default()
            },
            width_m: 1.,
            height_m: 1.,
            eye_visibility: 0,
            flags: 0,
            order: 0,
            anchor: 0,
            color_space: 1,
            bgra: false,
            image_width: 2,
            image_height: 2,
            pixels: &data,
        };
        assert!(game.submit_layers_with_metadata(
            Default::default(),
            (8, 8),
            false,
            false,
            2,
            [1, 1],
            None,
            0,
            &[make_panel()],
            |_, _| {}
        ));
        let first = host.begin_read().unwrap();
        let old = host.panels(first.slot, first.frame_index).unwrap();
        host.end_read();
        assert!(game.submit_layers_with_metadata(
            Default::default(),
            (8, 8),
            false,
            false,
            2,
            [1, 1],
            None,
            0,
            &[make_panel()],
            |_, _| {}
        ));
        assert!(
            host.claim_panel(0, old.panels[0].picture_seq).is_none(),
            "old frame cannot sample a newer quad image"
        );
        let header = unsafe { &*host.header() };
        assert_eq!(header.overlay_pictures[0].reading.load(Ordering::SeqCst), 0);
    }

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
    fn bridge_replacement_isolates_mapped_clients_and_late_host_drop() {
        use std::os::unix::fs::PermissionsExt;
        let path = std::env::temp_dir().join(format!(
            "halliday-replacement-{}-{}.shm",
            std::process::id(),
            crate::time::host_time_ns()
        ));
        let old = GameBridge::create(
            &path,
            Config {
                eye_width: 64,
                ..config()
            },
        )
        .unwrap();
        let mut old_game = GameSide::view(&path).unwrap();
        let old_inode = std::fs::metadata(&path).unwrap().ino();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        let new = GameBridge::create(
            &path,
            Config {
                eye_width: 128,
                ..config()
            },
        )
        .unwrap();
        let new_game = GameSide::view(&path).unwrap();
        assert_ne!(old_inode, std::fs::metadata(&path).unwrap().ino());
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o640
        );
        assert_eq!(
            old_game.config().eye_width,
            64,
            "old mappings retain their complete configuration"
        );
        assert_eq!(new_game.config().eye_width, 128);
        old_game.submit_as(bridge::Pose::default(), (8, 8), false, false, |_, p| {
            p.fill(31)
        });
        assert_eq!(old.client().frames, 1);
        assert_eq!(
            new.client().frames,
            0,
            "an old writer cannot publish into the replacement"
        );
        assert!(new.begin_read().is_none());
        drop(old);
        assert!(
            path.exists(),
            "late old host destruction cannot unlink the replacement"
        );
        assert!(!old_game.halliday_alive());
        assert!(
            new_game.halliday_alive(),
            "old destruction only clears its own mapping"
        );
        assert_eq!(
            old_game.config().eye_width,
            64,
            "old view remains safely mapped after old host exits"
        );
        old_game.submit_as(bridge::Pose::default(), (8, 8), false, false, |_, p| {
            p.fill(44)
        });
        assert_eq!(new.client().frames, 0);
        drop(new);
        assert!(!path.exists());
        assert!(!new_game.halliday_alive());
    }

    #[test]
    fn failed_bridge_publication_preserves_destination_and_removes_temporary() {
        let dir = std::env::temp_dir().join(format!(
            "halliday-publication-failure-{}-{}",
            std::process::id(),
            crate::time::host_time_ns()
        ));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("bridge.shm");
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("keep"), b"original").unwrap();
        assert!(GameBridge::create(&path, config()).is_err());
        assert_eq!(std::fs::read(path.join("keep")).unwrap(), b"original");
        let mut entries: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        entries.sort();
        assert_eq!(
            entries,
            vec![
                std::ffi::OsString::from(".bridge.shm.lock"),
                std::ffi::OsString::from("bridge.shm")
            ],
            "failed publication leaves only the destination and stable lock"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn bridge_publication_and_late_drop_share_one_stable_lock() {
        use std::sync::mpsc;
        use std::time::{Duration, Instant};
        let dir = std::env::temp_dir().join(format!(
            "halliday-publication-lock-{}-{}",
            std::process::id(),
            crate::time::host_time_ns()
        ));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("bridge.shm");
        let old = GameBridge::create(&path, config()).unwrap();
        let old_game = GameSide::view(&path).unwrap();
        let guard = BridgePathLock::acquire(&path).unwrap();
        let lock_path = BridgePathLock::path(&path).unwrap();
        let lock_inode = std::fs::metadata(&lock_path).unwrap().ino();
        let competitor = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&lock_path)
            .unwrap();
        // A second independently opened descriptor cannot bypass the same lock.
        // LOCK_NB is 4 on the Unix platforms supported by this host module.
        assert_eq!(unsafe { flock(competitor.as_raw_fd(), LOCK_EX | 4) }, -1);
        assert_eq!(
            std::io::Error::last_os_error().kind(),
            std::io::ErrorKind::WouldBlock
        );

        let (drop_done, dropped) = mpsc::channel();
        let old_worker = std::thread::spawn(move || {
            drop(old);
            drop_done.send(()).unwrap();
        });
        // Drop clears only the old mapping before acquiring the public lock.
        // Observing this flag is a deterministic barrier into that operation.
        let deadline = Instant::now() + Duration::from_secs(2);
        while old_game.halliday_alive() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(!old_game.halliday_alive());
        assert!(
            matches!(dropped.try_recv(), Err(mpsc::TryRecvError::Empty)),
            "old Drop waits for the public-path mutation lock"
        );

        let new_path = path.clone();
        let (created, receiver) = mpsc::channel();
        let new_worker = std::thread::spawn(move || {
            created
                .send(GameBridge::create(
                    &new_path,
                    Config {
                        eye_width: 128,
                        ..config()
                    },
                ))
                .map_err(|_| ())
                .unwrap();
        });
        assert!(
            matches!(
                receiver.recv_timeout(Duration::from_millis(50)),
                Err(mpsc::RecvTimeoutError::Timeout)
            ),
            "new publication also waits for the same public-path lock"
        );
        drop(guard); // Either contender may acquire first; both orders must be safe.
        let new = receiver
            .recv_timeout(Duration::from_secs(2))
            .unwrap()
            .unwrap();
        dropped.recv_timeout(Duration::from_secs(2)).unwrap();
        old_worker.join().unwrap();
        new_worker.join().unwrap();
        assert!(path.exists(), "late old Drop cannot remove new publication");
        assert_eq!(GameSide::view(&path).unwrap().config().eye_width, 128);
        assert_eq!(
            std::fs::metadata(&lock_path).unwrap().ino(),
            lock_inode,
            "lock inode is stable across publication and destruction"
        );
        drop(new);
        assert!(
            !path.exists(),
            "normal close still removes the public bridge"
        );
        assert_eq!(std::fs::metadata(&lock_path).unwrap().ino(), lock_inode);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn client_epoch_requires_ready_matching_ownership() {
        let path = std::env::temp_dir().join(format!(
            "halliday-client-epoch-{}-{}.shm",
            std::process::id(),
            crate::time::host_time_ns()
        ));
        let host = GameBridge::create(&path, config()).unwrap();
        let side = GameSide::view(&path).unwrap();
        assert_eq!(host.client_epoch(), 0);
        assert!(side.register_client_as("generation fixture"));
        assert_eq!(host.client_epoch(), 0, "legacy producer has no epoch");
        let first = side.begin_haptics();
        assert_ne!(first, 0);
        assert_eq!(host.client_epoch(), first);
        let h = unsafe { &*host.header() };
        let ext = unsafe { bridge::haptics::extension(host.header()) };
        h.client_initialized.store(u32::MAX, Ordering::SeqCst);
        assert!(
            !host.client().initialized,
            "initialization lease is not ready in the host snapshot"
        );
        assert_eq!(
            host.client_epoch(),
            0,
            "initialization lease is not a ready producer"
        );
        h.client_initialized.store(1, Ordering::SeqCst);
        assert!(host.client().initialized);
        ext.owner_pid
            .store(std::process::id().wrapping_add(1), Ordering::SeqCst);
        assert_eq!(
            host.client_epoch(),
            0,
            "stale epoch cannot belong to a different producer"
        );
        ext.owner_pid.store(std::process::id(), Ordering::SeqCst);
        assert_eq!(host.client_epoch(), first);
        side.end_haptics(first);
        assert_eq!(host.client_epoch(), 0);
        let second = side.begin_haptics();
        assert_ne!(first, second);
        assert_eq!(
            host.client_epoch(),
            second,
            "same PID can have a new session generation"
        );
        side.unregister_client();
        assert_eq!(
            host.client_epoch(),
            0,
            "ended producer is unavailable even if epoch remains"
        );
    }

    #[test]
    fn new_producer_clears_previous_picture_but_preserves_host_read_lease() {
        let path = std::env::temp_dir().join(format!(
            "halliday-producer-picture-{}-{}.shm",
            std::process::id(),
            crate::time::host_time_ns()
        ));
        let host = GameBridge::create(&path, config()).unwrap();
        let mut previous = GameSide::view(&path).unwrap();
        assert!(previous.register_client_as("previous producer"));
        previous.submit_as(bridge::Pose::default(), (8, 8), false, false, |_, p| {
            p.fill(5)
        });
        let frame = host.begin_read().unwrap();
        let h = unsafe { &*host.header() };
        let owned_reading = h.reading.load(Ordering::SeqCst);
        assert_eq!(owned_reading, frame.slot as u32 + 1);
        assert_ne!(h.latest.load(Ordering::SeqCst), 0);
        assert_eq!(host.client().frames, 1);
        previous.unregister_client();
        let mut next = GameSide::view(&path).unwrap();
        assert!(next.register_client_as("next producer, same PID"));
        assert_eq!(h.latest.load(Ordering::SeqCst), 0);
        assert_eq!(host.client().frames, 0);
        assert_eq!(h.reading.load(Ordering::SeqCst), owned_reading);
        next.submit_as(bridge::Pose::default(), (8, 8), false, false, |_, p| {
            p.fill(9)
        });
        assert_ne!(
            h.latest.load(Ordering::SeqCst),
            owned_reading,
            "new writer respects pending host GPU read"
        );
        host.end_read();
        let fresh = host.begin_read().unwrap();
        assert_eq!(unsafe { *host.base().add(fresh.offsets[0]) }, 9);
        host.end_read();
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
    fn native_metadata_and_pose_are_published_with_the_pixels() {
        let path = std::env::temp_dir().join(format!(
            "halliday-native-metadata-{}.shm",
            std::process::id()
        ));
        let b = GameBridge::create(&path, config()).unwrap();
        let mut game = GameSide::open(&path).unwrap();
        let pose = bridge::Pose {
            valid: 1,
            stamp: 97.0,
            orientation: [0.0, 0.0, 0.0, 1.0],
            position: [0.1, 1.7, -0.3],
            ..Default::default()
        };
        game.submit_as_with_metadata(
            pose,
            (16, 12),
            false,
            true,
            2,
            [bridge::FRAME_COLOR_LINEAR, bridge::FRAME_COLOR_SRGB],
            |eye, p| p.fill(32 + eye as u8),
        );
        let frame = b.begin_read().unwrap();
        assert_eq!(
            (frame.width, frame.height, frame.bottom_up),
            (16, 12, false)
        );
        assert_eq!(frame.pose, pose);
        assert_eq!(
            b.frame_color_space(frame.slot, 0),
            bridge::FRAME_COLOR_LINEAR
        );
        assert_eq!(b.frame_color_space(frame.slot, 1), bridge::FRAME_COLOR_SRGB);
        unsafe {
            assert_eq!(
                (*b.header()).frames[frame.slot].texture_type & bridge::FRAME_TEXTURE_API_MASK,
                2
            );
            assert_eq!((*b.header()).frames[frame.slot].bgra, 1);
            assert_eq!(*b.base().add(frame.offsets[0]), 32);
            assert_eq!(*b.base().add(frame.offsets[1]), 33);
        }
        b.end_read();
        game.submit_as(pose, (8, 8), true, false, |_, p| p.fill(127));
        let legacy = b.begin_read().unwrap();
        assert_eq!(
            b.frame_color_space(legacy.slot, 0),
            bridge::FRAME_COLOR_LEGACY
        );
        assert_eq!(
            b.frame_color_space(legacy.slot, 1),
            bridge::FRAME_COLOR_LEGACY
        );
        assert_eq!(unsafe { (*b.header()).frames[legacy.slot].texture_type }, 1);
        b.end_read();
        drop(game);
        drop(b); // GameBridge owns and removes its disposable file.
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
        // Transfer tags are opt-in and only readable while the frame is owned.
        unsafe {
            (*h).frames[info.slot].texture_type = bridge::frame_texture_metadata(
                4,
                bridge::FRAME_COLOR_LINEAR,
                bridge::FRAME_COLOR_SRGB,
            );
        }
        assert_eq!(
            b.frame_color_space(info.slot, 0),
            bridge::FRAME_COLOR_LINEAR
        );
        assert_eq!(b.frame_color_space(info.slot, 1), bridge::FRAME_COLOR_SRGB);
        assert_eq!(
            b.frame_color_space(bridge::SLOTS, 0),
            bridge::FRAME_COLOR_LEGACY
        );
        assert_eq!(
            b.frame_color_space(info.slot, 2),
            bridge::FRAME_COLOR_LEGACY
        );
        assert_ne!(unsafe { bridge::free_slot(h) }, info.slot);
        b.end_read();
        assert_eq!(
            b.frame_color_space(info.slot, 0),
            bridge::FRAME_COLOR_LEGACY
        );

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
