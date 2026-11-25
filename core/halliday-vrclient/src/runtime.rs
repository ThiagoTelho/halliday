//! The runtime's state: the bridge file shared with Halliday.app, the poses handed to the game,
//! the controller events, and copying submitted frames into the bridge.

use crate::log::log;
use crate::ovr::{self, TrackedDevicePose};
use crate::win;
use core::cell::UnsafeCell;
use core::sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use halliday_bridge::{self as bridge, Header, State};

static HEADER: AtomicPtr<Header> = AtomicPtr::new(core::ptr::null_mut());
static LEASE_PID: AtomicU32 = AtomicU32::new(0);
static LEASE_EPOCH: AtomicU64 = AtomicU64::new(0);
static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);
static CONNECTION: Locked<()> = Locked::new(());
fn current_lease() -> bridge::producer_lease::Lease {
    bridge::producer_lease::Lease {
        pid: LEASE_PID.load(Ordering::Acquire),
        epoch: LEASE_EPOCH.load(Ordering::Acquire),
    }
}
fn lease_active(h: *const Header, lease: bridge::producer_lease::Lease) -> bool {
    !h.is_null() && unsafe { bridge::producer_lease::active(h, lease) }
}
// Lease nonce only, not an image timestamp. Monotonic across init/reinit in this DLL.
fn fresh_epoch() -> u64 {
    let now = qpc();
    NEXT_EPOCH
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |last| {
            Some(now.max(last.wrapping_add(1).max(1)))
        })
        .unwrap()
        .wrapping_add(1)
        .max(now)
        .max(1)
}
fn activate_mapping(h: *mut Header) -> bool {
    let pid = unsafe { win::GetCurrentProcessId() };
    let Some(lease) = (unsafe { bridge::producer_lease::claim(h, pid, fresh_epoch()) }) else {
        return false;
    };
    LEASE_PID.store(lease.pid, Ordering::Release);
    LEASE_EPOCH.store(lease.epoch, Ordering::Release);
    unsafe {
        (*h).present_state
            .store(bridge::present::OFF, Ordering::SeqCst);
        (*h).present_width.store(0, Ordering::SeqCst);
        (*h).present_height.store(0, Ordering::SeqCst);
        write_app_name(h);
    }
    SHARED.with(|s| {
        s.eyes = 0;
        s.frame_index = 0;
        s.copied_texture = 0;
    });
    HEADER.store(h, Ordering::Release);
    true
}
/// Release only this init's admission. Finish CPU slot writes first, without issuing GPU cleanup.
pub fn disconnect() {
    CONNECTION.with(|_| {
        let h = HEADER.load(Ordering::Acquire);
        let lease = current_lease();
        if !lease_active(h, lease) {
            return;
        }
        // Copy helpers can still own a shared slot. If they stall, preserve ownership and
        // stop heartbeat/callbacks; the host's bounded retirement handles the abandoned lease.
        for _ in 0..100 {
            if JOB_DONE.load(Ordering::Acquire) {
                break;
            }
            unsafe { win::Sleep(1) };
        }
        if !JOB_DONE.load(Ordering::Acquire) {
            LEASE_PID.store(0, Ordering::Release);
            return;
        }
        if unsafe { bridge::producer_lease::release(h, lease) } {
            LEASE_PID.store(0, Ordering::Release);
            LEASE_EPOCH.store(0, Ordering::Release);
            PENDING.with(|p| *p = [NO_PENDING; 2]);
            SHARED.with(|s| s.eyes = 0);
        }
    });
}
/// Producer-side first-eye Submit entry time, captured before readback/window work.
pub fn submit_time_ns() -> i64 {
    let ticks = qpc();
    let mut frequency = 0i64;
    unsafe { win::QueryPerformanceFrequency(&mut frequency) };
    if frequency <= 0 {
        return 0;
    }
    let ns = (ticks as u128) * 1_000_000_000 / (frequency as u128);
    if ns == 0 || ns > i64::MAX as u128 {
        0
    } else {
        ns as i64
    }
}

/// The mapped bridge, if Halliday's file was found.
pub fn header() -> Option<*mut Header> {
    let h = HEADER.load(Ordering::Acquire);
    lease_active(h, current_lease()).then_some(h)
}

/// Halliday is running with the file mapped.
pub fn halliday_alive() -> bool {
    // SAFETY: a mapped header.
    header().is_some_and(|h| unsafe { (*h).halliday_alive.load(Ordering::SeqCst) } != 0)
}

/// A sign of life for Halliday (it shows "starting…" while the game loads).
pub fn touch() {
    if let Some(h) = header() {
        // SAFETY: a mapped header.
        unsafe { (*h).client_calls.fetch_add(1, Ordering::Relaxed) };
    }
}

/// The runtime folder (the parent of `bin`, or of `bin\win64`), as UTF-16 without a NUL.
pub struct Folder {
    pub path: [u16; 1024],
    pub len: usize,
}

impl Folder {
    /// Where this DLL was loaded from, two (or three) levels up.
    pub fn of_this_dll() -> Option<Folder> {
        let mut module: win::HANDLE = core::ptr::null_mut();
        let anchor = Folder::of_this_dll as *const u16;
        // SAFETY: valid out pointer; the address is inside this DLL.
        let ok = unsafe {
            win::GetModuleHandleExW(
                win::GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                    | win::GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                anchor,
                &mut module,
            )
        };
        if ok == 0 {
            return None;
        }
        let mut f = Folder {
            path: [0; 1024],
            len: 0,
        };
        // SAFETY: the buffer holds 1024 units.
        f.len = unsafe { win::GetModuleFileNameW(module, f.path.as_mut_ptr(), 1000) } as usize;
        if f.len == 0 {
            return None;
        }
        f.pop(); // vrclient_x64.dll
        if f.ends_with("win64") {
            f.pop();
        }
        if f.ends_with("bin") {
            f.pop();
        }
        Some(f)
    }

