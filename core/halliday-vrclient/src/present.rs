//! Frames through a window instead of the copy into the bridge (ROADMAP W14.9,
//! docs/research/zero-copy-frames.md).
//!
//! When Halliday says it can capture one (`present_enabled`, with the place for it in
//! `present_origin`: a display Halliday made for game frames), the runtime makes a borderless
//! window there and, every frame, has the GPU copy both eyes into it side by side, below
//! [`PRESENT_BAND`] rows that hold the frame's number, and presents it: Direct3D 11 through a swap
//! chain made on the game's own device, OpenGL through a context that shares the game's textures.
//! Halliday captures the window with ScreenCaptureKit and finds the frame's pose by its number in
//! the bridge (`present_frames`). The game's thread spends tens of microseconds on it instead of
//! milliseconds of reading back.
//!
//! The copy into the bridge stays the fallback. Until Halliday reports seeing window frames
//! (`present_seen`), frames go both ways (`STARTING`); then only through the window (`ON`); if
//! Halliday stops seeing them, both ways again; and if it never sees any for a while, or anything
//! here fails, copies only (`FAILED`, with the reason in the log).

use crate::log::log;
use crate::ovr;
use crate::runtime::Locked;
use crate::win;
use core::ffi::c_void;
use core::sync::atomic::{AtomicU32, Ordering};
use halliday_bridge::{self as bridge, Header, PRESENT_BAND, PresentInfo, present};

type Obj = *mut c_void;
const NULL: Obj = core::ptr::null_mut();

/// Where a frame goes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Route {
    /// Copied into the bridge only.
    Bridge,
    /// Through the window, and copied too.
    Both,
    /// Through the window only.
    Window,
}

/// How long frames may go to the window unseen before the runtime gives up on it (ms).
const START_TIMEOUT_MS: f64 = 10_000.0;
/// How long, with frames presented, Halliday may see none before copies resume (ms).
const STALL_MS: f64 = 500.0;

#[repr(C)]
struct WndClass {
    size: u32,
    style: u32,
    proc_: unsafe extern "system" fn(Obj, u32, usize, isize) -> isize,
    cls_extra: i32,
    wnd_extra: i32,
    instance: Obj,
    icon: Obj,
    cursor: Obj,
    brush: Obj,
    menu: *const u16,
    name: *const u16,
    icon_small: Obj,
}

#[link(name = "user32", kind = "raw-dylib")]
unsafe extern "system" {
    fn RegisterClassExW(c: *const WndClass) -> u16;
    #[allow(clippy::too_many_arguments)]
    fn CreateWindowExW(
        ex: u32,
        class: *const u16,
        title: *const u16,
        style: u32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        parent: Obj,
        menu: Obj,
        inst: Obj,
        param: Obj,
    ) -> Obj;
    fn DefWindowProcW(h: Obj, m: u32, w: usize, l: isize) -> isize;
    fn GetMessageW(msg: *mut [u64; 6], h: Obj, a: u32, b: u32) -> i32;
    fn TranslateMessage(msg: *const [u64; 6]) -> i32;
    fn DispatchMessageW(msg: *const [u64; 6]) -> isize;
    fn ShowWindow(h: Obj, cmd: i32) -> i32;
    fn SetWindowPos(h: Obj, after: Obj, x: i32, y: i32, w: i32, hgt: i32, flags: u32) -> i32;
    fn GetDC(h: Obj) -> Obj;
}

#[repr(C)]
#[derive(Default, Clone, Copy, PartialEq)]
struct Desc {
    width: u32,
    height: u32,
    mip_levels: u32,
    array_size: u32,
    format: u32,
    sample_count: u32,
    sample_quality: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access: u32,
    misc_flags: u32,
}

#[repr(C)]
struct SwapDesc {
    width: u32,
    height: u32,
    rate_num: u32,
    rate_den: u32,
    format: u32,
    scanline: u32,
    scaling: u32,
    samples: u32,
    quality: u32,
    usage: u32,
    buffers: u32,
    window: Obj,
    windowed: i32,
    effect: u32,
    flags: u32,
}

#[repr(C)]
struct D3dBox {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
}

const fn guid(a: u32, b: u16, c: u16, d: [u8; 8]) -> [u8; 16] {
    let (a, b, c) = (a.to_le_bytes(), b.to_le_bytes(), c.to_le_bytes());
    [
        a[0], a[1], a[2], a[3], b[0], b[1], c[0], c[1], d[0], d[1], d[2], d[3], d[4], d[5], d[6],
        d[7],
    ]
}
const IID_DXGI_DEVICE: [u8; 16] = guid(
    0x54ec77fa,
    0x1377,
    0x44e6,
    [0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c],
);
const IID_DXGI_FACTORY: [u8; 16] = guid(
    0x7b7166ec,
    0x21c7,
    0x44ae,
    [0xb2, 0x1a, 0xc9, 0xae, 0x32, 0x1a, 0xe3, 0x69],
);
const IID_TEXTURE2D: [u8; 16] = guid(
    0x6f15aaf2,
    0xd208,
    0x4e89,
    [0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c],
);

// Method indices (Wine's d3d11.h and dxgi.h, the order of Microsoft's interfaces).
const QUERY_INTERFACE: usize = 0;
const RELEASE: usize = 2;
const GET_DEVICE: usize = 3;
const TEXTURE_GET_DESC: usize = 10;
const DEVICE_CREATE_TEXTURE_2D: usize = 5;
const DEVICE_GET_IMMEDIATE_CONTEXT: usize = 40;
const CONTEXT_COPY_SUBRESOURCE_REGION: usize = 46;
const CONTEXT_UPDATE_SUBRESOURCE: usize = 48;
const CONTEXT_RESOLVE_SUBRESOURCE: usize = 57;
const DXGI_DEVICE_GET_ADAPTER: usize = 7;
const DXGI_OBJECT_GET_PARENT: usize = 6;
const FACTORY_CREATE_SWAP_CHAIN: usize = 10;
const SWAP_PRESENT: usize = 8;
const SWAP_GET_BUFFER: usize = 9;
const SWAP_RESIZE_BUFFERS: usize = 13;

