//! Direct3D 11 eye textures (`TextureType_DirectX`): read back through the Direct3D 11 API itself,
//! so it works on whatever implements Direct3D under Wine (GameHub and CrossOver's GPTK/D3DMetal,
//! DXMT, DXVK). Without stalling the game (ROADMAP W14.9): each frame `issue` has the GPU copy the
//! eye into a staging texture the CPU may read (`CopySubresourceRegion`, after
//! `ResolveSubresource` if it is multisampled) and returns; a frame later `finish` maps that staging
//! texture, by then filled, the runtime's worker thread copies its rows into the bridge, and
//! `unmap` releases it a frame after that. Two per eye alternate. Method indices from Wine's `d3d11.h` (the order of Microsoft's
//! interfaces), checked against the copy GameHub ships.

use crate::log::log;
use crate::runtime::Locked;
use core::ffi::c_void;

type Obj = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy, Default, PartialEq)]
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
struct Mapped {
    data: *const u8,
    row_pitch: u32,
    depth_pitch: u32,
}

// Method indices (IUnknown 0–2, ID3D11DeviceChild 3–6).
const RELEASE: usize = 2;
const GET_DEVICE: usize = 3;
const TEXTURE_GET_DESC: usize = 10;
const DEVICE_CREATE_TEXTURE_2D: usize = 5;
const DEVICE_GET_IMMEDIATE_CONTEXT: usize = 40;
const CONTEXT_MAP: usize = 14;
const CONTEXT_UNMAP: usize = 15;
const CONTEXT_COPY_SUBRESOURCE_REGION: usize = 46;
const CONTEXT_RESOLVE_SUBRESOURCE: usize = 57;

const USAGE_DEFAULT: u32 = 0;
const USAGE_STAGING: u32 = 3;
const CPU_ACCESS_READ: u32 = 0x20000;
const MAP_READ: u32 = 1;

/// The method `index` of a COM object.
unsafe fn method(obj: Obj, index: usize) -> *const c_void {
    // SAFETY: a COM object starts with a pointer to its table of methods.
    unsafe { *(*(obj as *const *const *const c_void)).add(index) }
}

unsafe fn release(obj: Obj) {
    if !obj.is_null() {
        // SAFETY: IUnknown::Release.
        unsafe {
            core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj) -> u32>(method(
                obj, RELEASE,
            ))(obj)
        };
    }
}

/// Byte order and the typed format of an 8-bit-per-channel format (typeless ones can't be
/// resolved); `None` for formats the bridge doesn't carry yet.
fn eight_bit(format: u32) -> Option<(bool, u32)> {
    match format {
        0x1b..=0x1d => Some((false, if format == 0x1b { 0x1c } else { format })), // R8G8B8A8
        0x57 | 0x5a | 0x5b => Some((true, if format == 0x5a { 0x57 } else { format })), // B8G8R8A8
        0x58 | 0x5c | 0x5d => Some((true, if format == 0x5c { 0x58 } else { format })), // B8G8R8X8
        _ => None,
    }
}

/// What `issue` made, kept for `finish` and the next frames.
struct Cached {
    device: Obj,
    /// [frame parity][eye].
    staging: [[Obj; 2]; 2],
    staging_desc: [[Desc; 2]; 2],
    resolve: [Obj; 2],
    resolve_desc: [Desc; 2],
}

unsafe impl Send for Cached {}

const NO_DESC: Desc = Desc {
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
};

static CACHE: Locked<Cached> = Locked::new(Cached {
    device: core::ptr::null_mut(),
    staging: [[core::ptr::null_mut(); 2]; 2],
    staging_desc: [[NO_DESC; 2]; 2],
    resolve: [core::ptr::null_mut(); 2],
    resolve_desc: [NO_DESC; 2],
});