    fn pop(&mut self) {
        while self.len > 0 {
            self.len -= 1;
            if self.path[self.len] == b'\\' as u16 || self.path[self.len] == b'/' as u16 {
                break;
            }
        }
    }

    fn ends_with(&self, name: &str) -> bool {
        let n = name.len();
        if self.len < n + 1 {
            return false;
        }
        let tail = &self.path[self.len - n..self.len];
        tail.iter()
            .zip(name.bytes())
            .all(|(&c, b)| (c as u8).eq_ignore_ascii_case(&b) && c < 128)
            && (self.path[self.len - n - 1] == b'\\' as u16
                || self.path[self.len - n - 1] == b'/' as u16)
    }

    /// `folder\name` with a NUL.
    pub fn join(&self, name: &str) -> [u16; 1100] {
        let mut out = [0u16; 1100];
        out[..self.len].copy_from_slice(&self.path[..self.len]);
        out[self.len] = b'\\' as u16;
        for (i, b) in name.bytes().enumerate() {
            out[self.len + 1 + i] = b as u16;
        }
        out
    }
}

impl core::fmt::Display for Folder {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        for &c in &self.path[..self.len] {
            core::fmt::Write::write_char(f, char::from_u32(c as u32).unwrap_or('?'))?;
        }
        Ok(())
    }
}

/// Availability queries never admit a producer or start a heartbeat.
pub fn is_hmd_present() -> bool {
    if halliday_alive() {
        return true;
    }
    let Some(folder) = Folder::of_this_dll() else {
        return false;
    };
    let path = folder.join(bridge::FILE_NAME);
    unsafe {
        let file = win::CreateFileW(
            path.as_ptr(),
            win::GENERIC_READ,
            win::FILE_SHARE_READ | win::FILE_SHARE_WRITE,
            core::ptr::null_mut(),
            win::OPEN_EXISTING,
            win::FILE_ATTRIBUTE_NORMAL,
            core::ptr::null_mut(),
        );
        if file == win::INVALID_HANDLE_VALUE {
            return false;
        }
        let mapping =
            win::CreateFileMappingW(file, core::ptr::null_mut(), 2, 0, 0, core::ptr::null()); // PAGE_READONLY
        win::CloseHandle(file);
        if mapping.is_null() {
            return false;
        }
        let view = win::MapViewOfFile(mapping, 4, 0, 0, bridge::HEADER_BYTES); // FILE_MAP_READ
        win::CloseHandle(mapping);
        if view.is_null() {
            return false;
        }
        let present = bridge::producer_lease::present(view.cast::<Header>());
        win::UnmapViewOfFile(view);
        present
    }
}

/// Maps Halliday's bridge file from the runtime folder. False if Halliday isn't running.
pub fn connect() -> bool {
    CONNECTION.with(|_| connect_locked())
}
fn connect_locked() -> bool {
    if header().is_some() {
        return true;
    }
    let old = HEADER.load(Ordering::Acquire);
    if !old.is_null() && unsafe { (*old).halliday_alive.load(Ordering::SeqCst) != 0 } {
        return activate_mapping(old);
    }
    let Some(folder) = Folder::of_this_dll() else {
        log!("can't tell where this DLL is");
        return false;
    };
    crate::log::open(&folder.join("vrclient.log"));
    log!("runtime folder {folder}");
    let path = folder.join(bridge::FILE_NAME);
    // SAFETY: NUL-terminated path; plain Win32 calls.
    unsafe {
        let file = win::CreateFileW(
            path.as_ptr(),
            win::GENERIC_READ | win::GENERIC_WRITE,
            win::FILE_SHARE_READ | win::FILE_SHARE_WRITE,
            core::ptr::null_mut(),
            win::OPEN_EXISTING,
            win::FILE_ATTRIBUTE_NORMAL,
            core::ptr::null_mut(),
        );
        if file == win::INVALID_HANDLE_VALUE {
            // Halliday reads this line at its next start (the Games app: "Stopped at launch").
            let exe = exe_name();
            let len = exe.iter().position(|&b| b == 0).unwrap_or(64);
            log!(
                "{}: started while Halliday isn't running (no {} in the runtime folder)",
                core::str::from_utf8(&exe[..len]).unwrap_or("?"),
                bridge::FILE_NAME
            );
            return false;
        }
        let mapping = win::CreateFileMappingW(
            file,
            core::ptr::null_mut(),
            win::PAGE_READWRITE,
            0,
            0,
            core::ptr::null(),
        );
        win::CloseHandle(file);
        if mapping.is_null() {
            log!("CreateFileMapping failed");
            return false;
        }
        let base = win::MapViewOfFile(mapping, win::FILE_MAP_ALL_ACCESS, 0, 0, 0);
        win::CloseHandle(mapping);
        if base.is_null() {
            log!("MapViewOfFile failed");
            return false;
        }
        let h = base as *mut Header;
        if (*h).magic != bridge::MAGIC || (*h).version != bridge::VERSION {
            log!(
                "the bridge file is from another version of Halliday ({:#x} v{})",
                (*h).magic,
                (*h).version
            );
            win::UnmapViewOfFile(base);
            return false;
        }
        if !activate_mapping(h) {
            log!("another producer owns the bridge, or its admission is not ready");
            win::UnmapViewOfFile(base);
            return false;
        }
        crate::scene::start_heartbeat();
        log!(
            "connected to Halliday: eye {}x{} at {} Hz",
            (*h).eye_width,
            (*h).eye_height,
            (*h).display_hz
        );
    }
    true
}