unsafe fn method(obj: Obj, index: usize) -> *const c_void {
    // SAFETY: a COM object starts with a pointer to its table of methods.
    unsafe { *(*(obj as *const *const *const c_void)).add(index) }
}

macro_rules! call {
    ($obj:expr, $i:expr, fn($($t:ty),*) -> $r:ty $(, $a:expr)*) => {
        core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj $(, $t)*) -> $r>(
            method($obj, $i),
        )($obj $(, $a)*)
    };
}

unsafe fn release(obj: &mut Obj) {
    if !obj.is_null() {
        // SAFETY: IUnknown::Release on an object we hold a reference to.
        unsafe { call!(*obj, RELEASE, fn() -> u32) };
        *obj = NULL;
    }
}

/// The swap chain's format for an eye texture's format (one it can be copied into), or `None`.
fn swap_format(format: u32) -> Option<u32> {
    match format {
        0x1b..=0x1d => Some(0x1c),        // R8G8B8A8 typeless / unorm / srgb
        0x57 | 0x5a | 0x5b => Some(0x57), // B8G8R8A8 unorm / typeless / srgb
        _ => None,
    }
}

/// The typed format a multisampled texture is resolved as.
fn resolve_format(format: u32) -> u32 {
    match format {
        0x1b => 0x1c,
        0x5a => 0x57,
        f => f,
    }
}

/// One eye of the frame being submitted.
#[derive(Clone, Copy)]
struct Eye {
    handle: usize,
    bounds: [f32; 4],
}

struct D3d {
    device: Obj,
    /// The swap chain's size.
    size: (u32, u32),
    context: Obj,
    swap: Obj,
    back: Obj,
    format: u32,
    resolve: [Obj; 2],
    resolve_desc: [Desc; 2],
}

struct Gl {
    dc: Obj,
    ctx: Obj,
    framebuffer: u32,
    bind_framebuffer: usize,
    framebuffer_texture: usize,
    check_framebuffer: usize,
    blit: usize,
}

struct State {
    phase: u32,
    /// The texture kind the window was made for.
    kind: i32,
    hwnd: Obj,
    width: u32,
    height: u32,
    eyes: [Eye; 2],
    number: u32,
    /// The frame number that began this STARTING phase, the time it began, and how many times
    /// the runtime started presenting.
    start_number: u32,
    started: u64,
    starts: u32,
    /// The last number Halliday reported, when it changed, and frames presented since.
    seen: u32,
    seen_at: u64,
    unseen: u32,
    d3d: D3d,
    gl: Gl,
    stamp: [u8; (32 * PRESENT_BAND * PRESENT_BAND * 4) as usize],
    ticks: u64,
    max: u64,
    frames: u32,
    window_start: u64,
}

unsafe impl Send for State {}

static STATE: Locked<State> = Locked::new(State {
    phase: present::OFF,
    kind: -1,
    hwnd: NULL,
    width: 0,
    height: 0,
    eyes: [Eye {
        handle: 0,
        bounds: [0.0; 4],
    }; 2],
    number: 0,
    start_number: 0,
    started: 0,
    starts: 0,
    seen: 0,
    seen_at: 0,
    unseen: 0,
    d3d: D3d {
        device: NULL,
        size: (0, 0),
        context: NULL,
        swap: NULL,
        back: NULL,
        format: 0,
        resolve: [NULL; 2],
        resolve_desc: [Desc {
            width: 0,
            height: 0,
            mip_levels: 0,
            array_size: 0,
            format: 0,
            sample_count: 0,
            sample_quality: 0,
            usage: 0,
            bind_flags: 0,
            cpu_access: 0,
            misc_flags: 0,
        }; 2],
    },
    gl: Gl {
        dc: NULL,
        ctx: NULL,
        framebuffer: 0,
        bind_framebuffer: 0,
        framebuffer_texture: 0,
        check_framebuffer: 0,
        blit: 0,
    },
    stamp: [0; (32 * PRESENT_BAND * PRESENT_BAND * 4) as usize],
    ticks: 0,
    max: 0,
    frames: 0,
    window_start: 0,
});

/// 0 while the window thread makes the window, 1 made, 2 failed.
static WINDOW: AtomicU32 = AtomicU32::new(0);
static WINDOW_PLACE: Locked<(i32, i32, i32, i32)> = Locked::new((0, 0, 0, 0));
static WINDOW_HANDLE: Locked<usize> = Locked::new(0);

fn ms_since(t: u64) -> f64 {
    crate::runtime::ticks_to_ms(crate::runtime::now_ticks().wrapping_sub(t))
}

fn set_phase(h: *mut Header, s: &mut State, phase: u32, why: core::fmt::Arguments) {
    if s.phase != phase {
        let name = match phase {
            present::OFF => "off",
            present::STARTING => "starting (copies too, until Halliday sees the window)",
            present::ON => "on (no copies)",
            _ => "failed (copies only)",
        };
        log!("present: {name}: {why}");
    }
    s.phase = phase;
    if phase == present::STARTING {
        s.start_number = s.number.wrapping_add(1);
        s.started = crate::runtime::now_ticks();
        s.starts += 1;
    }
    // SAFETY: a mapped header.
    unsafe { (*h).present_state.store(phase, Ordering::SeqCst) };
}

