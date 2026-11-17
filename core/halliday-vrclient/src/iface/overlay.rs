//! `IVROverlay` (016, 018, 020): the game's overlays (loading screens, menus, a message), shown
//! by Halliday as flat pictures in the room or following the head or a hand (bridge `Overlay`).
//! Their pictures come from the game's textures, its memory or a file. An overlay that takes the
//! mouse (`VROverlayInputMethod_Mouse`) gets mouse events from the hands: Halliday finds where
//! a hand's ray meets it and publishes that (bridge `Pointer`), and `poll_next_overlay_event`
//! turns the changes into focus, move, button and scroll events. Not provided: dashboard
//! overlays, SteamVR's keyboard.

use crate::Iface;
use crate::iface::system::write_string;
use crate::log::{CStr, log};
use crate::ovr::{self, HmdMatrix34};
use crate::runtime::{self, Locked};
use crate::scene;
use core::ffi::{c_char, c_void};
use halliday_bridge::{OVERLAYS, Overlay, math};

type This = *mut Iface;
// Overlay handles are `u64` (`VROverlayHandle_t`).

const NONE: i32 = 0;
const UNKNOWN_OVERLAY: i32 = 10;
const INVALID_HANDLE: i32 = 11;
const OVERLAY_LIMIT_EXCEEDED: i32 = 13;
const KEY_IN_USE: i32 = 17;
const INVALID_PARAMETER: i32 = 20;
const REQUEST_FAILED: i32 = 23;
const INVALID_TEXTURE: i32 = 24;
const UNABLE_TO_LOAD_FILE: i32 = 25;

/// Handles: a tag over the slot, so a stale or foreign number is refused.
const TAG: u64 = 0x4856_0000_0000;

fn slot(h: u64) -> Option<usize> {
    let i = h.checked_sub(TAG + 1)? as usize;
    (h & !0xFFFF == TAG && i < OVERLAYS).then_some(i)
}

fn handle(i: usize) -> u64 {
    TAG + 1 + i as u64
}

/// What only the runtime keeps per overlay: its name, flags, input method, last copy.
#[derive(Clone, Copy)]
struct Local {
    name: [u8; 64],
    flags: u32,
    input_method: u32,
    mouse_scale: [f32; 2],
    color_space: i32,
    last_copy: u64,
}

const NO_LOCAL: Local = Local {
    name: [0; 64],
    flags: 0,
    input_method: 0,
    mouse_scale: [1.0, 1.0],
    color_space: 0,
    last_copy: 0,
};

static LOCAL: Locked<[Local; OVERLAYS]> = Locked::new([NO_LOCAL; OVERLAYS]);

fn bytes<'a>(s: *const c_char) -> &'a [u8] {
    if s.is_null() {
        return &[];
    }
    let mut n = 0;
    // SAFETY: a NUL-terminated string of the game's (at most 1024 bytes read).
    unsafe {
        while n < 1024 && *s.add(n) != 0 {
            n += 1;
        }
        core::slice::from_raw_parts(s.cast(), n)
    }
}

fn padded<const N: usize>(s: &[u8]) -> [u8; N] {
    let mut out = [0u8; N];
    for (o, &c) in out.iter_mut().take(N - 1).zip(s) {
        *o = c;
    }
    out
}

fn trimmed(s: &[u8]) -> &[u8] {
    &s[..s.iter().position(|&c| c == 0).unwrap_or(s.len())]
}

/// Changes overlay `h` in the bridge.
fn change(h: u64, f: impl FnOnce(&mut Overlay)) -> i32 {
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    scene::edit(|_, overlays| {
        if overlays[i].used == 0 {
            return UNKNOWN_OVERLAY;
        }
        f(&mut overlays[i]);
        NONE
    })
    .unwrap_or(REQUEST_FAILED)
}

/// Overlay `h` as last written.
fn get(h: u64) -> Result<Overlay, i32> {
    let i = slot(h).ok_or(INVALID_HANDLE)?;
    let (_, overlays) = scene::read().ok_or(REQUEST_FAILED)?;
    if overlays[i].used == 0 {
        return Err(UNKNOWN_OVERLAY);
    }
    Ok(overlays[i])
}

fn set_error(error: *mut i32, e: i32) {
    if !error.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *error = e };
    }
}

fn out<T>(p: *mut T, v: T) {
    if !p.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { p.write(v) };
    }
}

fn key_of(o: &Overlay) -> &[u8] {
    trimmed(&o.key)
}