unsafe fn write_app_name(h: *mut Header) {
    // SAFETY: a mapped header.
    unsafe { (*h).app_name = exe_name() };
}

/// The game executable's file name (ASCII, `?` for other characters, NUL-padded).
fn exe_name() -> [u8; 64] {
    let mut name = [0u16; 1024];
    // SAFETY: the buffer holds 1024 units; module NULL is the game's executable.
    let n =
        unsafe { win::GetModuleFileNameW(core::ptr::null_mut(), name.as_mut_ptr(), 1000) } as usize;
    let start = name[..n]
        .iter()
        .rposition(|&c| c == b'\\' as u16 || c == b'/' as u16)
        .map_or(0, |i| i + 1);
    let mut out = [0u8; 64];
    for (o, &c) in out.iter_mut().take(63).zip(&name[start..n]) {
        *o = if c < 128 { c as u8 } else { b'?' };
    }
    out
}

/// A tiny lock for the state the game's threads share.
pub struct Locked<T> {
    busy: AtomicBool,
    value: UnsafeCell<T>,
}

unsafe impl<T> Sync for Locked<T> {}

impl<T> Locked<T> {
    pub const fn new(value: T) -> Self {
        Locked {
            busy: AtomicBool::new(false),
            value: UnsafeCell::new(value),
        }
    }

    pub fn with<R>(&self, f: impl FnOnce(&mut T) -> R) -> R {
        while self.busy.swap(true, Ordering::Acquire) {
            core::hint::spin_loop();
        }
        // SAFETY: exclusive while `busy` is held.
        let r = f(unsafe { &mut *self.value.get() });
        self.busy.store(false, Ordering::Release);
        r
    }
}

/// What the game was last told.
pub struct Shared {
    pub state: State,
    /// The head pose of the last `WaitGetPoses` (the one the next frame is rendered from).
    pub render_head: bridge::Pose,
    /// The seated universe's origin in the standing one.
    pub seated_zero: [f32; 3],
    pub seated_set: bool,
    /// Events: devices announced, and buttons as last reported per controller.
    pub announced: u32,
    pub reported_pressed: [u64; 2],
    pub reported_touched: [u64; 2],
    /// The frame being submitted: slot + 1 and which eyes are in.
    pub slot: u32,
    pub eyes: u32,
    /// The texture of the eye already submitted for this frame (both eyes may share one).
    pub copied_texture: usize,
    pub frame_index: u64,
    pub submit_time_ns: i64,
    pub submit_lease: bridge::producer_lease::Lease,
}

pub static SHARED: Locked<Shared> = Locked::new(Shared {
    state: State {
        head: bridge::Pose {
            position: [0.0, 1.65, 0.0],
            valid: 0,
            orientation: [0.0, 0.0, 0.0, 1.0],
            velocity: [0.0; 3],
            _pad0: 0.0,
            angular_velocity: [0.0; 3],
            stamp: 0.0,
        },
        controllers: [halliday_bridge::Controller {
            pose: bridge::Pose {
                position: [0.0; 3],
                valid: 0,
                orientation: [0.0, 0.0, 0.0, 1.0],
                velocity: [0.0; 3],
                _pad0: 0.0,
                angular_velocity: [0.0; 3],
                stamp: 0.0,
            },
            pressed: 0,
            touched: 0,
            axes: [[0.0; 2]; 5],
            connected: 0,
            packet: 0,
        }; 2],
    },
    render_head: bridge::Pose {
        position: [0.0, 1.65, 0.0],
        valid: 0,
        orientation: [0.0, 0.0, 0.0, 1.0],
        velocity: [0.0; 3],
        _pad0: 0.0,
        angular_velocity: [0.0; 3],
        stamp: 0.0,
    },
    seated_zero: [0.0, 1.65, 0.0],
    seated_set: false,
    announced: 0,
    reported_pressed: [0; 2],
    reported_touched: [0; 2],
    slot: 0,
    eyes: 0,
    copied_texture: 0,
    frame_index: 0,
    submit_time_ns: 0,
    submit_lease: bridge::producer_lease::Lease { pid: 0, epoch: 0 },
});

pub static TRACKING_SPACE: AtomicU32 = AtomicU32::new(1); // standing
static LAST_VSYNC: AtomicU64 = AtomicU64::new(0);
static LAST_VSYNC_QPC: AtomicU64 = AtomicU64::new(0);

fn qpc() -> u64 {
    let mut c = 0i64;
    // SAFETY: valid out pointer.
    unsafe { win::QueryPerformanceCounter(&mut c) };
    c as u64
}

/// Keeps this DLL loaded until the process ends, before it starts threads of its own (the
/// heartbeat, the copy threads): Unity loads and unloads the runtime several times while it
/// starts, and a thread left running in an unloaded DLL crashes the game.
pub fn pin_this_dll() {
    static PINNED: AtomicBool = AtomicBool::new(false);
    if PINNED.swap(true, Ordering::SeqCst) {
        return;
    }
    let mut module: win::HANDLE = core::ptr::null_mut();
    // SAFETY: valid out pointer; the address is inside this DLL.
    let ok = unsafe {
        win::GetModuleHandleExW(
            win::GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win::GET_MODULE_HANDLE_EX_FLAG_PIN,
            pin_this_dll as *const u16,
            &mut module,
        )
    };
    if ok == 0 {
        log!("couldn't keep the runtime loaded: its threads may outlive it");
    }
}