/// A texture of `desc` on `device`, kept in `slot` while it still matches.
unsafe fn texture(device: Obj, desc: Desc, slot: &mut Obj, kept: &mut Desc) -> Option<Obj> {
    if !slot.is_null() && *kept == desc {
        return Some(*slot);
    }
    // SAFETY: releasing our own texture, then creating one with the device's method.
    unsafe {
        release(*slot);
        *slot = core::ptr::null_mut();
        let create = core::mem::transmute::<
            *const c_void,
            unsafe extern "system" fn(Obj, *const Desc, *const c_void, *mut Obj) -> i32,
        >(method(device, DEVICE_CREATE_TEXTURE_2D));
        let mut t: Obj = core::ptr::null_mut();
        let hr = create(device, &desc, core::ptr::null(), &mut t);
        if hr < 0 || t.is_null() {
            log!(
                "CreateTexture2D ({}x{}, format {:#x}, usage {}) failed: {hr:#x}",
                desc.width,
                desc.height,
                desc.format,
                desc.usage
            );
            return None;
        }
        *slot = t;
        *kept = desc;
        Some(t)
    }
}

unsafe fn immediate_context(device: Obj) -> Obj {
    let mut context: Obj = core::ptr::null_mut();
    // SAFETY: ID3D11Device::GetImmediateContext (adds a reference).
    unsafe {
        core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, *mut Obj)>(method(
            device,
            DEVICE_GET_IMMEDIATE_CONTEXT,
        ))(device, &mut context)
    };
    context
}

/// Starts copying a game's eye texture into the staging texture for (`parity`, `eye`). Its size
/// and whether it is BGRA, or `None` if it can't be read.
///
/// # Safety
/// `source` is an `ID3D11Texture2D`; called on the thread that submits (which owns the immediate
/// context).
pub unsafe fn issue(source: Obj, parity: usize, eye: usize) -> Option<(u32, u32, bool)> {
    if source.is_null() {
        return None;
    }
    // SAFETY (whole function): COM calls on the game's objects, with the methods' signatures.
    unsafe {
        let mut desc = Desc::default();
        core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, *mut Desc)>(method(
            source,
            TEXTURE_GET_DESC,
        ))(source, &mut desc);
        let Some((bgra, typed)) = eight_bit(desc.format) else {
            crate::runtime::warn_once(
                5,
                format_args!(
                    "[halliday-vrclient] Direct3D 11 eye format {:#x} isn't supported yet",
                    desc.format
                ),
            );
            return None;
        };
        // The left eye may take both eyes' areas (when the right shares its texture).
        let fits = if eye == 0 {
            halliday_bridge::fits_shared(desc.width, desc.height)
        } else {
            halliday_bridge::fits(desc.width, desc.height)
        };
        if !fits {
            crate::runtime::warn_once(
                1,
                format_args!(
                    "[halliday-vrclient] eye texture {}x{} is larger than the bridge holds",
                    desc.width, desc.height
                ),
            );
            return None;
        }
        let mut device: Obj = core::ptr::null_mut();
        core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, *mut Obj)>(method(
            source, GET_DEVICE,
        ))(source, &mut device);
        if device.is_null() {
            return None;
        }
        let context = immediate_context(device);
        let result = CACHE.with(|c| {
            if c.device != device {
                for t in c.staging.iter_mut().flatten().chain(c.resolve.iter_mut()) {
                    release(*t);
                    *t = core::ptr::null_mut();
                }
                c.device = device; // not kept alive: the game owns it for as long as it submits
            }
            let mut from = source;
            if desc.sample_count > 1 {
                let resolve_desc = Desc {
                    format: typed,
                    mip_levels: 1,
                    array_size: 1,
                    sample_count: 1,
                    sample_quality: 0,
                    usage: USAGE_DEFAULT,
                    bind_flags: 0,
                    cpu_access: 0,
                    misc_flags: 0,
                    ..desc
                };
                let resolve = texture(
                    device,
                    resolve_desc,
                    &mut c.resolve[eye],
                    &mut c.resolve_desc[eye],
                )?;
                core::mem::transmute::<
                    *const c_void,
                    unsafe extern "system" fn(Obj, Obj, u32, Obj, u32, u32),
                >(method(context, CONTEXT_RESOLVE_SUBRESOURCE))(
                    context, resolve, 0, source, 0, typed,
                );
                from = resolve;
            }
            let staging_desc = Desc {
                format: if desc.sample_count > 1 {
                    typed
                } else {
                    desc.format
                },
                mip_levels: 1,
                array_size: 1,
                sample_count: 1,
                sample_quality: 0,
                usage: USAGE_STAGING,
                bind_flags: 0,
                cpu_access: CPU_ACCESS_READ,
                misc_flags: 0,
                ..desc
            };
            let staging = texture(
                device,
                staging_desc,
                &mut c.staging[parity][eye],
                &mut c.staging_desc[parity][eye],
            )?;
            core::mem::transmute::<
                *const c_void,
                unsafe extern "system" fn(Obj, Obj, u32, u32, u32, u32, Obj, u32, *const c_void),
            >(method(context, CONTEXT_COPY_SUBRESOURCE_REGION))(
                context,
                staging,
                0,
                0,
                0,
                0,
                from,
                0,
                core::ptr::null(),
            );
            Some((desc.width, desc.height, bgra))
        });
        release(context);
        release(device);
        result
    }
}