pub unsafe extern "C" fn find_overlay(_: This, key: *const c_char, out_handle: *mut u64) -> i32 {
    crate::log::seen!("IVROverlay::find_overlay");
    let key = bytes(key);
    let Some((_, overlays)) = scene::read() else {
        return REQUEST_FAILED;
    };
    match overlays
        .iter()
        .position(|o| o.used != 0 && key_of(o) == key)
    {
        Some(i) => {
            out(out_handle, handle(i));
            NONE
        }
        None => UNKNOWN_OVERLAY,
    }
}

pub unsafe extern "C" fn create_overlay(
    _: This,
    key: *const c_char,
    name: *const c_char,
    out_handle: *mut u64,
) -> i32 {
    crate::log::seen!("IVROverlay::create_overlay");
    let (key, name) = (bytes(key), bytes(name));
    let made = scene::edit(|_, overlays| {
        if overlays.iter().any(|o| o.used != 0 && key_of(o) == key) {
            return Err(KEY_IN_USE);
        }
        let i = overlays
            .iter()
            .position(|o| o.used == 0)
            .ok_or(OVERLAY_LIMIT_EXCEEDED)?;
        overlays[i] = Overlay {
            used: 1,
            key: padded(key),
            ..Overlay::NONE
        };
        Ok(i)
    });
    match made {
        Some(Ok(i)) => {
            LOCAL.with(|l| {
                l[i] = Local {
                    name: padded(name),
                    ..NO_LOCAL
                }
            });
            scene::overlay_clear(i);
            log!("overlay {} created: {}", i, CStr(key.as_ptr().cast()));
            out(out_handle, handle(i));
            NONE
        }
        Some(Err(e)) => e,
        None => REQUEST_FAILED,
    }
}

pub unsafe extern "C" fn destroy_overlay(_: This, h: u64) -> i32 {
    crate::log::seen!("IVROverlay::destroy_overlay");
    change(h, |o| *o = Overlay::NONE)
}

pub unsafe extern "C" fn get_overlay_key(
    _: This,
    h: u64,
    value: *mut c_char,
    size: u32,
    error: *mut i32,
) -> u32 {
    crate::log::seen!("IVROverlay::get_overlay_key");
    match get(h) {
        Ok(o) => {
            set_error(error, NONE);
            let mut k = [0u8; 65];
            let n = key_of(&o).len();
            k[..n].copy_from_slice(key_of(&o));
            write_string(&k[..n + 1], value, size).0
        }
        Err(e) => {
            set_error(error, e);
            0
        }
    }
}

pub unsafe extern "C" fn get_overlay_name(
    _: This,
    h: u64,
    value: *mut c_char,
    size: u32,
    error: *mut i32,
) -> u32 {
    crate::log::seen!("IVROverlay::get_overlay_name");
    let Some(i) = slot(h) else {
        set_error(error, INVALID_HANDLE);
        return 0;
    };
    set_error(error, NONE);
    let name = LOCAL.with(|l| l[i].name);
    let n = trimmed(&name).len();
    let mut s = [0u8; 65];
    s[..n].copy_from_slice(&name[..n]);
    write_string(&s[..n + 1], value, size).0
}

pub unsafe extern "C" fn set_overlay_name(_: This, h: u64, name: *const c_char) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_name");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    LOCAL.with(|l| l[i].name = padded(bytes(name)));
    NONE
}

pub unsafe extern "C" fn get_overlay_image_data(
    _: This,
    _h: u64,
    _buffer: *mut c_void,
    _size: u32,
    _w: *mut u32,
    _ht: *mut u32,
) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_image_data");
    REQUEST_FAILED
}

pub unsafe extern "C" fn get_overlay_error_name_from_enum(_: This, _error: i32) -> *const c_char {
    crate::log::seen!("IVROverlay::get_overlay_error_name_from_enum");
    c"VROverlayError".as_ptr()
}

pub unsafe extern "C" fn set_overlay_rendering_pid(_: This, h: u64, _pid: u32) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_rendering_pid");
    change(h, |_| {})
}

pub unsafe extern "C" fn get_overlay_rendering_pid(_: This, _h: u64) -> u32 {
    crate::log::seen!("IVROverlay::get_overlay_rendering_pid");
    // SAFETY: plain call.
    unsafe { crate::win::GetCurrentProcessId() }
}

pub unsafe extern "C" fn set_overlay_flag(_: This, h: u64, flag: u32, on: bool) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_flag");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    if flag < 32 {
        LOCAL.with(|l| {
            if on {
                l[i].flags |= 1 << flag;
            } else {
                l[i].flags &= !(1 << flag);
            }
        });
    }
    NONE
}

pub unsafe extern "C" fn get_overlay_flag(_: This, h: u64, flag: u32, on: *mut bool) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_flag");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    out(
        on,
        flag < 32 && LOCAL.with(|l| l[i].flags) & (1 << flag) != 0,
    );
    NONE
}