/// Waits for Halliday's next display frame (at most ~40 ms), then reads its state.
pub fn wait_for_frame() -> State {
    let called = qpc();
    if let Some(h) = header() {
        let last = LAST_VSYNC.load(Ordering::Relaxed);
        for _ in 0..40 {
            // SAFETY: a mapped header.
            let v = unsafe { (*h).vsync_count.load(Ordering::SeqCst) };
            if v != last {
                LAST_VSYNC.store(v, Ordering::Relaxed);
                LAST_VSYNC_QPC.store(qpc(), Ordering::Relaxed);
                break;
            }
            // SAFETY: plain call.
            unsafe { win::Sleep(1) };
        }
    } else {
        // SAFETY: plain call.
        unsafe { win::Sleep(11) };
    }
    // The game's frame is seen a couple of display frames after this pose: render it from where
    // the head will be by then (Halliday reprojects from this pose to the latest).
    let mut state = latest_state();
    let dt = crate::scene::prediction_seconds();
    state.head = crate::scene::predict(&state.head, dt);
    for c in &mut state.controllers {
        c.pose = crate::scene::predict(&c.pose, dt);
    }
    let returned = qpc();
    let late = crate::scene::late_vsyncs();
    crate::scene::FRAMES.with(|f| {
        f.previous_wait = f.wait_called;
        f.wait_called = called;
        f.wait_returned = returned;
        f.vsync = LAST_VSYNC_QPC.load(Ordering::Relaxed);
        f.index = f.index.wrapping_add(1);
        f.late_since = late.saturating_sub(f.late_at_start) as u32;
        f.late_at_start = late;
        f.pose = state.head;
    });
    SHARED.with(|s| {
        s.state = state;
        s.render_head = state.head;
        if !s.seated_set && state.head.valid != 0 {
            s.seated_zero = state.head.position;
            s.seated_set = true;
        }
    });
    state
}

/// Halliday's newest state, without waiting.
pub fn latest_state() -> State {
    // SAFETY: a mapped header.
    let fresh = header().and_then(|h| unsafe { bridge::read_state(h) });
    match fresh {
        Some(s) => s,
        None => SHARED.with(|s| s.state),
    }
}

pub fn vsync_info() -> (f32, u64) {
    let qpc_then = LAST_VSYNC_QPC.load(Ordering::Relaxed);
    let mut f = 0i64;
    // SAFETY: valid out pointer.
    unsafe { win::QueryPerformanceFrequency(&mut f) };
    let since = (qpc().wrapping_sub(qpc_then)) as f64 / f.max(1) as f64;
    (since.min(1.0) as f32, LAST_VSYNC.load(Ordering::Relaxed))
}

/// The offset to subtract from standing positions for `universe`.
pub fn universe_offset(universe: u32) -> [f32; 3] {
    if universe == ovr::UNIVERSE_SEATED {
        SHARED.with(|s| s.seated_zero)
    } else {
        [0.0; 3]
    }
}

/// Poses for every device index, from `state`.
pub fn fill_poses(state: &State, universe: u32, out: *mut TrackedDevicePose, count: u32) {
    if out.is_null() {
        return;
    }
    let offset = universe_offset(universe);
    for i in 0..count.min(ovr::MAX_DEVICES) {
        let pose = match i {
            ovr::HMD => ovr::device_pose(&state.head, true, offset),
            ovr::LEFT | ovr::RIGHT => {
                let c = &state.controllers[(i - 1) as usize];
                ovr::device_pose(&c.pose, c.connected != 0, offset)
            }
            _ => ovr::INVALID_POSE,
        };
        // SAFETY: the game's array holds `count` poses.
        unsafe { out.add(i as usize).write(pose) };
    }
}

/// The next event for the game: devices first, then controller buttons as they change.
pub fn next_event() -> Option<(u32, u32, u32)> {
    if let Some(e) = crate::scene::next_event() {
        return Some(e);
    }
    let state = latest_state();
    SHARED.with(|s| {
        while s.announced < 3 {
            let d = s.announced;
            s.announced += 1;
            if d == ovr::HMD || state.controllers[(d - 1) as usize].connected != 0 {
                return Some((ovr::EVENT_DEVICE_ACTIVATED, d, 0));
            }
        }
        for c in 0..2 {
            let now = &state.controllers[c];
            for (reported, current, on, off) in [
                (
                    &mut s.reported_pressed[c],
                    now.pressed,
                    ovr::EVENT_BUTTON_PRESS,
                    ovr::EVENT_BUTTON_UNPRESS,
                ),
                (
                    &mut s.reported_touched[c],
                    now.touched,
                    ovr::EVENT_BUTTON_TOUCH,
                    ovr::EVENT_BUTTON_UNTOUCH,
                ),
            ] {
                let changed = *reported ^ current;
                if changed != 0 {
                    let bit = changed.trailing_zeros();
                    *reported ^= 1 << bit;
                    let kind = if current & (1 << bit) != 0 { on } else { off };
                    return Some((kind, c as u32 + 1, bit));
                }
            }
        }
        None
    })
}

static WARNED: AtomicU32 = AtomicU32::new(0);

pub fn warn_once(bit: u32, args: core::fmt::Arguments) {
    if WARNED.fetch_or(1 << bit, Ordering::Relaxed) & (1 << bit) == 0 {
        crate::log::write(args);
    }
}

