//! OpenGL contexts macOS can give: a game under Wine asking for a 3.2+ *compatibility* context
//! gets nothing on a Mac (Apple's OpenGL has only a 2.1 legacy context and 3.2+ core,
//! forward-compatible ones), and quits. The OpenGL game does exactly that right after VR_Init.
//!
//! The runtime is loaded before the game makes its contexts, so it redirects the game's import of
//! `wglGetProcAddress` (in the game's import table, in memory: no file is changed) and, when the
//! game asks for `wglCreateContextAttribsARB`, hands it a version that turns a 3.2+ compatibility
//! request into a core, forward-compatible one, which Wine can create on macOS.

use crate::log::log;
use crate::win;
use core::ffi::c_void;
use core::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

type GetProcAddress = unsafe extern "system" fn(name: *const u8) -> *const c_void;
type CreateContextAttribs = unsafe extern "system" fn(
    hdc: *mut c_void,
    share: *mut c_void,
    attribs: *const i32,
) -> *mut c_void;

static REAL_GET_PROC: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static REAL_CREATE: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static INSTALLED: AtomicBool = AtomicBool::new(false);
/// The attributes of the game's latest `wglCreateContextAttribsARB` context, as created (zero-
/// terminated); `[0, …]` if it made none that way. Its window of frames (present.rs) makes a
/// context like it, sharing its objects.
static ATTRIBS: crate::runtime::Locked<[i32; 66]> = crate::runtime::Locked::new([0; 66]);

const MAJOR: i32 = 0x2091;
const MINOR: i32 = 0x2092;
const FLAGS: i32 = 0x2094;
const PROFILE: i32 = 0x9126;
const CORE_PROFILE: i32 = 1;
const FORWARD_COMPATIBLE: i32 = 2;

fn name_is(name: *const u8, wanted: &[u8]) -> bool {
    if name.is_null() || (name as usize) < 0x10000 {
        return false; // an ordinal, not a name
    }
    for (i, &w) in wanted.iter().enumerate() {
        // SAFETY: a NUL-terminated name from the game; stops at the first difference.
        if unsafe { *name.add(i) } != w {
            return false;
        }
    }
    // SAFETY: as above.
    unsafe { *name.add(wanted.len()) == 0 }
}

unsafe extern "system" fn get_proc_address(name: *const u8) -> *const c_void {
    let real = REAL_GET_PROC.load(Ordering::Acquire);
    // SAFETY: the original wglGetProcAddress, saved before the import was redirected.
    let real_get = unsafe { core::mem::transmute::<*mut c_void, GetProcAddress>(real) };
    // SAFETY: as above.
    let f = unsafe { real_get(name) };
    if f.is_null() {
        return f;
    }
    if name_is(name, b"wglCreateContextAttribsARB") {
        REAL_CREATE.store(f as *mut c_void, Ordering::Release);
        return create_context_attribs as *const c_void;
    }
    // The game's shaders, written for the compatibility context, translated for the core one.
    if name_is(name, b"glShaderSource") {
        // SAFETY: looking up the functions the translation needs, in the same context.
        unsafe { remember_shader_functions(real_get) };
        REAL_SHADER_SOURCE.store(f as *mut c_void, Ordering::Release);
        return shader_source as *const c_void;
    }
    // Shader diagnostics: what fails to compile or link is logged with the driver's message.
    if name_is(name, b"glCompileShader") {
        // SAFETY: looking up the functions the check needs, in the same context.
        unsafe { remember_shader_functions(real_get) };
        REAL_COMPILE.store(f as *mut c_void, Ordering::Release);
        return compile_shader as *const c_void;
    }
    if name_is(name, b"glLinkProgram") {
        // SAFETY: as above.
        unsafe { remember_shader_functions(real_get) };
        REAL_LINK.store(f as *mut c_void, Ordering::Release);
        return link_program as *const c_void;
    }
    f
}

static REAL_COMPILE: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static REAL_SHADER_SOURCE: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
/// Set once a compatibility request was turned into a core context: its shaders get translated.
static CORE_FORCED: AtomicBool = AtomicBool::new(false);
static TRANSLATED: core::sync::atomic::AtomicU32 = core::sync::atomic::AtomicU32::new(0);

type ShaderSource = unsafe extern "system" fn(
    shader: u32,
    count: i32,
    strings: *const *const u8,
    lengths: *const i32,
);

const SOURCE_BYTES: usize = 128 * 1024;
static SOURCE_BUFFERS: crate::runtime::Locked<(
    [u8; SOURCE_BYTES],
    [u8; SOURCE_BYTES + 32 * 1024],
)> = crate::runtime::Locked::new(([0; SOURCE_BYTES], [0; SOURCE_BYTES + 32 * 1024]));