pub unsafe extern "C" fn get_overlay_flags(_: This, h: u64, flags: *mut u32) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_flags");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    out(flags, LOCAL.with(|l| l[i].flags));
    NONE
}

pub unsafe extern "C" fn set_overlay_color(_: This, h: u64, r: f32, g: f32, b: f32) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_color");
    change(h, |o| o.color = [r, g, b])
}

pub unsafe extern "C" fn get_overlay_color(
    _: This,
    h: u64,
    r: *mut f32,
    g: *mut f32,
    b: *mut f32,
) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_color");
    get(h).map_or_else(
        |e| e,
        |o| {
            out(r, o.color[0]);
            out(g, o.color[1]);
            out(b, o.color[2]);
            NONE
        },
    )
}

pub unsafe extern "C" fn set_overlay_alpha(_: This, h: u64, alpha: f32) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_alpha");
    change(h, |o| o.alpha = alpha.clamp(0.0, 1.0))
}

pub unsafe extern "C" fn get_overlay_alpha(_: This, h: u64, alpha: *mut f32) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_alpha");
    get(h).map_or_else(
        |e| e,
        |o| {
            out(alpha, o.alpha);
            NONE
        },
    )
}

pub unsafe extern "C" fn set_overlay_texel_aspect(_: This, h: u64, aspect: f32) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_texel_aspect");
    if aspect.is_nan() || aspect <= 0.0 {
        return INVALID_PARAMETER;
    }
    change(h, |o| o.texel_aspect = aspect)
}

pub unsafe extern "C" fn get_overlay_texel_aspect(_: This, h: u64, aspect: *mut f32) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_texel_aspect");
    get(h).map_or_else(
        |e| e,
        |o| {
            out(aspect, o.texel_aspect);
            NONE
        },
    )
}

pub unsafe extern "C" fn set_overlay_sort_order(_: This, h: u64, order: u32) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_sort_order");
    change(h, |o| o.sort_order = order)
}

pub unsafe extern "C" fn get_overlay_sort_order(_: This, h: u64, order: *mut u32) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_sort_order");
    get(h).map_or_else(
        |e| e,
        |o| {
            out(order, o.sort_order);
            NONE
        },
    )
}

pub unsafe extern "C" fn set_overlay_width_in_meters(_: This, h: u64, width: f32) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_width_in_meters");
    if width.is_nan() || width <= 0.0 {
        return INVALID_PARAMETER;
    }
    change(h, |o| o.width_m = width)
}

pub unsafe extern "C" fn get_overlay_width_in_meters(_: This, h: u64, width: *mut f32) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_width_in_meters");
    get(h).map_or_else(
        |e| e,
        |o| {
            out(width, o.width_m);
            NONE
        },
    )
}

pub unsafe extern "C" fn set_overlay_auto_curve_distance_range_in_meters(
    _: This,
    h: u64,
    _min: f32,
    _max: f32,
) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_auto_curve_distance_range_in_meters");
    change(h, |_| {})
}

pub unsafe extern "C" fn get_overlay_auto_curve_distance_range_in_meters(
    _: This,
    h: u64,
    min: *mut f32,
    max: *mut f32,
) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_auto_curve_distance_range_in_meters");
    out(min, 0.0);
    out(max, 0.0);
    get(h).map_or_else(|e| e, |_| NONE)
}

pub unsafe extern "C" fn set_overlay_texture_color_space(_: This, h: u64, space: i32) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_texture_color_space");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    LOCAL.with(|l| l[i].color_space = space);
    NONE
}

pub unsafe extern "C" fn get_overlay_texture_color_space(_: This, h: u64, space: *mut i32) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_texture_color_space");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    out(space, LOCAL.with(|l| l[i].color_space));
    NONE
}

pub unsafe extern "C" fn set_overlay_texture_bounds(
    _: This,
    h: u64,
    bounds: *const [f32; 4],
) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_texture_bounds");
    if bounds.is_null() {
        return INVALID_PARAMETER;
    }
    // SAFETY: the game's VRTextureBounds_t.
    let b = unsafe { bounds.read_unaligned() };
    change(h, |o| o.bounds = b)
}

pub unsafe extern "C" fn get_overlay_texture_bounds(_: This, h: u64, bounds: *mut [f32; 4]) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_texture_bounds");
    get(h).map_or_else(
        |e| e,
        |o| {
            out(bounds, o.bounds);
            NONE
        },
    )
}

pub unsafe extern "C" fn get_overlay_render_model(
    _: This,
    _h: u64,
    value: *mut c_char,
    size: u32,
    _color: *mut c_void,
    error: *mut i32,
) -> u32 {
    crate::log::seen!("IVROverlay::get_overlay_render_model");
    set_error(error, NONE);
    write_string(b"\0", value, size).0
}