/// Where this frame goes: decided at the first eye of each frame, for both.
pub fn route(h: *mut Header, kind: i32) -> Route {
    STATE.with(|s| {
        // SAFETY: a mapped header; plain loads.
        let (enabled, seen) = unsafe {
            (
                (*h).present_enabled.load(Ordering::SeqCst) == 1,
                (*h).present_seen.load(Ordering::SeqCst),
            )
        };
        if seen != s.seen {
            s.seen = seen;
            s.seen_at = crate::runtime::now_ticks();
            s.unseen = 0;
        }
        match s.phase {
            present::FAILED => return Route::Bridge,
            _ if !enabled => {
                if s.phase != present::OFF {
                    set_phase(
                        h,
                        s,
                        present::OFF,
                        format_args!("Halliday no longer captures it"),
                    );
                }
                return Route::Bridge;
            }
            _ if s.kind >= 0 && s.kind != kind => {
                set_phase(
                    h,
                    s,
                    present::FAILED,
                    format_args!("the game changed its texture type"),
                );
                return Route::Bridge;
            }
            present::OFF => {
                if kind != ovr::TEXTURE_DIRECTX && kind != ovr::TEXTURE_OPENGL {
                    return Route::Bridge;
                }
                set_phase(
                    h,
                    s,
                    present::STARTING,
                    format_args!("Halliday can capture a window"),
                );
            }
            present::STARTING => {
                let ahead = seen.wrapping_sub(s.start_number);
                if seen != 0 && ahead < 1 << 30 {
                    set_phase(
                        h,
                        s,
                        present::ON,
                        format_args!("Halliday sees frame {seen}"),
                    );
                } else if ms_since(s.started) > START_TIMEOUT_MS {
                    set_phase(
                        h,
                        s,
                        present::FAILED,
                        format_args!(
                            "Halliday saw none of the window's frames in {:.0} s",
                            START_TIMEOUT_MS / 1000.0
                        ),
                    );
                    return Route::Bridge;
                }
            }
            present::ON if s.unseen > 20 && ms_since(s.seen_at) > STALL_MS => {
                if s.starts >= 5 {
                    set_phase(
                        h,
                        s,
                        present::FAILED,
                        format_args!("Halliday kept losing the window"),
                    );
                    return Route::Bridge;
                }
                set_phase(
                    h,
                    s,
                    present::STARTING,
                    format_args!("Halliday saw no frame for {:.0} ms", ms_since(s.seen_at)),
                );
            }
            _ => {}
        }
        if s.phase == present::ON {
            Route::Window
        } else {
            Route::Both
        }
    })
}

/// Keeps one eye of the frame being submitted (presented with the frame's second eye).
pub fn keep(eye: usize, handle: usize, bounds: [f32; 4]) {
    STATE.with(|s| s.eyes[eye.min(1)] = Eye { handle, bounds });
}

unsafe extern "system" fn wndproc(h: Obj, m: u32, w: usize, l: isize) -> isize {
    // SAFETY: the default handling.
    unsafe { DefWindowProcW(h, m, w, l) }
}