unsafe extern "system" fn shader_source(
    shader: u32,
    count: i32,
    strings: *const *const u8,
    lengths: *const i32,
) {
    // SAFETY: the real function, from the real wglGetProcAddress.
    let real = unsafe {
        core::mem::transmute::<*mut c_void, ShaderSource>(
            REAL_SHADER_SOURCE.load(Ordering::Acquire),
        )
    };
    let iv = GET_SHADER_IV.load(Ordering::Relaxed);
    if !CORE_FORCED.load(Ordering::Relaxed) || iv.is_null() || strings.is_null() || count <= 0 {
        // SAFETY: the game's call, unchanged.
        return unsafe { real(shader, count, strings, lengths) };
    }
    let mut kind = 0;
    // SAFETY: a GL call in the game's current context.
    unsafe { core::mem::transmute::<*mut c_void, GetIv>(iv)(shader, 0x8B4F, &mut kind) }; // SHADER_TYPE
    let fragment = kind == 0x8B30;
    let done = SOURCE_BUFFERS.with(|(input, output)| {
        let mut len = 0usize;
        for i in 0..count as usize {
            // SAFETY: the game's array of `count` strings, with lengths or NUL-terminated.
            let (p, n) = unsafe {
                let p = *strings.add(i);
                let n = if lengths.is_null() || *lengths.add(i) < 0 {
                    let mut n = 0;
                    while *p.add(n) != 0 {
                        n += 1;
                    }
                    n
                } else {
                    *lengths.add(i) as usize
                };
                (p, n)
            };
            if len + n > input.len() {
                return false;
            }
            // SAFETY: `n` bytes of the game's string.
            input[len..len + n].copy_from_slice(unsafe { core::slice::from_raw_parts(p, n) });
            len += n;
        }
        let Some(out) = halliday_bridge::glsl::translate(&input[..len], fragment, output) else {
            return false;
        };
        let (ptr, n) = (output.as_ptr(), out as i32);
        // SAFETY: one translated string of `n` bytes.
        unsafe { real(shader, 1, &ptr, &n) };
        true
    });
    if done {
        if TRANSLATED.fetch_add(1, Ordering::Relaxed) == 0 {
            log!("translating the game's shaders to GLSL 1.50 for the core context");
        }
    } else {
        // SAFETY: the game's call, unchanged (too long to translate).
        unsafe { real(shader, count, strings, lengths) };
    }
}
static REAL_LINK: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static GET_SHADER_IV: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static GET_SHADER_LOG: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static GET_SHADER_SOURCE: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static GET_PROGRAM_IV: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static GET_PROGRAM_LOG: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static FAILURES: core::sync::atomic::AtomicU32 = core::sync::atomic::AtomicU32::new(0);
static COMPILED: core::sync::atomic::AtomicU32 = core::sync::atomic::AtomicU32::new(0);

type GetIv = unsafe extern "system" fn(object: u32, name: u32, value: *mut i32);
type GetLog = unsafe extern "system" fn(object: u32, size: i32, length: *mut i32, log: *mut u8);
type Object = unsafe extern "system" fn(object: u32);

unsafe fn remember_shader_functions(get: GetProcAddress) {
    for (slot, name) in [
        (&GET_SHADER_IV, c"glGetShaderiv"),
        (&GET_SHADER_LOG, c"glGetShaderInfoLog"),
        (&GET_SHADER_SOURCE, c"glGetShaderSource"),
        (&GET_PROGRAM_IV, c"glGetProgramiv"),
        (&GET_PROGRAM_LOG, c"glGetProgramInfoLog"),
    ] {
        if slot.load(Ordering::Relaxed).is_null() {
            // SAFETY: the real wglGetProcAddress.
            slot.store(
                unsafe { get(name.as_ptr().cast()) } as *mut c_void,
                Ordering::Relaxed,
            );
        }
    }
}

/// Logs `text` (a driver log or shader source) in lines, at most `max` bytes.
fn log_text(prefix: &str, text: &[u8], max: usize) {
    for (i, line) in text[..text.len().min(max)]
        .split(|&c| c == b'\n')
        .enumerate()
        .take(1000)
    {
        if line.iter().all(|c| c.is_ascii_whitespace()) {
            continue;
        }
        let s = core::str::from_utf8(line).unwrap_or("?");
        log!("  {prefix} {}: {s}", i + 1);
    }
}