pub unsafe extern "C" fn set_overlay_render_model(
    _: This,
    h: u64,
    _model: *const c_char,
    _color: *const c_void,
) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_render_model");
    change(h, |_| {})
}

pub unsafe extern "C" fn get_overlay_transform_type(_: This, h: u64, kind: *mut u32) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_transform_type");
    // VROverlayTransform_Absolute 0, _TrackedDeviceRelative 1.
    get(h).map_or_else(
        |e| e,
        |o| {
            out(kind, o.relative);
            NONE
        },
    )
}

/// The seated universe's origin, which a seated transform is relative to.
fn seated_offset(universe: u32) -> [f32; 3] {
    runtime::universe_offset(universe)
}

pub unsafe extern "C" fn set_overlay_transform_absolute(
    _: This,
    h: u64,
    universe: u32,
    transform: *const HmdMatrix34,
) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_transform_absolute");
    if transform.is_null() {
        return INVALID_PARAMETER;
    }
    // SAFETY: the game's matrix.
    let mut m = unsafe { transform.read_unaligned() }.0;
    let offset = seated_offset(universe);
    for (r, o) in m.iter_mut().zip(offset) {
        r[3] += o;
    }
    change(h, |o| {
        o.transform = m;
        o.relative = 0;
    })
}

pub unsafe extern "C" fn get_overlay_transform_absolute(
    _: This,
    h: u64,
    universe: *mut u32,
    transform: *mut HmdMatrix34,
) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_transform_absolute");
    get(h).map_or_else(
        |e| e,
        |o| {
            out(universe, 1); // standing
            out(transform, HmdMatrix34(o.transform));
            NONE
        },
    )
}

pub unsafe extern "C" fn set_overlay_transform_tracked_device_relative(
    _: This,
    h: u64,
    device: u32,
    transform: *const HmdMatrix34,
) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_transform_tracked_device_relative");
    if transform.is_null() {
        return INVALID_PARAMETER;
    }
    if device > ovr::RIGHT {
        return 19; // VROverlayError_InvalidTrackedDevice
    }
    // SAFETY: the game's matrix.
    let m = unsafe { transform.read_unaligned() }.0;
    change(h, |o| {
        o.transform = m;
        o.relative = 1;
        o.device = device;
    })
}

pub unsafe extern "C" fn get_overlay_transform_tracked_device_relative(
    _: This,
    h: u64,
    device: *mut u32,
    transform: *mut HmdMatrix34,
) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_transform_tracked_device_relative");
    get(h).map_or_else(
        |e| e,
        |o| {
            out(device, o.device);
            out(transform, HmdMatrix34(o.transform));
            NONE
        },
    )
}

pub unsafe extern "C" fn set_overlay_transform_tracked_device_component(
    _: This,
    h: u64,
    device: u32,
    _component: *const c_char,
) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_transform_tracked_device_component");
    // No render model components: the device's own pose.
    change(h, |o| {
        o.transform = ovr::IDENTITY34.0;
        o.relative = 1;
        o.device = device.min(ovr::RIGHT);
    })
}

pub unsafe extern "C" fn show_overlay(_: This, h: u64) -> i32 {
    crate::log::seen!("IVROverlay::show_overlay");
    change(h, |o| o.visible = 1)
}

pub unsafe extern "C" fn hide_overlay(_: This, h: u64) -> i32 {
    crate::log::seen!("IVROverlay::hide_overlay");
    change(h, |o| o.visible = 0)
}

pub unsafe extern "C" fn is_overlay_visible(_: This, h: u64) -> bool {
    crate::log::seen!("IVROverlay::is_overlay_visible");
    get(h).is_ok_and(|o| o.visible != 0)
}

// --- the hands as a mouse ---

const EVENT_MOUSE_MOVE: u32 = 300;
const EVENT_MOUSE_DOWN: u32 = 301;
const EVENT_MOUSE_UP: u32 = 302;
const EVENT_FOCUS_ENTER: u32 = 303;
const EVENT_FOCUS_LEAVE: u32 = 304;
const EVENT_SCROLL: u32 = 305;
const MOUSE_LEFT: u32 = 1;
const INPUT_MOUSE: u32 = 1;
/// `VROverlayFlags_SendVRScrollEvents` (`SendVRDiscreteScrollEvents` from 1.0.17), same value.
const FLAG_SCROLL: u32 = 6;

#[derive(Clone, Copy)]
struct Event {
    kind: u32,
    device: u32,
    /// The data's first three words: mouse x, y, button; a scroll's x and y delta; or, for focus,
    /// the overlay's handle (words 0 and 1).
    data: [u32; 3],
}

const QUEUE: usize = 32;