/// A frame whose eyes are being read back; published when the next one starts (or at once, when
/// it was copied straight into a slot).
#[derive(Clone, Copy)]
struct Pending {
    active: bool,
    kind: i32,
    width: u32,
    height: u32,
    bgra: bool,
    /// Both eyes in one texture: read once, into the left eye's area.
    shared: bool,
    bounds: [[f32; 4]; 2],
    pose: bridge::Pose,
    /// The frame's number (`Frame::frame_index`), given when its second eye is submitted.
    index: u64,
    source_time_ns: i64,
    lease: bridge::producer_lease::Lease,
    /// Copied straight into `slot` (no pixel buffers: the old, waiting way).
    direct: Option<usize>,
}

const NO_PENDING: Pending = Pending {
    active: false,
    kind: 0,
    width: 0,
    height: 0,
    bgra: false,
    shared: false,
    bounds: [[0.0; 4]; 2],
    pose: bridge::Pose {
        position: [0.0; 3],
        valid: 0,
        orientation: [0.0, 0.0, 0.0, 1.0],
        velocity: [0.0; 3],
        _pad0: 0.0,
        angular_velocity: [0.0; 3],
        stamp: 0.0,
    },
    index: 0,
    source_time_ns: 0,
    lease: bridge::producer_lease::Lease { pid: 0, epoch: 0 },
    direct: None,
};

/// Time spent mapping (waiting for the data) and copying rows, in performance-counter ticks
/// (`gl.rs` and `d3d11.rs` add to them; logged with the frame timings).
pub static MAP_TICKS: core::sync::atomic::AtomicU64 = core::sync::atomic::AtomicU64::new(0);
pub static COPY_TICKS: core::sync::atomic::AtomicU64 = core::sync::atomic::AtomicU64::new(0);

pub fn now_ticks() -> u64 {
    qpc()
}

/// [frame parity].
static PENDING: Locked<[Pending; 2]> = Locked::new([NO_PENDING; 2]);

/// Copy timings, logged every 600 frames: the time spent starting copies on the game's thread,
/// finishing them a frame later, and how often frames came.
struct Timing {
    issue: u64,
    finish: u64,
    max: u64,
    frames: u32,
    window_start: u64,
}

static TIMING: Locked<Timing> = Locked::new(Timing {
    issue: 0,
    finish: 0,
    max: 0,
    frames: 0,
    window_start: 0,
});

pub fn ticks_to_ms(t: u64) -> f64 {
    t as f64 / ticks_per_ms()
}

fn ticks_per_ms() -> f64 {
    let mut f = 0i64;
    // SAFETY: valid out pointer.
    unsafe { win::QueryPerformanceFrequency(&mut f) };
    f.max(1) as f64 / 1000.0
}

/// Writes `p`'s metadata into `slot` and makes it the newest frame.
fn publish(h: *mut Header, slot: usize, p: &Pending) {
    if !lease_active(h, p.lease) {
        return;
    }
    // SAFETY: a mapped header; the slot is this side's until published.
    let frame = unsafe { &mut *core::ptr::addr_of_mut!((*h).frames[slot]) };
    let index = p.index;
    frame.width = p.width;
    frame.height = p.height;
    frame.bounds = p.bounds;
    frame.pose = p.pose;
    frame.frame_index = index;
    frame.bottom_up = (p.kind == ovr::TEXTURE_OPENGL) as u32;
    frame.texture_type = p.kind as u32;
    let times = unsafe { bridge::frame_timing::extension(h) };
    times.clear(slot);
    if times.write(
        slot,
        p.lease.epoch,
        index,
        bridge::frame_timing::Time {
            nanoseconds: p.source_time_ns,
            clock_kind: bridge::frame_timing::SUBMIT_MONOTONIC_NS,
        },
    ) && lease_active(h, p.lease)
    {
        frame.texture_type |= bridge::FRAME_SOURCE_TIMING;
    }
    frame.shared = p.shared as u32;
    frame.bgra = p.bgra as u32;
    frame.see_through = 0;
    let seq = frame.seq.load(Ordering::SeqCst);
    frame.seq.store((seq | 1).wrapping_add(1), Ordering::SeqCst);
    // SAFETY: a mapped header.
    let n = unsafe {
        (*h).latest.store(slot as u32 + 1, Ordering::SeqCst);
        (*h).client_frames.fetch_add(1, Ordering::SeqCst) + 1
    };
    if n == 1 {
        let what = if p.kind == ovr::TEXTURE_OPENGL {
            "OpenGL"
        } else {
            "Direct3D 11"
        };
        log!(
            "first frame: {what}, {}x{}{}{}",
            p.width,
            p.height,
            if p.shared {
                ", both eyes in one texture"
            } else {
                ""
            },
            if p.direct.is_some() {
                ", copied directly (no pixel buffers)"
            } else {
                ", read back a frame later"
            }
        );
    }
    if n % 600 == 0 {
        let now = qpc();
        let per_ms = ticks_per_ms();
        let (issue, finish, max, rate) = TIMING.with(|t| {
            let frames = t.frames.max(1) as f64;
            let r = (
                t.issue as f64 / frames / per_ms,
                t.finish as f64 / frames / per_ms,
                t.max as f64 / per_ms,
                if t.window_start != 0 {
                    600.0 * 1000.0 / (now.wrapping_sub(t.window_start) as f64 / per_ms)
                } else {
                    0.0
                },
            );
            *t = Timing {
                issue: 0,
                finish: 0,
                max: 0,
                frames: 0,
                window_start: now,
            };
            r
        });
        let frames = 600.0;
        let mapping = MAP_TICKS.swap(0, Ordering::Relaxed) as f64 / frames / per_ms;
        let copying = COPY_TICKS.swap(0, Ordering::Relaxed) as f64 / frames / per_ms;
        log!(
            "  mapping {mapping:.2} ms a frame on the game's thread; copying rows {copying:.2} ms on the copy thread"
        );
        let (shaders, failed) = crate::glfix::shader_counts();
        log!(
            "frame {n}: on the game's thread {:.2} ms a frame (starting copies {issue:.2}, finishing {finish:.2}; max {max:.2}), {rate:.1} frames/s; shaders {shaders}, {failed} failed",
            issue + finish
        );
    }
}