unsafe extern "system" fn compile_shader(shader: u32) {
    // SAFETY: the real function, from the real wglGetProcAddress.
    unsafe {
        core::mem::transmute::<*mut c_void, Object>(REAL_COMPILE.load(Ordering::Acquire))(shader)
    };
    COMPILED.fetch_add(1, Ordering::Relaxed);
    let (iv, get_log, get_source) = (
        GET_SHADER_IV.load(Ordering::Relaxed),
        GET_SHADER_LOG.load(Ordering::Relaxed),
        GET_SHADER_SOURCE.load(Ordering::Relaxed),
    );
    if iv.is_null() || get_log.is_null() {
        return;
    }
    let mut ok = 1;
    // SAFETY: GL calls in the game's current context.
    unsafe { core::mem::transmute::<*mut c_void, GetIv>(iv)(shader, 0x8B81, &mut ok) }; // COMPILE_STATUS
    if ok != 0 || FAILURES.fetch_add(1, Ordering::Relaxed) >= 12 {
        return;
    }
    let mut buf = [0u8; 1024];
    let mut n = 0;
    // SAFETY: as above; the buffer holds 1024 bytes.
    unsafe {
        core::mem::transmute::<*mut c_void, GetLog>(get_log)(shader, 1024, &mut n, buf.as_mut_ptr())
    };
    log!("shader {shader} failed to compile:");
    log_text("error:", &buf[..(n.max(0) as usize).min(1024)], 600);
    if !get_source.is_null() {
        static SOURCE: crate::runtime::Locked<[u8; 65536]> =
            crate::runtime::Locked::new([0; 65536]);
        SOURCE.with(|src| {
            let mut n = 0;
            // SAFETY: as above; the buffer holds 16 KiB.
            unsafe {
                core::mem::transmute::<*mut c_void, GetLog>(get_source)(
                    shader,
                    65536,
                    &mut n,
                    src.as_mut_ptr(),
                )
            };
            log_text("source:", &src[..(n.max(0) as usize).min(65536)], 65536);
        });
    }
}

unsafe extern "system" fn link_program(program: u32) {
    // SAFETY: the real function, from the real wglGetProcAddress.
    unsafe {
        core::mem::transmute::<*mut c_void, Object>(REAL_LINK.load(Ordering::Acquire))(program)
    };
    let (iv, get_log) = (
        GET_PROGRAM_IV.load(Ordering::Relaxed),
        GET_PROGRAM_LOG.load(Ordering::Relaxed),
    );
    if iv.is_null() || get_log.is_null() {
        return;
    }
    let mut ok = 1;
    // SAFETY: GL calls in the game's current context.
    unsafe { core::mem::transmute::<*mut c_void, GetIv>(iv)(program, 0x8B82, &mut ok) }; // LINK_STATUS
    if ok != 0 || FAILURES.fetch_add(1, Ordering::Relaxed) >= 12 {
        return;
    }
    let mut buf = [0u8; 1024];
    let mut n = 0;
    // SAFETY: as above.
    unsafe {
        core::mem::transmute::<*mut c_void, GetLog>(get_log)(
            program,
            1024,
            &mut n,
            buf.as_mut_ptr(),
        )
    };
    log!("program {program} failed to link:");
    log_text("error:", &buf[..(n.max(0) as usize).min(1024)], 600);
}

/// Shaders compiled so far, and how many failed (for the frame log).
pub fn shader_counts() -> (u32, u32) {
    (
        COMPILED.load(Ordering::Relaxed),
        FAILURES.load(Ordering::Relaxed),
    )
}