/// Event kinds handed to the game at least once (bit: kind − 300).
static DELIVERED: core::sync::atomic::AtomicU32 = core::sync::atomic::AtomicU32::new(0);

struct Queues {
    events: [[Event; QUEUE]; OVERLAYS],
    first: [usize; OVERLAYS],
    count: [usize; OVERLAYS],
    last: halliday_bridge::PointerState,
    /// The overlay the hand was last over (index), and where in mouse units.
    over: Option<usize>,
    at: [f32; 2],
    started: bool,
}

static QUEUES: Locked<Queues> = Locked::new(Queues {
    events: [[Event {
        kind: 0,
        device: 0,
        data: [0; 3],
    }; QUEUE]; OVERLAYS],
    first: [0; OVERLAYS],
    count: [0; OVERLAYS],
    last: halliday_bridge::PointerState {
        overlay: 0,
        device: 0,
        buttons: 0,
        u: 0.0,
        v: 0.0,
        scroll: 0,
    },
    over: None,
    at: [0.0; 2],
    started: false,
});

fn push(q: &mut Queues, i: usize, e: Event) {
    if q.count[i] == QUEUE {
        // Full (the game doesn't read this overlay's events): drop the oldest.
        q.first[i] = (q.first[i] + 1) % QUEUE;
        q.count[i] -= 1;
    }
    let at = (q.first[i] + q.count[i]) % QUEUE;
    q.events[i][at] = e;
    q.count[i] += 1;
}

fn mouse(kind: u32, device: u32, at: [f32; 2], button: u32) -> Event {
    Event {
        kind,
        device,
        data: [at[0].to_bits(), at[1].to_bits(), button],
    }
}

/// Turns what changed in Halliday's pointer into events for the overlays concerned.
fn take_pointer() {
    let Some(h) = runtime::header() else {
        return;
    };
    // SAFETY: a mapped header.
    let p = unsafe { halliday_bridge::read_pointer(h) };
    let locals = LOCAL.with(|l| *l);
    QUEUES.with(|q| {
        if !q.started {
            q.started = true;
            q.last.scroll = p.scroll;
        }
        let target = (p.overlay as usize)
            .checked_sub(1)
            .filter(|&i| i < OVERLAYS && locals[i].input_method == INPUT_MOUSE);
        let held = p.buttons & 1 != 0;
        let was_held = q.last.buttons & 1 != 0;
        if q.over != target {
            if let Some(old) = q.over {
                if was_held {
                    let at = q.at;
                    push(q, old, mouse(EVENT_MOUSE_UP, q.last.device, at, MOUSE_LEFT));
                }
                let hd = handle(old);
                push(
                    q,
                    old,
                    Event {
                        kind: EVENT_FOCUS_LEAVE,
                        device: q.last.device,
                        data: [hd as u32, (hd >> 32) as u32, 0],
                    },
                );
            }
            if let Some(new) = target {
                let hd = handle(new);
                push(
                    q,
                    new,
                    Event {
                        kind: EVENT_FOCUS_ENTER,
                        device: p.device,
                        data: [hd as u32, (hd >> 32) as u32, 0],
                    },
                );
                log!(
                    "a hand points at overlay {} ({})",
                    new,
                    CStr(locals[new].name.as_ptr().cast())
                );
            }
            q.over = target;
        }
        if let Some(i) = target {
            let scale = locals[i].mouse_scale;
            // GL convention: the picture's bottom left is 0, 0.
            let at = [p.u * scale[0], (1.0 - p.v) * scale[1]];
            if at != q.at || q.last.overlay != p.overlay {
                push(q, i, mouse(EVENT_MOUSE_MOVE, p.device, at, 0));
            }
            if held && !was_held {
                push(q, i, mouse(EVENT_MOUSE_DOWN, p.device, at, MOUSE_LEFT));
            } else if !held && was_held {
                push(q, i, mouse(EVENT_MOUSE_UP, p.device, at, MOUSE_LEFT));
            }
            let scrolled = p.scroll.wrapping_sub(q.last.scroll);
            if scrolled != 0 && locals[i].flags & (1 << FLAG_SCROLL) != 0 {
                let dy = scrolled as f32 / 100.0;
                push(
                    q,
                    i,
                    Event {
                        kind: EVENT_SCROLL,
                        device: p.device,
                        data: [0f32.to_bits(), dy.to_bits(), 0],
                    },
                );
            }
            q.at = at;
        }
        q.last = p;
    });
}