/// Maps the staging texture for (`parity`, `eye`), filled since `issue` a frame ago: a pointer to
/// its rows and their pitch, valid until `unmap`.
///
/// # Safety
/// As `issue`.
pub unsafe fn map(parity: usize, eye: usize) -> Option<(*const u8, usize)> {
    // SAFETY (whole function): COM calls on our staging texture and the game's device.
    unsafe {
        CACHE.with(|c| {
            let (device, staging) = (c.device, c.staging[parity][eye]);
            if device.is_null() || staging.is_null() {
                return None;
            }
            let context = immediate_context(device);
            let t0 = crate::runtime::now_ticks();
            let mut mapped = Mapped {
                data: core::ptr::null(),
                row_pitch: 0,
                depth_pitch: 0,
            };
            let hr = core::mem::transmute::<
                *const c_void,
                unsafe extern "system" fn(Obj, Obj, u32, u32, u32, *mut Mapped) -> i32,
            >(method(context, CONTEXT_MAP))(
                context, staging, 0, MAP_READ, 0, &mut mapped
            );
            crate::runtime::MAP_TICKS.fetch_add(
                crate::runtime::now_ticks().wrapping_sub(t0),
                core::sync::atomic::Ordering::Relaxed,
            );
            release(context);
            if hr < 0 || mapped.data.is_null() {
                crate::runtime::warn_once(
                    6,
                    format_args!("[halliday-vrclient] mapping the staging texture failed: {hr:#x}"),
                );
                return None;
            }
            Some((mapped.data, mapped.row_pitch as usize))
        })
    }
}

/// Unmaps what `map` mapped.
///
/// # Safety
/// As `issue`.
pub unsafe fn unmap(parity: usize, eye: usize) {
    // SAFETY: COM calls on our staging texture and the game's device.
    unsafe {
        CACHE.with(|c| {
            let (device, staging) = (c.device, c.staging[parity][eye]);
            if device.is_null() || staging.is_null() {
                return;
            }
            let context = immediate_context(device);
            core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, Obj, u32)>(
                method(context, CONTEXT_UNMAP),
            )(context, staging, 0);
            release(context);
        })
    }
}

/// The thread that submits frames (it owns the immediate context the game draws with).
static SUBMIT_THREAD: core::sync::atomic::AtomicU32 = core::sync::atomic::AtomicU32::new(0);

/// Notes the submitting thread (called from `issue`'s caller).
pub fn note_submit_thread() {
    // SAFETY: plain call.
    let id = unsafe { crate::win::GetCurrentThreadId() };
    SUBMIT_THREAD.store(id, core::sync::atomic::Ordering::Relaxed);
}

/// What `read_once` keeps between calls.
struct Once {
    device: Obj,
    staging: Obj,
    staging_desc: Desc,
    resolve: Obj,
    resolve_desc: Desc,
    /// The device whose immediate context was made thread-safe (`ID3D11Multithread`).
    protected: Obj,
}

unsafe impl Send for Once {}

static ONCE: Locked<Once> = Locked::new(Once {
    device: core::ptr::null_mut(),
    staging: core::ptr::null_mut(),
    staging_desc: NO_DESC,
    resolve: core::ptr::null_mut(),
    resolve_desc: NO_DESC,
    protected: core::ptr::null_mut(),
});