unsafe extern "system" fn create_context_attribs(
    hdc: *mut c_void,
    share: *mut c_void,
    attribs: *const i32,
) -> *mut c_void {
    let real = REAL_CREATE.load(Ordering::Acquire);
    // SAFETY: the original function, from the real wglGetProcAddress.
    let create = unsafe { core::mem::transmute::<*mut c_void, CreateContextAttribs>(real) };
    let mut list = [0i32; 66];
    let mut n = 0;
    if !attribs.is_null() {
        // SAFETY: a zero-terminated list of pairs from the game (at most 32 pairs read).
        while n < 64 && unsafe { *attribs.add(n) } != 0 {
            list[n] = unsafe { *attribs.add(n) };
            list[n + 1] = unsafe { *attribs.add(n + 1) };
            n += 2;
        }
    }
    let value = |list: &[i32], key: i32| {
        list.chunks(2)
            .take(n / 2)
            .find(|p| p[0] == key)
            .map(|p| p[1])
    };
    let (major, minor) = (
        value(&list, MAJOR).unwrap_or(1),
        value(&list, MINOR).unwrap_or(0),
    );
    let profile = value(&list, PROFILE).unwrap_or(CORE_PROFILE);
    let flags = value(&list, FLAGS).unwrap_or(0);
    if major * 10 + minor >= 32 && (profile != CORE_PROFILE || flags & FORWARD_COMPATIBLE == 0) {
        log!(
            "the game asks for an OpenGL {major}.{minor} compatibility context: macOS only has core ones, asking for core"
        );
        let mut set = |key: i32, v: i32| match list.chunks_mut(2).take(n / 2).find(|p| p[0] == key)
        {
            Some(p) => p[1] = v,
            None if n < 64 => {
                list[n] = key;
                list[n + 1] = v;
                n += 2;
            }
            None => {}
        };
        set(PROFILE, CORE_PROFILE);
        CORE_FORCED.store(true, Ordering::Relaxed);
        set(FLAGS, flags | FORWARD_COMPATIBLE);
        list[n] = 0;
        // SAFETY: the original function with a valid, zero-terminated list.
        let ctx = unsafe { create(hdc, share, list.as_ptr()) };
        if !ctx.is_null() {
            ATTRIBS.with(|a| *a = list);
        }
        log!(
            "core context: {}",
            if ctx.is_null() { "failed" } else { "created" }
        );
        return ctx;
    }
    // SAFETY: the game's own request, unchanged.
    let ctx = unsafe { create(hdc, share, attribs) };
    if !ctx.is_null() {
        list[n] = 0;
        ATTRIBS.with(|a| *a = list);
    }
    ctx
}

/// A new context on `hdc` sharing the objects of `share` (the game's), made the way the game made
/// its own: with the same attributes if it used `wglCreateContextAttribsARB`, else the classic way.
///
/// # Safety
/// `hdc` has the pixel format of the game's drawable; `share` is the game's context, current on
/// this thread or on none.
pub unsafe fn context_like_the_games(hdc: *mut c_void, share: *mut c_void) -> *mut c_void {
    let list = ATTRIBS.with(|a| *a);
    let real = REAL_CREATE.load(Ordering::Acquire);
    // SAFETY (whole function): WGL calls with their signatures.
    unsafe {
        if list[0] != 0 && !real.is_null() {
            let create = core::mem::transmute::<*mut c_void, CreateContextAttribs>(real);
            return create(hdc, share, list.as_ptr());
        }
        let ctx = win::wglCreateContext(hdc);
        if !ctx.is_null() && win::wglShareLists(share, ctx) == 0 {
            log!("present: wglShareLists failed");
            win::wglDeleteContext(ctx);
            return core::ptr::null_mut();
        }
        ctx
    }
}

/// Redirects the game executable's import of opengl32's `wglGetProcAddress`. Once.
pub fn install() {
    if INSTALLED.swap(true, Ordering::SeqCst) {
        return;
    }
    // SAFETY: walking the game's own PE headers in memory, as the Windows loader laid them out.
    unsafe {
        let base = win::GetModuleHandleW(core::ptr::null()) as *mut u8;
        if base.is_null() {
            return;
        }
        let at = |off: usize| base.add(off);
        let u32_at = |off: usize| (at(off) as *const u32).read_unaligned() as usize;
        let nt = u32_at(0x3c);
        if u32_at(nt) != 0x4550 {
            return;
        }
        let optional = nt + 24;
        if (at(optional) as *const u16).read_unaligned() != 0x20b {
            return; // not a 64-bit image
        }
        let imports = u32_at(optional + 112 + 8);
        if imports == 0 {
            return;
        }
        let mut desc = imports;
        loop {
            let (lookup, name, iat) = (u32_at(desc), u32_at(desc + 12), u32_at(desc + 16));
            if name == 0 {
                break;
            }
            let dll = at(name);
            let is_gl = (0..13).all(|i| (*dll.add(i)).to_ascii_lowercase() == b"opengl32.dll\0"[i]);
            if is_gl {
                let table = if lookup != 0 { lookup } else { iat };
                let mut i = 0;
                loop {
                    let entry = (at(table + i * 8) as *const u64).read_unaligned();
                    if entry == 0 {
                        break;
                    }
                    if entry >> 63 == 0 && name_is(at(entry as usize + 2), b"wglGetProcAddress") {
                        let slot = at(iat + i * 8) as *mut *const c_void;
                        let mut old = 0u32;
                        if win::VirtualProtect(slot.cast(), 8, 0x04, &mut old) != 0 {
                            REAL_GET_PROC.store(*slot as *mut c_void, Ordering::Release);
                            *slot = get_proc_address as *const c_void;
                            win::VirtualProtect(slot.cast(), 8, old, &mut old);
                            log!(
                                "OpenGL context requests go through Halliday (so macOS can make them)"
                            );
                        }
                        return;
                    }
                    i += 1;
                }
            }
            desc += 20;
        }
    }
}