pub unsafe extern "C" fn poll_next_overlay_event(
    _: This,
    h: u64,
    event: *mut c_void,
    size: u32,
) -> bool {
    crate::log::seen!("IVROverlay::poll_next_overlay_event");
    let Some(i) = slot(h) else {
        return false;
    };
    take_pointer();
    let Some(e) = QUEUES.with(|q| {
        (q.count[i] > 0).then(|| {
            let e = q.events[i][q.first[i]];
            q.first[i] = (q.first[i] + 1) % QUEUE;
            q.count[i] -= 1;
            e
        })
    }) else {
        return false;
    };
    // VREvent_t: type, device, age, then the data union (8-aligned, at 16).
    if event.is_null() || size < 32 {
        return false;
    }
    // The first of each kind, for the log.
    let bit = 1u32 << (e.kind - EVENT_MOUSE_MOVE).min(31);
    if DELIVERED.fetch_or(bit, core::sync::atomic::Ordering::Relaxed) & bit == 0 {
        let f = |k: usize| f32::from_bits(e.data[k]);
        log!(
            "overlay {} got its first event {} (x {} y {})",
            i,
            e.kind,
            f(0) as i32,
            f(1) as i32
        );
    }
    // SAFETY: the game's event struct holds `size` bytes.
    unsafe {
        core::ptr::write_bytes(event.cast::<u8>(), 0, size as usize);
        let w = event.cast::<u32>();
        w.write_unaligned(e.kind);
        w.add(1).write_unaligned(e.device);
        for (k, v) in e.data.iter().enumerate() {
            w.add(4 + k).write_unaligned(*v);
        }
    }
    true
}

pub unsafe extern "C" fn get_overlay_input_method(_: This, h: u64, method: *mut u32) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_input_method");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    out(method, LOCAL.with(|l| l[i].input_method));
    NONE
}

pub unsafe extern "C" fn set_overlay_input_method(_: This, h: u64, method: u32) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_input_method");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    LOCAL.with(|l| l[i].input_method = method);
    if method == INPUT_MOUSE {
        log!("overlay {} takes the mouse", i);
    }
    change(h, |o| o.input = (method == INPUT_MOUSE) as u32)
}

pub unsafe extern "C" fn get_overlay_mouse_scale(_: This, h: u64, scale: *mut [f32; 2]) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_mouse_scale");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    out(scale, LOCAL.with(|l| l[i].mouse_scale));
    NONE
}

pub unsafe extern "C" fn set_overlay_mouse_scale(_: This, h: u64, scale: *const [f32; 2]) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_mouse_scale");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    if !scale.is_null() {
        // SAFETY: the game's HmdVector2_t.
        let s = unsafe { scale.read_unaligned() };
        LOCAL.with(|l| l[i].mouse_scale = s);
    }
    NONE
}

/// `VROverlayIntersectionParams_t`.
#[repr(C)]
struct IntersectionParams {
    source: [f32; 3],
    direction: [f32; 3],
    origin: u32,
}

/// `VROverlayIntersectionResults_t`.
#[repr(C)]
struct IntersectionResults {
    point: [f32; 3],
    normal: [f32; 3],
    uv: [f32; 2],
    distance: f32,
}

/// Overlay `o`'s pose in the standing universe, now.
fn world_matrix(o: &Overlay) -> math::Matrix34 {
    if o.relative == 0 {
        return o.transform;
    }
    let state = runtime::latest_state();
    let pose = match o.device {
        ovr::LEFT => state.controllers[0].pose,
        ovr::RIGHT => state.controllers[1].pose,
        _ => state.head,
    };
    math::matrix_mul(
        &math::pose_matrix(pose.position, pose.orientation),
        &o.transform,
    )
}

pub unsafe extern "C" fn compute_overlay_intersection(
    _: This,
    h: u64,
    params: *const c_void,
    results: *mut c_void,
) -> bool {
    crate::log::seen!("IVROverlay::compute_overlay_intersection");
    let (Some(i), Ok(o)) = (slot(h), get(h)) else {
        return false;
    };
    if params.is_null() || o.visible == 0 {
        return false;
    }
    // SAFETY: the game's params struct.
    let p = unsafe { params.cast::<IntersectionParams>().read_unaligned() };
    let offset = runtime::universe_offset(p.origin);
    let source = [
        p.source[0] + offset[0],
        p.source[1] + offset[1],
        p.source[2] + offset[2],
    ];
    let d = p.direction;
    let l = math::sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    if l < 1e-6 {
        return false;
    }
    let direction = [d[0] / l, d[1] / l, d[2] / l];
    let height = runtime::header()
        // SAFETY: a mapped header; an atomic.
        .map(|hd| {
            f32::from_bits(unsafe {
                (*hd).overlay_heights[i].load(core::sync::atomic::Ordering::SeqCst)
            })
        })
        .filter(|&m| m > 0.0)
        .unwrap_or(o.width_m);
    let Some(hit) = math::overlay_hit(&world_matrix(&o), o.width_m, height, source, direction)
    else {
        return false;
    };
    out(
        results.cast::<IntersectionResults>(),
        IntersectionResults {
            point: [
                hit.point[0] - offset[0],
                hit.point[1] - offset[1],
                hit.point[2] - offset[2],
            ],
            normal: hit.normal,
            uv: hit.uv,
            distance: hit.distance,
        },
    );
    true
}