/// `ID3D11Multithread`'s IID, {9B7E4E00-342C-4106-A19F-4F2704F689F0}.
const IID_MULTITHREAD: [u8; 16] = [
    0x00, 0x4E, 0x7E, 0x9B, 0x2C, 0x34, 0x06, 0x41, 0xA1, 0x9F, 0x4F, 0x27, 0x04, 0xF6, 0x89, 0xF0,
];

/// Makes the device's immediate context safe to call from two threads, the game's render thread
/// and the one calling the runtime now (a game sets overlays and its skybox from its main thread).
unsafe fn protect(context: Obj) -> bool {
    // SAFETY: IUnknown::QueryInterface, then ID3D11Multithread::SetMultithreadProtected (5).
    unsafe {
        let mut mt: Obj = core::ptr::null_mut();
        let hr = core::mem::transmute::<
            *const c_void,
            unsafe extern "system" fn(Obj, *const u8, *mut Obj) -> i32,
        >(method(context, 0))(context, IID_MULTITHREAD.as_ptr(), &mut mt);
        if hr < 0 || mt.is_null() {
            return false;
        }
        core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, i32) -> i32>(method(
            mt, 5,
        ))(mt, 1);
        release(mt);
        true
    }
}

/// Reads a game's Direct3D 11 texture now (waiting for the GPU) and hands its pixels to `f`: for
/// overlays and the skybox, which change rarely. `None` if it can't be read.
///
/// # Safety
/// `source` is an `ID3D11Texture2D` of the game's.
pub unsafe fn read_once<R>(
    source: Obj,
    f: impl FnOnce(&halliday_bridge::picture::Source) -> R,
) -> Option<R> {
    if source.is_null() {
        return None;
    }
    // SAFETY (whole function): COM calls on the game's objects and ours, with their signatures.
    unsafe {
        let mut desc = Desc::default();
        core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, *mut Desc)>(method(
            source,
            TEXTURE_GET_DESC,
        ))(source, &mut desc);
        let (bgra, typed) = eight_bit(desc.format)?;
        let opaque = matches!(desc.format, 0x58 | 0x5c | 0x5d);
        let mut device: Obj = core::ptr::null_mut();
        core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, *mut Obj)>(method(
            source, GET_DEVICE,
        ))(source, &mut device);
        if device.is_null() {
            return None;
        }
        let context = immediate_context(device);
        let result = ONCE.with(|c| {
            if c.device != device {
                for t in [&mut c.staging, &mut c.resolve] {
                    release(*t);
                    *t = core::ptr::null_mut();
                }
                c.device = device;
            }
            let here = crate::win::GetCurrentThreadId();
            let submitter = SUBMIT_THREAD.load(core::sync::atomic::Ordering::Relaxed);
            if submitter != 0 && submitter != here && c.protected != device {
                c.protected = device;
                if protect(context) {
                    log!("Direct3D 11: the game's context made thread-safe (overlays come from another thread)");
                } else {
                    log!("Direct3D 11: couldn't make the context thread-safe; reading overlays anyway");
                }
            }
            let mut from = source;
            if desc.sample_count > 1 {
                let resolve_desc = Desc {
                    format: typed,
                    mip_levels: 1,
                    array_size: 1,
                    sample_count: 1,
                    sample_quality: 0,
                    usage: USAGE_DEFAULT,
                    bind_flags: 0,
                    cpu_access: 0,
                    misc_flags: 0,
                    ..desc
                };
                let resolve = texture(device, resolve_desc, &mut c.resolve, &mut c.resolve_desc)?;
                core::mem::transmute::<
                    *const c_void,
                    unsafe extern "system" fn(Obj, Obj, u32, Obj, u32, u32),
                >(method(context, CONTEXT_RESOLVE_SUBRESOURCE))(
                    context, resolve, 0, source, 0, typed,
                );
                from = resolve;
            }
            let staging_desc = Desc {
                format: if desc.sample_count > 1 { typed } else { desc.format },
                mip_levels: 1,
                array_size: 1,
                sample_count: 1,
                sample_quality: 0,
                usage: USAGE_STAGING,
                bind_flags: 0,
                cpu_access: CPU_ACCESS_READ,
                misc_flags: 0,
                ..desc
            };
            let staging = texture(device, staging_desc, &mut c.staging, &mut c.staging_desc)?;
            core::mem::transmute::<
                *const c_void,
                unsafe extern "system" fn(Obj, Obj, u32, u32, u32, u32, Obj, u32, *const c_void),
            >(method(context, CONTEXT_COPY_SUBRESOURCE_REGION))(
                context,
                staging,
                0,
                0,
                0,
                0,
                from,
                0,
                core::ptr::null(),
            );
            let mut mapped = Mapped {
                data: core::ptr::null(),
                row_pitch: 0,
                depth_pitch: 0,
            };
            let hr = core::mem::transmute::<
                *const c_void,
                unsafe extern "system" fn(Obj, Obj, u32, u32, u32, *mut Mapped) -> i32,
            >(method(context, CONTEXT_MAP))(
                context, staging, 0, MAP_READ, 0, &mut mapped
            );
            if hr < 0 || mapped.data.is_null() {
                return None;
            }
            let r = f(&halliday_bridge::picture::Source {
                ptr: mapped.data,
                pitch: mapped.row_pitch as usize,
                width: desc.width,
                height: desc.height,
                bgra,
                bottom_up: false,
                opaque,
                premultiplied: false,
            });
            core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, Obj, u32)>(
                method(context, CONTEXT_UNMAP),
            )(context, staging, 0);
            Some(r)
        });
        release(context);
        release(device);
        result
    }
}