/// The window's thread: makes the window and pumps its messages for as long as the game runs.
unsafe extern "system" fn window_thread(_: *mut c_void) -> u32 {
    // SAFETY: Win32 calls with their signatures.
    unsafe {
        let (x, y, w, h) = WINDOW_PLACE.with(|p| *p);
        let mut class = [0u16; 16];
        for (i, b) in b"HallidayFrames".iter().enumerate() {
            class[i] = *b as u16;
        }
        // "Halliday frames <pid>": Halliday finds the window by it.
        let mut title = [0u16; 40];
        let mut n = 0;
        for b in bridge::PRESENT_TITLE.bytes() {
            title[n] = b as u16;
            n += 1;
        }
        let pid = win::GetCurrentProcessId();
        let mut digits = [0u8; 10];
        let mut d = 0;
        let mut v = pid;
        loop {
            digits[d] = b'0' + (v % 10) as u8;
            d += 1;
            v /= 10;
            if v == 0 {
                break;
            }
        }
        while d > 0 {
            d -= 1;
            title[n] = digits[d] as u16;
            n += 1;
        }
        let inst = win::GetModuleHandleW(core::ptr::null());
        let wc = WndClass {
            size: core::mem::size_of::<WndClass>() as u32,
            style: 0x20, // CS_OWNDC: the OpenGL path keeps the window's DC
            proc_: wndproc,
            cls_extra: 0,
            wnd_extra: 0,
            instance: inst,
            icon: NULL,
            cursor: NULL,
            brush: NULL,
            menu: core::ptr::null(),
            name: class.as_ptr(),
            icon_small: NULL,
        };
        RegisterClassExW(&wc);
        // WS_EX_NOACTIVATE, WS_POPUP. Not a tool window: Wine on the Mac hides those while the
        // game's app isn't active, and a hidden window stalls Present.
        let hwnd = CreateWindowExW(
            0x0800_0000,
            class.as_ptr(),
            title.as_ptr(),
            0x8000_0000,
            x,
            y,
            w,
            h,
            NULL,
            NULL,
            inst,
            NULL,
        );
        if !hwnd.is_null() {
            ShowWindow(hwnd, 4); // SW_SHOWNOACTIVATE
        }
        WINDOW_HANDLE.with(|w| *w = hwnd as usize);
        WINDOW.store(if hwnd.is_null() { 2 } else { 1 }, Ordering::Release);
        let mut msg = [0u64; 6];
        while GetMessageW(&mut msg, NULL, 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    0
}

/// Makes the window (once) at Halliday's origin, `width` × `height`; or resizes it.
unsafe fn window(h: *mut Header, s: &mut State, width: u32, height: u32) -> bool {
    // SAFETY (whole function): Win32 calls with their signatures.
    unsafe {
        if !s.hwnd.is_null() {
            if (s.width, s.height) != (width, height) {
                // SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
                SetWindowPos(
                    s.hwnd,
                    NULL,
                    0,
                    0,
                    width as i32,
                    height as i32,
                    0x2 | 0x4 | 0x10,
                );
                (s.width, s.height) = (width, height);
                (*h).present_width.store(width, Ordering::SeqCst);
                (*h).present_height.store(height, Ordering::SeqCst);
            }
            return true;
        }
        if WINDOW.load(Ordering::Acquire) == 2 {
            return false;
        }
        crate::runtime::pin_this_dll();
        let [x, y] = core::ptr::read_volatile(core::ptr::addr_of!((*h).present_origin));
        WINDOW_PLACE.with(|p| *p = (x, y, width as i32, height as i32));
        let thread = win::CreateThread(NULL, 0, window_thread, NULL, 0, core::ptr::null_mut());
        if thread.is_null() {
            WINDOW.store(2, Ordering::Release);
            return false;
        }
        win::CloseHandle(thread);
        for _ in 0..2000 {
            if WINDOW.load(Ordering::Acquire) != 0 {
                break;
            }
            win::Sleep(1);
        }
        s.hwnd = WINDOW_HANDLE.with(|w| *w) as Obj;
        if s.hwnd.is_null() {
            WINDOW.store(2, Ordering::Release);
            return false;
        }
        (s.width, s.height) = (width, height);
        (*h).present_width.store(width, Ordering::SeqCst);
        (*h).present_height.store(height, Ordering::SeqCst);
        log!("present: window {width}x{height} at {x},{y}");
        true
    }
}

/// An eye's part of its texture in pixels (x0, y0, x1, y1, rows counted the texture's way) and
/// whether its bounds ask for it upside down.
fn region(bounds: [f32; 4], width: u32, height: u32) -> (u32, u32, u32, u32, bool) {
    let px = |v: f32, n: u32| ((v.clamp(0.0, 1.0) * n as f32) + 0.5) as u32;
    let (u0, u1) = (bounds[0].min(bounds[2]), bounds[0].max(bounds[2]));
    let (v0, v1) = (bounds[1].min(bounds[3]), bounds[1].max(bounds[3]));
    let (x0, x1) = (px(u0, width), px(u1, width).max(px(u0, width) + 1));
    let (y0, y1) = (px(v0, height), px(v1, height).max(px(v0, height) + 1));
    (x0, y0, x1.min(width), y1.min(height), bounds[1] > bounds[3])
}

/// Presents the frame whose eyes were kept: `index` and `pose` are the frame's. False if the
/// window path failed (it is then off for the rest of the game; the caller copies the frame).
///
/// # Safety
/// On the game's render thread: owning the Direct3D 11 immediate context, or with the game's
/// OpenGL context current.
pub unsafe fn present(h: *mut Header, kind: i32, index: u64, pose: bridge::Pose, source_time_ns: i64, lease: bridge::producer_lease::Lease) -> bool {
    let start = crate::runtime::now_ticks();
    let ok = STATE.with(|s| {
        if s.phase == present::FAILED || s.phase == present::OFF {
            return false;
        }
        s.kind = kind;
        s.number = s.number.wrapping_add(1);
        if s.number == 0 || s.number == bridge::PRESENT_BUSY {
            s.number = 1;
        }
        // SAFETY: as the caller's.
        let result = unsafe {
            if kind == ovr::TEXTURE_DIRECTX {
                d3d_present(h, s, index, pose, source_time_ns, lease)
            } else {
                gl_present(h, s, index, pose, source_time_ns, lease)
            }
        };
        if let Err(why) = result {
            set_phase(h, s, present::FAILED, format_args!("{why}"));
            return false;
        }
        s.unseen += 1;
        true
    });
    if ok {
        let end = crate::runtime::now_ticks();
        STATE.with(|s| {
            let t = end.wrapping_sub(start);
            s.ticks += t;
            s.max = s.max.max(t);
            s.frames += 1;
            if s.window_start == 0 {
                s.window_start = end;
            }
            if s.frames == 600 {
                let span = crate::runtime::ticks_to_ms(end.wrapping_sub(s.window_start));
                log!(
                    "present: 600 frames in {:.0} ms ({:.1}/s); on the game's thread {:.3} ms a frame, {:.2} ms max",
                    span,
                    600.0 * 1000.0 / span,
                    crate::runtime::ticks_to_ms(s.ticks) / 600.0,
                    crate::runtime::ticks_to_ms(s.max)
                );
                (s.frames, s.ticks, s.max, s.window_start) = (0, 0, 0, end);
            }
        });
    }
    ok
}

/// Records the frame's pose and size under its number, before it is presented.
unsafe fn record(h: *mut Header, mut info: PresentInfo, source_time_ns: i64, lease: bridge::producer_lease::Lease) {
    if !unsafe {bridge::producer_lease::active(h,lease)} { return; }
    let times=unsafe {bridge::frame_timing::extension(h)};let index=bridge::frame_timing::present_index(info.number);times.clear(index);
    if times.write(index,lease.epoch,info.frame_index,bridge::frame_timing::Time{nanoseconds:source_time_ns,clock_kind:bridge::frame_timing::SUBMIT_MONOTONIC_NS})
        && unsafe {bridge::producer_lease::active(h,lease)} {info.texture_type |= bridge::FRAME_SOURCE_TIMING;}
    // SAFETY: a mapped header; the game side writes the ring from its render thread only.
    unsafe { bridge::write_present_frame(h, &info) };
}

unsafe fn d3d_present(
    h: *mut Header,
    s: &mut State,
    index: u64,
    pose: bridge::Pose,
    source_time_ns: i64,
    lease: bridge::producer_lease::Lease,
) -> Result<(), &'static str> {
    // SAFETY (whole function): COM calls with their signatures on the game's objects and ours.
    unsafe {
        let sources = [s.eyes[0].handle as Obj, s.eyes[1].handle as Obj];
        if sources[0].is_null() || sources[1].is_null() {
            return Err("an eye texture is missing");
        }
        let shared = sources[0] == sources[1];
        let mut descs = [Desc::default(); 2];
        for e in 0..2 {
            call!(
                sources[e],
                TEXTURE_GET_DESC,
                fn(*mut Desc) -> (),
                &mut descs[e]
            );
        }
        let Some(format) = swap_format(descs[0].format) else {
            return Err("its eye format isn't one the window takes (8-bit RGBA or BGRA)");
        };
        if swap_format(descs[1].format) != Some(format) {
            return Err("its two eyes have different formats");
        }
        // The game's device: ours to follow if it changes.
        let mut device = NULL;
        call!(sources[0], GET_DEVICE, fn(*mut Obj) -> (), &mut device);
        if device.is_null() {
            return Err("no device");
        }
        if s.d3d.device != device {
            if !s.d3d.device.is_null() {
                log!("present: the game changed its Direct3D device");
            }
            release(&mut s.d3d.back);
            release(&mut s.d3d.swap);
            release(&mut s.d3d.context);
            for r in s.d3d.resolve.iter_mut() {
                release(r);
            }
            release(&mut s.d3d.device);
            s.d3d.device = device; // keeps the reference GetDevice added
            call!(
                device,
                DEVICE_GET_IMMEDIATE_CONTEXT,
                fn(*mut Obj) -> (),
                &mut s.d3d.context
            );
        } else {
            release(&mut device);
        }
        let regions = [
            region(s.eyes[0].bounds, descs[0].width, descs[0].height),
            region(s.eyes[1].bounds, descs[1].width, descs[1].height),
        ];
        let ew = (regions[0].2 - regions[0].0).min(regions[1].2 - regions[1].0);
        let eh = (regions[0].3 - regions[0].1).min(regions[1].3 - regions[1].1);
        let (width, height) = (ew * 2, eh + PRESENT_BAND);
        if !(32 * PRESENT_BAND..=8192).contains(&width) || height > 8192 {
            return Err("its eye size doesn't fit a window");
        }
        if !window(h, s, width, height) {
            return Err("couldn't make the window");
        }
        if s.d3d.swap.is_null() {
            let mut dxgi = NULL;
            call!(
                s.d3d.device,
                QUERY_INTERFACE,
                fn(*const u8, *mut Obj) -> i32,
                IID_DXGI_DEVICE.as_ptr(),
                &mut dxgi
            );
            let mut adapter = NULL;
            if dxgi.is_null()
                || call!(
                    dxgi,
                    DXGI_DEVICE_GET_ADAPTER,
                    fn(*mut Obj) -> i32,
                    &mut adapter
                ) < 0
            {
                release(&mut dxgi);
                return Err("no DXGI adapter");
            }
            let mut factory = NULL;
            call!(
                adapter,
                DXGI_OBJECT_GET_PARENT,
                fn(*const u8, *mut Obj) -> i32,
                IID_DXGI_FACTORY.as_ptr(),
                &mut factory
            );
            release(&mut adapter);
            release(&mut dxgi);
            if factory.is_null() {
                return Err("no DXGI factory");
            }
            let sd = SwapDesc {
                width,
                height,
                rate_num: 0,
                rate_den: 1,
                format,
                scanline: 0,
                scaling: 0,
                samples: 1,
                quality: 0,
                usage: 0x20, // render target output
                buffers: 2,
                window: s.hwnd,
                windowed: 1,
                effect: 4, // flip discard
                flags: 0,
            };
            let hr = call!(
                factory,
                FACTORY_CREATE_SWAP_CHAIN,
                fn(Obj, *const SwapDesc, *mut Obj) -> i32,
                s.d3d.device,
                &sd,
                &mut s.d3d.swap
            );
            release(&mut factory);
            if hr < 0 || s.d3d.swap.is_null() {
                s.d3d.swap = NULL;
                return Err("CreateSwapChain failed");
            }
            s.d3d.format = format;
            s.d3d.size = (width, height);
            log!(
                "present: Direct3D 11 swap chain {width}x{height}, format {format:#x} (eyes {}x{} format {:#x}, {} samples{})",
                descs[0].width,
                descs[0].height,
                descs[0].format,
                descs[0].sample_count,
                if shared { ", one texture" } else { "" }
            );
        } else if s.d3d.format != format || s.d3d.size != (width, height) {
            release(&mut s.d3d.back);
            let hr = call!(
                s.d3d.swap,
                SWAP_RESIZE_BUFFERS,
                fn(u32, u32, u32, u32, u32) -> i32,
                0,
                width,
                height,
                format,
                0
            );
            if hr < 0 {
                return Err("ResizeBuffers failed");
            }
            s.d3d.format = format;
            s.d3d.size = (width, height);
            log!("present: eyes now {ew}x{eh}: swap chain {width}x{height}");
        }
        if s.d3d.back.is_null() {
            call!(
                s.d3d.swap,
                SWAP_GET_BUFFER,
                fn(u32, *const u8, *mut Obj) -> i32,
                0,
                IID_TEXTURE2D.as_ptr(),
                &mut s.d3d.back
            );
            if s.d3d.back.is_null() {
                return Err("no back buffer");
            }
        }
        // Multisampled eyes are resolved first (once when both share a texture).
        let mut from = sources;
        for e in 0..2 {
            if descs[e].sample_count <= 1 {
                continue;
            }
            if e == 1 && shared {
                from[1] = from[0];
                continue;
            }
            let typed = resolve_format(descs[e].format);
            let want = Desc {
                format: typed,
                mip_levels: 1,
                array_size: 1,
                sample_count: 1,
                sample_quality: 0,
                usage: 0,
                bind_flags: 0,
                cpu_access: 0,
                misc_flags: 0,
                ..descs[e]
            };
            if s.d3d.resolve[e].is_null() || s.d3d.resolve_desc[e] != want {
                release(&mut s.d3d.resolve[e]);
                let hr = call!(
                    s.d3d.device,
                    DEVICE_CREATE_TEXTURE_2D,
                    fn(*const Desc, *const c_void, *mut Obj) -> i32,
                    &want,
                    core::ptr::null(),
                    &mut s.d3d.resolve[e]
                );
                if hr < 0 || s.d3d.resolve[e].is_null() {
                    s.d3d.resolve[e] = NULL;
                    return Err("couldn't make a texture to resolve a multisampled eye into");
                }
                s.d3d.resolve_desc[e] = want;
            }
            call!(
                s.d3d.context,
                CONTEXT_RESOLVE_SUBRESOURCE,
                fn(Obj, u32, Obj, u32, u32) -> (),
                s.d3d.resolve[e],
                0,
                sources[e],
                0,
                typed
            );
            from[e] = s.d3d.resolve[e];
        }
        let flipped = regions[0].4;
        record(
            h,
            PresentInfo {
                number: s.number,
                eye_width: ew,
                eye_height: eh,
                flipped,
                frame_index: index,
                texture_type: ovr::TEXTURE_DIRECTX as u32,
                pose,
            }, source_time_ns, lease,
        );
        for e in 0..2 {
            let r = regions[e];
            let b = D3dBox {
                left: r.0,
                top: r.1,
                front: 0,
                right: r.0 + ew,
                bottom: r.1 + eh,
                back: 1,
            };
            call!(
                s.d3d.context,
                CONTEXT_COPY_SUBRESOURCE_REGION,
                fn(Obj, u32, u32, u32, u32, Obj, u32, *const D3dBox) -> (),
                s.d3d.back,
                0,
                e as u32 * ew,
                PRESENT_BAND,
                0,
                from[e],
                0,
                &b
            );
        }
        bridge::fill_band(s.number, &mut s.stamp);
        let band = D3dBox {
            left: 0,
            top: 0,
            front: 0,
            right: 32 * PRESENT_BAND,
            bottom: PRESENT_BAND,
            back: 1,
        };
        call!(
            s.d3d.context,
            CONTEXT_UPDATE_SUBRESOURCE,
            fn(Obj, u32, *const D3dBox, *const u8, u32, u32) -> (),
            s.d3d.back,
            0,
            &band,
            s.stamp.as_ptr(),
            32 * PRESENT_BAND * 4,
            0
        );
        let hr = call!(s.d3d.swap, SWAP_PRESENT, fn(u32, u32) -> i32, 0, 0);
        if hr < 0 {
            log!("present: Present failed ({hr:#x})");
            return Err("Present failed");
        }
        Ok(())
    }
}

const GL_READ_FRAMEBUFFER: u32 = 0x8CA8;
const GL_DRAW_FRAMEBUFFER: u32 = 0x8CA9;
const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
const GL_NEAREST: u32 = 0x2600;
const GL_SCISSOR_TEST: u32 = 0x0C11;

/// The window's OpenGL context, made once: on the window's DC with the pixel format of the game's
/// drawable, sharing the game's textures.
unsafe fn gl_setup(s: &mut State) -> Result<(), &'static str> {
    // SAFETY (whole function): WGL and GDI calls with their signatures.
    unsafe {
        let game_dc = win::wglGetCurrentDC();
        let game_ctx = win::wglGetCurrentContext();
        if game_dc.is_null() || game_ctx.is_null() {
            return Err("no current OpenGL context");
        }
        let dc = GetDC(s.hwnd);
        if dc.is_null() {
            return Err("no DC for the window");
        }
        let format = win::GetPixelFormat(game_dc);
        let mut pfd = [0u8; 40];
        if format <= 0
            || win::DescribePixelFormat(game_dc, format, 40, pfd.as_mut_ptr().cast()) == 0
        {
            return Err("couldn't read the game's pixel format");
        }
        if win::GetPixelFormat(dc) == 0 && win::SetPixelFormat(dc, format, pfd.as_ptr().cast()) == 0
        {
            return Err("couldn't set the window's pixel format");
        }
        // The new context shares the game's objects; made while the game's is current here,
        // which wglShareLists allows (the new one has no objects yet).
        let ctx = crate::glfix::context_like_the_games(dc, game_ctx);
        if ctx.is_null() {
            return Err("couldn't make an OpenGL context sharing the game's");
        }
        if win::wglMakeCurrent(dc, ctx) == 0 {
            win::wglDeleteContext(ctx);
            win::wglMakeCurrent(game_dc, game_ctx);
            return Err("couldn't make the window's context current");
        }
        let get = |name: &core::ffi::CStr| win::wglGetProcAddress(name.as_ptr().cast()) as usize;
        let functions = [
            get(c"glGenFramebuffers"),
            get(c"glBindFramebuffer"),
            get(c"glFramebufferTexture2D"),
            get(c"glCheckFramebufferStatus"),
            get(c"glBlitFramebuffer"),
        ];
        let interval = get(c"wglSwapIntervalEXT");
        if interval != 0 {
            // Never wait for the display here: Halliday paces the game.
            core::mem::transmute::<usize, unsafe extern "system" fn(i32) -> i32>(interval)(0);
        }
        let mut fb = 0u32;
        if functions[0] != 0 {
            core::mem::transmute::<usize, unsafe extern "system" fn(i32, *mut u32)>(functions[0])(
                1, &mut fb,
            );
        }
        win::wglMakeCurrent(game_dc, game_ctx);
        if functions.contains(&0) || fb == 0 {
            win::wglDeleteContext(ctx);
            return Err("the window's context lacks framebuffer blits");
        }
        s.gl = Gl {
            dc,
            ctx,
            framebuffer: fb,
            bind_framebuffer: functions[1],
            framebuffer_texture: functions[2],
            check_framebuffer: functions[3],
            blit: functions[4],
        };
        log!("present: OpenGL context for the window, sharing the game's (pixel format {format})");
        Ok(())
    }
}