pub unsafe extern "C" fn is_hover_target_overlay(_: This, h: u64) -> bool {
    crate::log::seen!("IVROverlay::is_hover_target_overlay");
    take_pointer();
    slot(h).is_some_and(|i| QUEUES.with(|q| q.over == Some(i)))
}

pub unsafe extern "C" fn get_gamepad_focus_overlay(_: This) -> u64 {
    crate::log::seen!("IVROverlay::get_gamepad_focus_overlay");
    0
}

pub unsafe extern "C" fn set_gamepad_focus_overlay(_: This, _h: u64) -> i32 {
    crate::log::seen!("IVROverlay::set_gamepad_focus_overlay");
    NONE
}

/// Copies at most this often per overlay: games set their overlays' textures every frame, and a
/// copy waits for the GPU.
const COPY_EVERY_MS: f64 = 100.0;

pub unsafe extern "C" fn set_overlay_texture(_: This, h: u64, texture: *const ovr::Texture) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_texture");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    if texture.is_null() {
        return INVALID_TEXTURE;
    }
    if get(h).is_err() {
        return UNKNOWN_OVERLAY;
    }
    let now = runtime::now_ticks();
    let recent = LOCAL.with(|l| {
        let last = l[i].last_copy;
        if last != 0 && runtime::ticks_to_ms(now.wrapping_sub(last)) < COPY_EVERY_MS {
            true
        } else {
            l[i].last_copy = now;
            false
        }
    });
    if recent {
        return NONE;
    }
    // SAFETY: the game's texture description.
    let t = unsafe { &*texture };
    if scene::overlay_texture(i, t) {
        NONE
    } else {
        runtime::warn_once(
            12,
            format_args!(
                "[halliday-vrclient] an overlay's texture couldn't be read (type {})",
                t.kind
            ),
        );
        INVALID_TEXTURE
    }
}

pub unsafe extern "C" fn clear_overlay_texture(_: This, h: u64) -> i32 {
    crate::log::seen!("IVROverlay::clear_overlay_texture");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    scene::overlay_clear(i);
    NONE
}

pub unsafe extern "C" fn set_overlay_raw(
    _: This,
    h: u64,
    buffer: *const c_void,
    w: u32,
    ht: u32,
    depth: u32,
) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_raw");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    if scene::overlay_raw(i, buffer.cast(), w, ht, depth) {
        NONE
    } else {
        INVALID_PARAMETER
    }
}

/// Wine's own conversion of a Windows path to the Mac's (`kernel32.wine_get_unix_file_name`).
fn unix_path(path: &[u8]) -> Option<[u8; 256]> {
    // SAFETY: plain Win32 calls; Wine's function takes a wide path and returns a heap string.
    unsafe {
        let k = crate::win::GetModuleHandleW(
            [
                b'k' as u16,
                b'e' as u16,
                b'r' as u16,
                b'n' as u16,
                b'e' as u16,
                b'l' as u16,
                b'3' as u16,
                b'2' as u16,
                0,
            ]
            .as_ptr(),
        );
        if k.is_null() {
            return None;
        }
        let f = crate::win::GetProcAddress(k, c"wine_get_unix_file_name".as_ptr().cast());
        if f.is_null() {
            return None;
        }
        let f =
            core::mem::transmute::<*const c_void, unsafe extern "C" fn(*const u16) -> *mut u8>(f);
        let mut wide = [0u16; 512];
        for (w, &c) in wide.iter_mut().take(511).zip(path) {
            *w = c as u16;
        }
        let p = f(wide.as_ptr());
        if p.is_null() {
            return None;
        }
        let s = padded::<256>(bytes(p.cast()));
        crate::win::HeapFree(crate::win::GetProcessHeap(), 0, p.cast());
        Some(s)
    }
}

pub unsafe extern "C" fn set_overlay_from_file(_: This, h: u64, path: *const c_char) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_from_file");
    let path = bytes(path);
    let Some(file) = unix_path(path) else {
        return UNABLE_TO_LOAD_FILE;
    };
    log!("overlay picture from {}", CStr(path.as_ptr().cast()));
    change(h, |o| o.file = file)
}

pub unsafe extern "C" fn get_overlay_texture(
    _: This,
    _h: u64,
    _handle: *mut *mut c_void,
    _native: *mut c_void,
    _w: *mut u32,
    _ht: *mut u32,
    _format: *mut u32,
    _api: *mut i32,
    _space: *mut i32,
    _bounds: *mut c_void,
) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_texture");
    REQUEST_FAILED
}