// --- Pacing (ROADMAP W14.9) -------------------------------------------------------------------
//
// A game whose GPU work takes longer than a display frame runs ahead on the CPU: its frames, and
// the poses they were drawn from, wait in Direct3D's queue (the Unity game at 120 Hz: poses 54 ms old at
// the eyes). SteamVR's `WaitGetPoses` waits until the GPU has finished the previous frame; so does
// this one: the frame's last submit ends an event query on the game's device, and `wait_frame_end`
// waits for it before the next pose is read. `HALLIDAY_GPU_WAIT=0` in the game's environment turns
// it off (to compare).

const DEVICE_CREATE_QUERY: usize = 24;
const CONTEXT_END: usize = 28;
const CONTEXT_GET_DATA: usize = 29;
const QUERY_EVENT: u32 = 0;
const GET_DATA_DO_NOT_FLUSH: u32 = 1;

struct Pacing {
    device: Obj,
    query: Obj,
    /// An event was ended and not yet waited for.
    pending: bool,
    /// The device whose context was made thread-safe for a wait from another thread.
    protected: Obj,
    // Statistics, logged every 600 waits.
    waits: u32,
    waited: u32,
    ms: f64,
    max: f64,
    timeouts: u32,
}

unsafe impl Send for Pacing {}

static PACING: Locked<Pacing> = Locked::new(Pacing {
    device: core::ptr::null_mut(),
    query: core::ptr::null_mut(),
    pending: false,
    protected: core::ptr::null_mut(),
    waits: 0,
    waited: 0,
    ms: 0.0,
    max: 0.0,
    timeouts: 0,
});

/// Off with `HALLIDAY_GPU_WAIT=0`.
fn pacing_on() -> bool {
    use core::sync::atomic::{AtomicU8, Ordering};
    static ON: AtomicU8 = AtomicU8::new(0); // 0 unknown, 1 on, 2 off
    match ON.load(Ordering::Relaxed) {
        1 => true,
        2 => false,
        _ => {
            let mut value = [0u8; 8];
            // SAFETY: a NUL-terminated name and a buffer of its size.
            let n = unsafe {
                crate::win::GetEnvironmentVariableA(
                    c"HALLIDAY_GPU_WAIT".as_ptr().cast(),
                    value.as_mut_ptr(),
                    value.len() as u32,
                )
            };
            let on = !(n == 1 && value[0] == b'0');
            ON.store(if on { 1 } else { 2 }, Ordering::Relaxed);
            if !on {
                log!("pacing: off (HALLIDAY_GPU_WAIT=0): WaitGetPoses doesn't wait for the GPU");
            }
            on
        }
    }
}