/// A copy for the worker thread: the mapped images of a frame, into a slot, then published.
#[derive(Clone, Copy)]
struct Job {
    header: *mut Header,
    slot: usize,
    pending: Pending,
    /// Each eye's mapped rows and their pitch (one when both eyes share a texture).
    source: [(*const u8, usize); 2],
    eyes: usize,
    /// The frame parity whose buffers are mapped (unmapped on the game's thread afterwards).
    parity: usize,
}

unsafe impl Send for Job {}

static JOB: Locked<Option<Job>> = Locked::new(None);
/// The job's copy is done (or there is none in flight).
static JOB_DONE: AtomicBool = AtomicBool::new(true);
static WAKE: AtomicPtr<core::ffi::c_void> = AtomicPtr::new(core::ptr::null_mut());

/// Copy threads in all (the worker and its helpers): one thread copying out of mapped GPU memory
/// under Rosetta managed ~2.8 GB/s, so a large frame (33 MB for the Unity game) is copied in stripes.
const STRIPES: usize = 4;
static HELPER_WAKE: [AtomicPtr<core::ffi::c_void>; STRIPES - 1] =
    [const { AtomicPtr::new(core::ptr::null_mut()) }; STRIPES - 1];
static HELPER_DONE: [AtomicBool; STRIPES - 1] = [const { AtomicBool::new(true) }; STRIPES - 1];
/// Helpers started (the first `HELPERS` of them).
static HELPERS: AtomicUsize = AtomicUsize::new(0);

/// Copies stripe `k` of `n` (a band of rows of each eye) of the job into its slot.
fn copy_stripe(h: *mut Header, job: &Job, k: usize, n: usize) {
    if !lease_active(h, job.pending.lease) {
        return;
    }
    let row = job.pending.width as usize * 4;
    let height = job.pending.height as usize;
    let (y0, y1) = (height * k / n, height * (k + 1) / n);
    for (eye, &(src, pitch)) in job.source.iter().enumerate().take(job.eyes) {
        // SAFETY: the slot's image area for this eye, and the mapped rows the game's thread
        // keeps mapped until the job is done.
        unsafe {
            let dst = (h as *mut u8).add(bridge::image_offset(job.slot, eye));
            if pitch == row {
                crate::fast_copy(dst.add(y0 * row), src.add(y0 * row), row * (y1 - y0));
            } else {
                for y in y0..y1 {
                    crate::fast_copy(dst.add(y * row), src.add(y * pitch), row);
                }
            }
        }
    }
}

/// The worker: copies each job's rows into the bridge (with its helpers) and publishes the
/// frame, off the game's render thread.
unsafe extern "system" fn worker(_: *mut core::ffi::c_void) -> u32 {
    loop {
        // SAFETY: our event; waits for the next job.
        unsafe { win::WaitForSingleObject(WAKE.load(Ordering::Acquire), 0xFFFF_FFFF) };
        let Some(job) = JOB.with(|j| *j) else {
            continue;
        };
        let h = job.header;
        if !lease_active(h, job.pending.lease) {
            JOB_DONE.store(true, Ordering::Release);
            continue;
        }
        let t0 = qpc();
        let helpers = HELPERS.load(Ordering::Acquire);
        for k in 0..helpers {
            HELPER_DONE[k].store(false, Ordering::Release);
            // SAFETY: the helper's event.
            unsafe { win::SetEvent(HELPER_WAKE[k].load(Ordering::Acquire)) };
        }
        copy_stripe(h, &job, 0, helpers + 1);
        for done in &HELPER_DONE[..helpers] {
            while !done.load(Ordering::Acquire) {
                core::hint::spin_loop();
            }
        }
        COPY_TICKS.fetch_add(qpc().wrapping_sub(t0), Ordering::Relaxed);
        publish(h, job.slot, &job.pending);
        JOB_DONE.store(true, Ordering::Release);
    }
}

/// A helper: copies stripe `k` of the worker's job when woken.
unsafe extern "system" fn helper(arg: *mut core::ffi::c_void) -> u32 {
    let k = arg as usize;
    loop {
        // SAFETY: this helper's event.
        unsafe {
            win::WaitForSingleObject(HELPER_WAKE[k - 1].load(Ordering::Acquire), 0xFFFF_FFFF)
        };
        if let Some(job) = JOB.with(|j| *j) {
            copy_stripe(job.header, &job, k, HELPERS.load(Ordering::Acquire) + 1);
        }
        HELPER_DONE[k - 1].store(true, Ordering::Release);
    }
}

/// Starts the worker the first time; false if it can't be.
fn worker_ready() -> bool {
    if !WAKE.load(Ordering::Acquire).is_null() {
        return true;
    }
    pin_this_dll();
    // SAFETY: plain Win32 calls.
    unsafe {
        let event = win::CreateEventW(core::ptr::null_mut(), 0, 0, core::ptr::null());
        if event.is_null() {
            return false;
        }
        WAKE.store(event, Ordering::Release);
        let thread = win::CreateThread(
            core::ptr::null_mut(),
            0,
            worker,
            core::ptr::null_mut(),
            0,
            core::ptr::null_mut(),
        );
        if thread.is_null() {
            log!("couldn't start the copy thread: copying on the game's thread");
            WAKE.store(core::ptr::null_mut(), Ordering::Release);
            return false;
        }
        win::CloseHandle(thread);
        for k in 1..STRIPES {
            let event = win::CreateEventW(core::ptr::null_mut(), 0, 0, core::ptr::null());
            if event.is_null() {
                break;
            }
            HELPER_WAKE[k - 1].store(event, Ordering::Release);
            let thread = win::CreateThread(
                core::ptr::null_mut(),
                0,
                helper,
                k as *mut core::ffi::c_void,
                0,
                core::ptr::null_mut(),
            );
            if thread.is_null() {
                break;
            }
            win::CloseHandle(thread);
            HELPERS.store(k, Ordering::Release);
        }
    }
    true
}