unsafe fn gl_present(
    h: *mut Header,
    s: &mut State,
    index: u64,
    pose: bridge::Pose,
    source_time_ns: i64,
    lease: bridge::producer_lease::Lease,
) -> Result<(), &'static str> {
    // SAFETY (whole function): GL and WGL calls with their signatures; the game's context is put
    // back current before returning.
    unsafe {
        let textures = [s.eyes[0].handle as u32, s.eyes[1].handle as u32];
        if textures[0] == 0 || textures[1] == 0 {
            return Err("an eye texture is missing");
        }
        // Each eye's size, asked in the game's context (its texture binding put back).
        let mut sizes = [(0i32, 0i32); 2];
        let mut bound = 0;
        win::glGetIntegerv(win::GL_TEXTURE_BINDING_2D, &mut bound);
        for e in 0..2 {
            win::glBindTexture(win::GL_TEXTURE_2D, textures[e]);
            win::glGetTexLevelParameteriv(
                win::GL_TEXTURE_2D,
                0,
                win::GL_TEXTURE_WIDTH,
                &mut sizes[e].0,
            );
            win::glGetTexLevelParameteriv(
                win::GL_TEXTURE_2D,
                0,
                win::GL_TEXTURE_HEIGHT,
                &mut sizes[e].1,
            );
        }
        win::glBindTexture(win::GL_TEXTURE_2D, bound as u32);
        if sizes.iter().any(|&(w, h)| w <= 0 || h <= 0) {
            return Err("couldn't read an eye texture's size");
        }
        let regions = [
            region(s.eyes[0].bounds, sizes[0].0 as u32, sizes[0].1 as u32),
            region(s.eyes[1].bounds, sizes[1].0 as u32, sizes[1].1 as u32),
        ];
        let ew = (regions[0].2 - regions[0].0).min(regions[1].2 - regions[1].0);
        let eh = (regions[0].3 - regions[0].1).min(regions[1].3 - regions[1].1);
        let (width, height) = (ew * 2, eh + PRESENT_BAND);
        if !(32 * PRESENT_BAND..=8192).contains(&width) || height > 8192 {
            return Err("its eye size doesn't fit a window");
        }
        if !window(h, s, width, height) {
            return Err("couldn't make the window");
        }
        if s.gl.ctx.is_null() {
            gl_setup(s)?;
            log!(
                "present: OpenGL eyes {}x{}, shown {ew}x{eh} each",
                sizes[0].0,
                sizes[0].1
            );
        }
        if GL_FAILED.load(Ordering::Acquire) {
            return Err("an eye texture can't be read through a framebuffer (multisampled?)");
        }
        // What the game drew must reach the shared textures before the other context reads them.
        win::glFlush();
        if GL_BUSY.load(Ordering::Acquire) {
            // The window's thread is still on the last frame (the GPU hasn't finished it): this
            // one is skipped rather than waited for.
            GL_SKIPPED.fetch_add(1, Ordering::Relaxed);
            return Ok(());
        }
        // Rows: OpenGL's count from the bottom, in the texture and in the window. The image goes
        // below the band (the window's top rows), each eye as the game's bounds say: a blit flips
        // by itself when the bounds ask for it, so the window shows it upright.
        record(
            h,
            PresentInfo {
                number: s.number,
                eye_width: ew,
                eye_height: eh,
                flipped: false,
                frame_index: index,
                texture_type: ovr::TEXTURE_OPENGL as u32,
                pose,
            }, source_time_ns, lease,
        );
        let mut job = GlJob {
            textures,
            source: [[0; 4]; 2],
            ew,
            eh,
            number: s.number,
        };
        for (e, (r, eye)) in regions.iter().zip(s.eyes).enumerate() {
            let b = eye.bounds;
            // Source rows in the bounds' order (v min to v max: upside down when v min > v max).
            let (sy0, sy1) = if b[1] > b[3] {
                (r.1 + eh, r.1)
            } else {
                (r.1, r.1 + eh)
            };
            job.source[e] = [r.0 as i32, sy0 as i32, (r.0 + ew) as i32, sy1 as i32];
        }
        if !gl_thread_ready(s) {
            return Err("couldn't start the window's OpenGL thread");
        }
        GL_JOB.with(|j| *j = Some(job));
        GL_BUSY.store(true, Ordering::Release);
        win::SetEvent(GL_WAKE.load(Ordering::Acquire));
        Ok(())
    }
}