/// Marks the end of a frame's GPU work, after its last submit.
///
/// # Safety
/// `texture` is the frame's `ID3D11Texture2D`; on the thread that submits.
pub unsafe fn mark_frame_end(texture: Obj) {
    if texture.is_null() || !pacing_on() {
        return;
    }
    // SAFETY (whole function): COM calls on the game's objects and ours, with their signatures.
    unsafe {
        let mut device: Obj = core::ptr::null_mut();
        core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, *mut Obj)>(method(
            texture, GET_DEVICE,
        ))(texture, &mut device);
        if device.is_null() {
            return;
        }
        let context = immediate_context(device);
        PACING.with(|p| {
            if p.device != device {
                release(p.query);
                p.query = core::ptr::null_mut();
                p.pending = false;
                p.device = device; // not kept alive, as in `issue`
                let desc = [QUERY_EVENT, 0];
                let hr = core::mem::transmute::<
                    *const c_void,
                    unsafe extern "system" fn(Obj, *const u32, *mut Obj) -> i32,
                >(method(device, DEVICE_CREATE_QUERY))(
                    device, desc.as_ptr(), &mut p.query
                );
                if hr < 0 || p.query.is_null() {
                    p.query = core::ptr::null_mut();
                    log!(
                        "pacing: CreateQuery failed ({hr:#x}): WaitGetPoses won't wait for the GPU"
                    );
                } else {
                    log!("pacing: WaitGetPoses waits for the previous frame's GPU work");
                }
            }
            if !p.query.is_null() {
                core::mem::transmute::<*const c_void, unsafe extern "system" fn(Obj, Obj)>(method(
                    context,
                    CONTEXT_END,
                ))(context, p.query);
                p.pending = true;
            }
        });
        release(context);
        release(device);
    }
}

/// Waits (at most `timeout_ms`) until the GPU has finished the frame `mark_frame_end` marked.
pub fn wait_frame_end(timeout_ms: f64) {
    let (device, query, protect_it) = PACING.with(|p| {
        let pending = core::mem::replace(&mut p.pending, false);
        if !pending || p.query.is_null() {
            return (core::ptr::null_mut(), core::ptr::null_mut(), false);
        }
        // SAFETY: plain call.
        let here = unsafe { crate::win::GetCurrentThreadId() };
        let submitter = SUBMIT_THREAD.load(core::sync::atomic::Ordering::Relaxed);
        let protect_it = submitter != here && p.protected != p.device;
        if protect_it {
            p.protected = p.device;
        }
        (p.device, p.query, protect_it)
    });
    if query.is_null() {
        return;
    }
    let start = crate::runtime::now_ticks();
    let mut done = false;
    let mut waited = false;
    // SAFETY (block): COM calls on the game's device and our query, with their signatures.
    unsafe {
        let context = immediate_context(device);
        if protect_it && protect(context) {
            log!(
                "pacing: the game's context made thread-safe (WaitGetPoses comes from another thread)"
            );
        }
        let get_data = core::mem::transmute::<
            *const c_void,
            unsafe extern "system" fn(Obj, Obj, *mut c_void, u32, u32) -> i32,
        >(method(context, CONTEXT_GET_DATA));
        let mut flags = 0; // the first call flushes, so the GPU has the work
        loop {
            let hr = get_data(context, query, core::ptr::null_mut(), 0, flags);
            if hr != 1 {
                // S_OK: finished; an error: don't wait on it.
                done = hr == 0;
                break;
            }
            flags = GET_DATA_DO_NOT_FLUSH;
            waited = true;
            if crate::runtime::ticks_to_ms(crate::runtime::now_ticks().wrapping_sub(start))
                >= timeout_ms
            {
                break;
            }
            crate::win::Sleep(0);
        }
        release(context);
    }
    let ms = crate::runtime::ticks_to_ms(crate::runtime::now_ticks().wrapping_sub(start));
    PACING.with(|p| {
        p.waits += 1;
        if waited {
            p.waited += 1;
        }
        if !done {
            p.timeouts += 1;
        }
        p.ms += ms;
        p.max = p.max.max(ms);
        if p.waits == 600 {
            log!(
                "pacing: 600 frames, {} waited for the GPU, {:.2} ms a frame, {:.2} ms max, {} gave up",
                p.waited,
                p.ms / 600.0,
                p.max,
                p.timeouts
            );
            (p.waits, p.waited, p.ms, p.max, p.timeouts) = (0, 0, 0.0, 0.0, 0);
        }
    });
}