/// Waits for the worker's job (if any) and unmaps its buffers, on the game's thread.
fn settle_job() {
    if JOB.with(|j| j.is_none()) {
        return;
    }
    while !JOB_DONE.load(Ordering::Acquire) {
        // SAFETY: plain call.
        unsafe { win::Sleep(0) };
    }
    if let Some(job) = JOB.with(|j| j.take()) {
        for eye in 0..job.eyes {
            // SAFETY: on the game's render thread, as `map` was.
            unsafe {
                if job.pending.kind == ovr::TEXTURE_OPENGL {
                    crate::gl::unmap(job.parity, eye);
                } else {
                    crate::d3d11::unmap(job.parity, eye);
                }
            }
        }
    }
}

/// Maps the previous frame's images (read back since) and hands them to the worker, which copies
/// them into a free slot and publishes the frame.
fn finish_previous(h: *mut Header, parity: usize) {
    settle_job();
    let p = PENDING.with(|p| core::mem::replace(&mut p[parity], NO_PENDING));
    if !p.active || p.direct.is_some() || !lease_active(h, p.lease) {
        return;
    }
    if !p.shared && !bridge::fits(p.width, p.height) {
        // Two separate textures, each too large for its eye's area.
        warn_once(
            1,
            format_args!(
                "[halliday-vrclient] eye textures {}x{} are larger than the bridge holds",
                p.width, p.height
            ),
        );
        return;
    }
    // SAFETY: a mapped header.
    let slot = unsafe { bridge::free_slot(h) };
    // SAFETY: as above; the slot is this side's until published.
    unsafe { (*h).frames[slot].seq.fetch_or(1, Ordering::SeqCst) };
    let eyes = if p.shared { 1 } else { 2 };
    let bytes = p.width as usize * p.height as usize * 4;
    let mut source = [(core::ptr::null::<u8>(), 0usize); 2];
    for (eye, src) in source.iter_mut().enumerate().take(eyes) {
        // SAFETY: on the game's render thread, as `issue` was.
        let mapped = unsafe {
            if p.kind == ovr::TEXTURE_OPENGL {
                crate::gl::map(parity, eye, bytes).map(|ptr| (ptr, p.width as usize * 4))
            } else {
                crate::d3d11::map(parity, eye)
            }
        };
        match mapped {
            Some(m) => *src = m,
            None => {
                for e in 0..eye {
                    // SAFETY: as above.
                    unsafe {
                        if p.kind == ovr::TEXTURE_OPENGL {
                            crate::gl::unmap(parity, e);
                        } else {
                            crate::d3d11::unmap(parity, e);
                        }
                    }
                }
                return; // left odd: never published
            }
        }
    }
    let job = Job {
        header: h,
        slot,
        pending: p,
        source,
        eyes,
        parity,
    };
    if worker_ready() {
        JOB.with(|j| *j = Some(job));
        JOB_DONE.store(false, Ordering::Release);
        // SAFETY: our event.
        unsafe { win::SetEvent(WAKE.load(Ordering::Acquire)) };
    } else {
        // No thread: copy here, then unmap.
        let row = p.width as usize * 4;
        for (eye, &(src, pitch)) in source.iter().enumerate().take(eyes) {
            // SAFETY: as in `worker`.
            unsafe {
                let dst = (h as *mut u8).add(bridge::image_offset(slot, eye));
                for y in 0..p.height as usize {
                    crate::fast_copy(dst.add(y * row), src.add(y * pitch), row);
                }
            }
        }
        JOB.with(|j| *j = Some(job));
        JOB_DONE.store(true, Ordering::Release);
        publish(h, slot, &p);
        settle_job();
    }
}

/// Where the frame being submitted goes (decided at its first eye: the window, the bridge or
/// both; present.rs), and the route of the frame before it.
static ROUTE: Locked<(crate::present::Route, crate::present::Route)> =
    Locked::new((crate::present::Route::Bridge, crate::present::Route::Bridge));

/// Frames go only through the window from now on: the copies under way are dropped.
fn drop_copies() {
    settle_job();
    PENDING.with(|p| *p = [NO_PENDING; 2]);
}