/// A frame for the window's OpenGL thread: the game's eye textures, each eye's source rectangle
/// (x0, y0, x1, y1, OpenGL's rows), the size shown per eye and the frame's number.
#[derive(Clone, Copy)]
struct GlJob {
    textures: [u32; 2],
    source: [[i32; 4]; 2],
    ew: u32,
    eh: u32,
    number: u32,
}

static GL_JOB: Locked<Option<GlJob>> = Locked::new(None);
static GL_BUSY: core::sync::atomic::AtomicBool = core::sync::atomic::AtomicBool::new(false);
static GL_FAILED: core::sync::atomic::AtomicBool = core::sync::atomic::AtomicBool::new(false);
static GL_SKIPPED: AtomicU32 = AtomicU32::new(0);
static GL_WAKE: core::sync::atomic::AtomicPtr<c_void> =
    core::sync::atomic::AtomicPtr::new(core::ptr::null_mut());
/// The window's DC, context and functions, for its thread.
static GL_WINDOW: Locked<(usize, usize, [usize; 5])> = Locked::new((0, 0, [0; 5]));

/// Starts the thread that draws into the window (once). Apple's OpenGL makes a context that reads
/// a texture another context drew wait until the GPU has finished that drawing: on the game's
/// thread that was its whole GPU time (about 7 ms a frame for the OpenGL game), so the blits and the swap
/// happen here instead, with the window's context current for good.
unsafe fn gl_thread_ready(s: &State) -> bool {
    if !GL_WAKE.load(Ordering::Acquire).is_null() {
        return true;
    }
    GL_WINDOW.with(|w| {
        *w = (
            s.gl.dc as usize,
            s.gl.ctx as usize,
            [
                s.gl.bind_framebuffer,
                s.gl.framebuffer_texture,
                s.gl.check_framebuffer,
                s.gl.blit,
                s.gl.framebuffer as usize,
            ],
        )
    });
    // SAFETY: plain Win32 calls.
    unsafe {
        let event = win::CreateEventW(core::ptr::null_mut(), 0, 0, core::ptr::null());
        if event.is_null() {
            return false;
        }
        GL_WAKE.store(event, Ordering::Release);
        let thread = win::CreateThread(NULL, 0, gl_thread, NULL, 0, core::ptr::null_mut());
        if thread.is_null() {
            GL_WAKE.store(core::ptr::null_mut(), Ordering::Release);
            return false;
        }
        win::CloseHandle(thread);
    }
    true
}