pub unsafe extern "C" fn release_native_overlay_handle(
    _: This,
    _h: u64,
    _native: *mut c_void,
) -> i32 {
    crate::log::seen!("IVROverlay::release_native_overlay_handle");
    NONE
}

pub unsafe extern "C" fn get_overlay_texture_size(
    _: This,
    h: u64,
    w: *mut u32,
    ht: *mut u32,
) -> i32 {
    crate::log::seen!("IVROverlay::get_overlay_texture_size");
    let Some(i) = slot(h) else {
        return INVALID_HANDLE;
    };
    let Some(hd) = runtime::header() else {
        return REQUEST_FAILED;
    };
    // SAFETY: a mapped header.
    let p = unsafe { &(*hd).overlay_pictures[i] };
    out(w, p.width.load(core::sync::atomic::Ordering::Relaxed));
    out(ht, p.height.load(core::sync::atomic::Ordering::Relaxed));
    NONE
}

pub unsafe extern "C" fn create_dashboard_overlay(
    _: This,
    _key: *const c_char,
    _name: *const c_char,
    _main: *mut u64,
    _thumbnail: *mut u64,
) -> i32 {
    crate::log::seen!("IVROverlay::create_dashboard_overlay");
    log!("a dashboard overlay was asked for: Halliday has no dashboard for games yet");
    REQUEST_FAILED
}

pub unsafe extern "C" fn is_dashboard_visible(_: This) -> bool {
    crate::log::seen!("IVROverlay::is_dashboard_visible");
    scene::dashboard()
}

pub unsafe extern "C" fn is_active_dashboard_overlay(_: This, _h: u64) -> bool {
    crate::log::seen!("IVROverlay::is_active_dashboard_overlay");
    false
}

pub unsafe extern "C" fn set_dashboard_overlay_scene_process(_: This, _h: u64, _pid: u32) -> i32 {
    crate::log::seen!("IVROverlay::set_dashboard_overlay_scene_process");
    NONE
}

pub unsafe extern "C" fn get_dashboard_overlay_scene_process(
    _: This,
    _h: u64,
    pid: *mut u32,
) -> i32 {
    crate::log::seen!("IVROverlay::get_dashboard_overlay_scene_process");
    out(pid, 0);
    NONE
}

pub unsafe extern "C" fn show_dashboard(_: This, _overlay: *const c_char) {
    crate::log::seen!("IVROverlay::show_dashboard");
}

pub unsafe extern "C" fn get_primary_dashboard_device(_: This) -> u32 {
    crate::log::seen!("IVROverlay::get_primary_dashboard_device");
    ovr::DEVICE_INVALID
}

pub unsafe extern "C" fn show_keyboard(_: This) -> i32 {
    crate::log::seen!("IVROverlay::show_keyboard");
    log!("the game asked for SteamVR's keyboard: not provided yet");
    REQUEST_FAILED
}

pub unsafe extern "C" fn show_keyboard_for_overlay(_: This) -> i32 {
    crate::log::seen!("IVROverlay::show_keyboard_for_overlay");
    log!("the game asked for SteamVR's keyboard: not provided yet");
    REQUEST_FAILED
}

pub unsafe extern "C" fn get_keyboard_text(_: This, text: *mut c_char, size: u32) -> u32 {
    crate::log::seen!("IVROverlay::get_keyboard_text");
    write_string(b"\0", text, size).0
}

pub unsafe extern "C" fn hide_keyboard(_: This) {
    crate::log::seen!("IVROverlay::hide_keyboard");
}

pub unsafe extern "C" fn set_keyboard_transform_absolute(
    _: This,
    _universe: u32,
    _m: *const HmdMatrix34,
) {
    crate::log::seen!("IVROverlay::set_keyboard_transform_absolute");
}

pub unsafe extern "C" fn set_overlay_intersection_mask(
    _: This,
    _h: u64,
    _primitives: *mut c_void,
    _count: u32,
    _size: u32,
) -> i32 {
    crate::log::seen!("IVROverlay::set_overlay_intersection_mask");
    NONE
}

pub unsafe extern "C" fn show_message_overlay(
    _: This,
    text: *const c_char,
    caption: *const c_char,
) -> i32 {
    crate::log::seen!("IVROverlay::show_message_overlay");
    log!("the game's message: {}: {}", CStr(caption), CStr(text));
    6 // VRMessageOverlayResponse_CouldntFindOrCreateClientOverlay
}

pub unsafe extern "C" fn close_message_overlay(_: This) {
    crate::log::seen!("IVROverlay::close_message_overlay");
}