/// One eye of the game's frame. Through the window (present.rs) when Halliday captures one;
/// otherwise, and while the window starts, copied into the bridge: the frame's first eye finishes
/// and publishes the previous frame, and each eye then starts the GPU copy of its texture,
/// collected a frame later (`gl.rs`, `d3d11.rs`). OpenGL rows are bottom-up, Direct3D 11's
/// top-down.
pub fn submit(eye: u32, texture: &ovr::Texture, bounds: Option<[f32; 4]>, flags: i32) -> i32 {
    use crate::present::Route;
    let source_submit_time = submit_time_ns();
    let Some(h) = header() else {
        return ovr::COMPOSITOR_NONE;
    };
    let kind = texture.kind;
    if kind != ovr::TEXTURE_OPENGL && kind != ovr::TEXTURE_DIRECTX {
        warn_once(
            3,
            format_args!(
                "[halliday-vrclient] texture type {kind} isn't supported yet (OpenGL and Direct3D 11 are)"
            ),
        );
        return ovr::COMPOSITOR_INVALID_TEXTURE;
    }
    if kind == ovr::TEXTURE_OPENGL && flags & ovr::SUBMIT_GL_RENDER_BUFFER != 0 {
        warn_once(
            4,
            format_args!("[halliday-vrclient] render buffers aren't supported yet"),
        );
        return ovr::COMPOSITOR_INVALID_TEXTURE;
    }
    let eye = eye.min(1) as usize;
    let bounds = bounds.unwrap_or([0.0, 0.0, 1.0, 1.0]);
    if kind == ovr::TEXTURE_DIRECTX {
        crate::d3d11::note_submit_thread();
    }
    let handle = texture.handle as usize;
    let first = SHARED.with(|s| {
        let first = s.eyes == 0;
        if first {
            s.submit_time_ns = source_submit_time;
            s.submit_lease = current_lease();
        }
        first
    });
    let route = if first {
        let route = crate::present::route(h, kind);
        let before = ROUTE.with(|r| {
            let before = r.0;
            *r = (route, before);
            before
        });
        if route == Route::Window && before != Route::Window {
            drop_copies();
        }
        route
    } else {
        ROUTE.with(|r| r.0)
    };
    let start = qpc();
    if route != Route::Bridge {
        crate::present::keep(eye, handle, bounds);
    }
    let parity = SHARED.with(|s| s.slot as usize & 1);
    let mut p = PENDING.with(|p| p[parity]);
    let finished;
    if route != Route::Window {
        let shared = SHARED.with(|s| {
            let shared = !first && s.copied_texture == handle;
            s.copied_texture = handle;
            shared
        });
        if first {
            finish_previous(h, parity ^ 1);
        }
        finished = qpc();
        if first {
            p = NO_PENDING;
            p.kind = kind;
        }
        if shared {
            p.shared = true;
        } else {
            // SAFETY: on the game's render thread, with its context current (OpenGL) or owning
            // the immediate context (Direct3D 11).
            let size = unsafe {
                if kind == ovr::TEXTURE_OPENGL {
                    match crate::gl::issue(handle as u32, parity, eye) {
                        Some((w, h)) => Some((w, h, crate::gl::READ_BGRA)),
                        None if p.direct.is_some() || first => {
                            // No pixel buffers (or they failed): straight into a slot, as before.
                            let slot = *p.direct.get_or_insert_with(|| {
                                let slot = bridge::free_slot(h);
                                (*h).frames[slot].seq.fetch_or(1, Ordering::SeqCst);
                                slot
                            });
                            let dst = (h as *mut u8).add(bridge::image_offset(slot, eye));
                            crate::gl::copy_now(handle as u32, eye, dst)
                                .map(|(w, h)| (w, h, crate::gl::READ_BGRA))
                        }
                        None => None,
                    }
                } else {
                    crate::d3d11::issue(texture.handle, parity, eye)
                }
            };
            match size {
                Some((w, hgt, bgra)) => {
                    p.width = w;
                    p.height = hgt;
                    p.bgra = bgra;
                }
                None if route == Route::Bridge => {
                    PENDING.with(|q| q[parity] = NO_PENDING);
                    return ovr::COMPOSITOR_NONE;
                }
                // The window still takes the frame; this one isn't copied.
                None => p.kind = -1,
            }
        }
        p.bounds[eye] = bounds;
    } else {
        finished = qpc();
    }
    let complete = SHARED.with(|s| {
        s.eyes |= 1 << eye;
        if s.eyes == 3 {
            s.eyes = 0;
            s.slot = s.slot.wrapping_add(1); // the next frame uses the other parity
            s.frame_index += 1;
            Some((
                s.frame_index,
                s.render_head,
                s.submit_time_ns,
                s.submit_lease,
            ))
        } else {
            None
        }
    });
    if let Some((index, pose, source_time_ns, lease)) = complete {
        if route != Route::Bridge {
            // SAFETY: on the game's render thread (see above).
            let shown =
                unsafe { crate::present::present(h, kind, index, pose, source_time_ns, lease) };
            // Not shown: the window path just failed; this one frame is lost, the next ones are
            // copied.
            if route == Route::Window && shown {
                // SAFETY: a mapped header.
                unsafe { (*h).client_frames.fetch_add(1, Ordering::SeqCst) };
            }
        }
        if kind == ovr::TEXTURE_DIRECTX {
            // The next WaitGetPoses waits for this frame's GPU work (d3d11.rs, pacing).
            // SAFETY: the game's texture, on its render thread.
            unsafe { crate::d3d11::mark_frame_end(texture.handle) };
        }
        if route != Route::Window {
            p.pose = pose;
            p.index = index;
            p.source_time_ns = source_time_ns;
            p.lease = lease;
            p.active = p.width > 0 && p.kind >= 0;
            if let Some(slot) = p.direct {
                publish(h, slot, &p);
                p.active = false;
            }
        }
    }
    let end = qpc();
    crate::scene::FRAMES.with(|f| {
        if first {
            f.submit_ticks = 0;
        }
        f.submit_ticks += end.wrapping_sub(start);
        f.last_submit = end;
    });
    TIMING.with(|t| {
        t.finish += finished.wrapping_sub(start);
        t.issue += end.wrapping_sub(finished);
        t.max = t.max.max(end.wrapping_sub(start));
        if first {
            t.frames += 1;
        }
    });
    if route != Route::Window {
        PENDING.with(|q| q[parity] = p);
    }
    ovr::COMPOSITOR_NONE
}