unsafe extern "system" fn gl_thread(_: *mut c_void) -> u32 {
    let (dc, ctx, f) = GL_WINDOW.with(|w| *w);
    // SAFETY (whole function): GL and WGL calls with their signatures, in the window's context,
    // current on this thread only.
    unsafe {
        if win::wglMakeCurrent(dc as Obj, ctx as Obj) == 0 {
            log!("present: the window's OpenGL thread couldn't make its context current");
            GL_FAILED.store(true, Ordering::Release);
            GL_BUSY.store(false, Ordering::Release);
            return 0;
        }
        let bind = core::mem::transmute::<usize, unsafe extern "system" fn(u32, u32)>(f[0]);
        let attach =
            core::mem::transmute::<usize, unsafe extern "system" fn(u32, u32, u32, u32, i32)>(f[1]);
        let check = core::mem::transmute::<usize, unsafe extern "system" fn(u32) -> u32>(f[2]);
        let blit = core::mem::transmute::<
            usize,
            unsafe extern "system" fn(i32, i32, i32, i32, i32, i32, i32, i32, u32, u32),
        >(f[3]);
        let framebuffer = f[4] as u32;
        let mut steps = [0u64; 2];
        let mut frames = 0u32;
        loop {
            win::WaitForSingleObject(GL_WAKE.load(Ordering::Acquire), 0xFFFF_FFFF);
            let Some(job) = GL_JOB.with(|j| j.take()) else {
                continue;
            };
            let t0 = crate::runtime::now_ticks();
            let (ew, eh) = (job.ew as i32, job.eh as i32);
            bind(GL_READ_FRAMEBUFFER, framebuffer);
            bind(GL_DRAW_FRAMEBUFFER, 0);
            win::glViewport(0, 0, ew * 2, eh + PRESENT_BAND as i32);
            let mut failed = false;
            for e in 0..2 {
                attach(
                    GL_READ_FRAMEBUFFER,
                    GL_COLOR_ATTACHMENT0,
                    win::GL_TEXTURE_2D,
                    job.textures[e],
                    0,
                );
                if check(GL_READ_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE {
                    failed = true;
                    break;
                }
                let r = job.source[e];
                let x = e as i32 * ew;
                blit(
                    r[0],
                    r[1],
                    r[2],
                    r[3],
                    x,
                    0,
                    x + ew,
                    eh,
                    GL_COLOR_BUFFER_BIT,
                    GL_NEAREST,
                );
            }
            attach(
                GL_READ_FRAMEBUFFER,
                GL_COLOR_ATTACHMENT0,
                win::GL_TEXTURE_2D,
                0,
                0,
            );
            if failed {
                log!("present: an eye texture can't be read through a framebuffer");
                GL_FAILED.store(true, Ordering::Release);
                GL_BUSY.store(false, Ordering::Release);
                continue;
            }
            win::glEnable(GL_SCISSOR_TEST);
            for bit in 0..32u32 {
                let v = if (job.number >> bit) & 1 == 1 {
                    1.0
                } else {
                    0.0
                };
                win::glScissor(
                    (bit * PRESENT_BAND) as i32,
                    eh,
                    PRESENT_BAND as i32,
                    PRESENT_BAND as i32,
                );
                win::glClearColor(v, v, v, 1.0);
                win::glClear(GL_COLOR_BUFFER_BIT);
            }
            win::glDisable(GL_SCISSOR_TEST);
            let t1 = crate::runtime::now_ticks();
            win::SwapBuffers(dc as Obj);
            let t2 = crate::runtime::now_ticks();
            GL_BUSY.store(false, Ordering::Release);
            steps[0] += t1.wrapping_sub(t0);
            steps[1] += t2.wrapping_sub(t1);
            frames += 1;
            if frames == 600 {
                let ms = |t: u64| crate::runtime::ticks_to_ms(t) / 600.0;
                log!(
                    "present: the window's OpenGL thread, a frame: blits {:.2} ms (waiting for the game's GPU work), swap {:.2} ms; {} frames skipped while it was busy",
                    ms(steps[0]),
                    ms(steps[1]),
                    GL_SKIPPED.swap(0, Ordering::Relaxed)
                );
                (steps, frames) = ([0; 2], 0);
            }
        }
    }
}
