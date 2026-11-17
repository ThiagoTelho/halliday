//! OpenGL eye textures: read back without stalling the game (ROADMAP W14.9).
//!
//! Each frame, `issue` asks the driver to copy the eye texture into a pixel buffer object
//! (`glGetTexImage` with a pack buffer bound); on the next frame `map` maps that buffer, by then
//! filled, the runtime's worker thread copies it into the bridge, and `unmap` releases it a frame
//! after that. Two buffers per eye alternate.
//! Rows come out bottom-up, RGBA8 (`READ_FORMAT`). Without pixel buffer objects (a very old context), `copy_now`
//! reads straight into the bridge, which waits for the GPU.
//!
//! Every call runs on the game's render thread with its context current, and leaves the game's
//! GL state (bound texture, pack buffer, pack alignment and row length) as it found it.

use crate::runtime::warn_once;
use crate::win::*;
use core::ffi::c_void;
use core::sync::atomic::{AtomicPtr, Ordering};

const GL_STREAM_READ: GLenum = 0x88E1;
const GL_READ_ONLY: GLenum = 0x88B8;
/// How rows are read back, and whether that is BGRA (the frame says so to Halliday). RGBA:
/// measured with an OpenGL game, reading as GL_BGRA / UNSIGNED_INT_8_8_8_8_REV cost more on
/// the game's thread (10.3 against 8.8 ms a frame), not less.
const READ_FORMAT: GLenum = 0x1908; // GL_RGBA
const READ_TYPE: GLenum = 0x1401; // GL_UNSIGNED_BYTE
pub const READ_BGRA: bool = false;

type GenBuffers = unsafe extern "system" fn(n: i32, buffers: *mut GLuint);
type BindBuffer = unsafe extern "system" fn(target: GLenum, buffer: GLuint);
type BufferData =
    unsafe extern "system" fn(target: GLenum, size: isize, data: *const c_void, usage: GLenum);
type MapBuffer = unsafe extern "system" fn(target: GLenum, access: GLenum) -> *mut c_void;
type UnmapBuffer = unsafe extern "system" fn(target: GLenum) -> u8;

struct Functions {
    generate: GenBuffers,
    bind: BindBuffer,
    data: BufferData,
    map: MapBuffer,
    unmap: UnmapBuffer,
}

static GEN: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static BIND: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static DATA: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static MAP: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());
static UNMAP: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());

/// The buffer functions, looked up once in the game's context; `None` if it has none.
fn functions() -> Option<Functions> {
    if GEN.load(Ordering::Relaxed).is_null() {
        for (slot, name) in [
            (&GEN, c"glGenBuffers"),
            (&BIND, c"glBindBuffer"),
            (&DATA, c"glBufferData"),
            (&MAP, c"glMapBuffer"),
            (&UNMAP, c"glUnmapBuffer"),
        ] {
            // SAFETY: wglGetProcAddress in the game's current context.
            slot.store(
                unsafe { wglGetProcAddress(name.as_ptr().cast()) } as *mut c_void,
                Ordering::Relaxed,
            );
        }
    }
    let all = [&GEN, &BIND, &DATA, &MAP, &UNMAP].map(|s| s.load(Ordering::Relaxed));
    if all.iter().any(|p| p.is_null()) {
        return None;
    }
    // SAFETY: GL entry points with these signatures.
    unsafe {
        Some(Functions {
            generate: core::mem::transmute::<*mut c_void, GenBuffers>(all[0]),
            bind: core::mem::transmute::<*mut c_void, BindBuffer>(all[1]),
            data: core::mem::transmute::<*mut c_void, BufferData>(all[2]),
            map: core::mem::transmute::<*mut c_void, MapBuffer>(all[3]),
            unmap: core::mem::transmute::<*mut c_void, UnmapBuffer>(all[4]),
        })
    }
}

/// The game's pack state, put back on drop.
struct Saved {
    texture: GLint,
    pack: GLint,
    align: GLint,
    row: GLint,
    bind: Option<BindBuffer>,
}

impl Saved {
    unsafe fn take(bind: Option<BindBuffer>) -> Saved {
        let mut s = Saved {
            texture: 0,
            pack: 0,
            align: 4,
            row: 0,
            bind,
        };
        // SAFETY: GL queries in the game's current context.
        unsafe {
            for _ in 0..8 {
                if glGetError() == 0 {
                    break;
                }
            }
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &mut s.texture);
            glGetIntegerv(GL_PACK_ALIGNMENT, &mut s.align);
            glGetIntegerv(GL_PACK_ROW_LENGTH, &mut s.row);
            glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &mut s.pack);
            let _ = glGetError(); // an old context has no pack buffers
        }
        s
    }
}

impl Drop for Saved {
    fn drop(&mut self) {
        // SAFETY: putting back what `take` read.
        unsafe {
            glPixelStorei(GL_PACK_ALIGNMENT, self.align);
            glPixelStorei(GL_PACK_ROW_LENGTH, self.row);
            if let Some(bind) = self.bind {
                bind(GL_PIXEL_PACK_BUFFER, self.pack as GLuint);
            }
            glBindTexture(GL_TEXTURE_2D, self.texture as GLuint);
        }
    }
}

/// Binds `name` and returns its size, if it is a 2D texture the bridge can hold (the left eye may
/// take both eyes' areas, when the right shares its texture).
unsafe fn bind_texture(name: GLuint, eye: usize) -> Option<(u32, u32)> {
    // SAFETY: GL calls in the game's current context.
    unsafe {
        glBindTexture(GL_TEXTURE_2D, name);
        if glGetError() != 0 {
            warn_once(
                0,
                format_args!(
                    "[halliday-vrclient] texture {name} isn't a 2D texture (multisampled?): not shown"
                ),
            );
            return None;
        }
        let (mut w, mut h) = (0, 0);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &mut w);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &mut h);
        let fits = if eye == 0 {
            halliday_bridge::fits_shared(w as u32, h as u32)
        } else {
            halliday_bridge::fits(w as u32, h as u32)
        };
        if w <= 0 || h <= 0 || !fits {
            warn_once(
                1,
                format_args!(
                    "[halliday-vrclient] eye texture {w}x{h} is larger than the bridge holds: not shown"
                ),
            );
            return None;
        }
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        Some((w as u32, h as u32))
    }
}

/// Reads `name` straight into `dst` (waits for the GPU).
///
/// # Safety
/// The game's context is current; `dst` holds an eye's image area.
pub unsafe fn copy_now(name: GLuint, eye: usize, dst: *mut u8) -> Option<(u32, u32)> {
    let f = functions();
    // SAFETY: GL calls in the game's current context.
    unsafe {
        let _saved = Saved::take(f.as_ref().map(|f| f.bind));
        let size = bind_texture(name, eye)?;
        if let Some(f) = &f {
            (f.bind)(GL_PIXEL_PACK_BUFFER, 0);
        }
        glGetTexImage(GL_TEXTURE_2D, 0, READ_FORMAT, READ_TYPE, dst.cast());
        let e = glGetError();
        if e != 0 {
            warn_once(
                2,
                format_args!("[halliday-vrclient] glGetTexImage failed ({e:#x})"),
            );
            return None;
        }
        Some(size)
    }
}

/// The pixel buffers: [frame parity][eye], with the size each holds.
struct Buffers {
    name: [[GLuint; 2]; 2],
    bytes: [[usize; 2]; 2],
}

static BUFFERS: crate::runtime::Locked<Buffers> = crate::runtime::Locked::new(Buffers {
    name: [[0; 2]; 2],
    bytes: [[0; 2]; 2],
});

/// Starts reading `name` into the buffer for (`parity`, `eye`). Its size, or `None` if the
/// texture can't be read (or the context has no pixel buffers: then use `copy_now`).
///
/// # Safety
/// The game's context is current.
pub unsafe fn issue(name: GLuint, parity: usize, eye: usize) -> Option<(u32, u32)> {
    let f = functions()?;
    // SAFETY: GL calls in the game's current context.
    unsafe {
        let _saved = Saved::take(Some(f.bind));
        let (w, h) = bind_texture(name, eye)?;
        let bytes = w as usize * h as usize * 4;
        let buffer = BUFFERS.with(|b| {
            if b.name[parity][eye] == 0 {
                (f.generate)(1, &mut b.name[parity][eye]);
            }
            (f.bind)(GL_PIXEL_PACK_BUFFER, b.name[parity][eye]);
            if b.bytes[parity][eye] != bytes {
                (f.data)(
                    GL_PIXEL_PACK_BUFFER,
                    bytes as isize,
                    core::ptr::null(),
                    GL_STREAM_READ,
                );
                b.bytes[parity][eye] = bytes;
            }
            b.name[parity][eye]
        });
        if buffer == 0 {
            return None;
        }
        // With a pack buffer bound, the pointer is an offset into it: the copy runs on the GPU.
        glGetTexImage(
            GL_TEXTURE_2D,
            0,
            READ_FORMAT,
            READ_TYPE,
            core::ptr::null_mut(),
        );
        let e = glGetError();
        if e != 0 {
            warn_once(
                2,
                format_args!(
                    "[halliday-vrclient] glGetTexImage into a pixel buffer failed ({e:#x})"
                ),
            );
            return None;
        }
        Some((w, h))
    }
}

/// Maps the buffer for (`parity`, `eye`), filled by `issue` a frame ago: a pointer to its rows,
/// valid until `unmap`. The buffer's size must be `bytes` or more.
///
/// # Safety
/// The game's context is current.
pub unsafe fn map(parity: usize, eye: usize, bytes: usize) -> Option<*const u8> {
    let f = functions()?;
    let (buffer, held) = BUFFERS.with(|b| (b.name[parity][eye], b.bytes[parity][eye]));
    if buffer == 0 || held < bytes {
        return None;
    }
    // SAFETY: GL calls in the game's current context.
    unsafe {
        let mut pack = 0;
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &mut pack);
        (f.bind)(GL_PIXEL_PACK_BUFFER, buffer);
        let t0 = crate::runtime::now_ticks();
        let p = (f.map)(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY);
        crate::runtime::MAP_TICKS.fetch_add(
            crate::runtime::now_ticks().wrapping_sub(t0),
            Ordering::Relaxed,
        );
        if p.is_null() {
            warn_once(
                7,
                format_args!(
                    "[halliday-vrclient] mapping a pixel buffer failed ({:#x})",
                    glGetError()
                ),
            );
            (f.unmap)(GL_PIXEL_PACK_BUFFER);
        }
        (f.bind)(GL_PIXEL_PACK_BUFFER, pack as GLuint);
        (!p.is_null()).then_some(p as *const u8)
    }
}

/// Unmaps the buffer for (`parity`, `eye`) mapped by `map` (once its rows are copied).
///
/// # Safety
/// The game's context is current.
pub unsafe fn unmap(parity: usize, eye: usize) {
    let Some(f) = functions() else { return };
    let buffer = BUFFERS.with(|b| b.name[parity][eye]);
    if buffer == 0 {
        return;
    }
    // SAFETY: GL calls in the game's current context.
    unsafe {
        let mut pack = 0;
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &mut pack);
        (f.bind)(GL_PIXEL_PACK_BUFFER, buffer);
        (f.unmap)(GL_PIXEL_PACK_BUFFER);
        (f.bind)(GL_PIXEL_PACK_BUFFER, pack as GLuint);
    }
}

/// Reads OpenGL texture `name` straight into `dst` (RGBA rows, bottom-up as OpenGL keeps them;
/// waits for the GPU), for an overlay: its size, or `None` if it isn't a 2D texture, is larger than
/// `max_side` or no context of the game's is current on this thread.
///
/// # Safety
/// `dst` holds `max_side * max_side * 4` bytes.
pub unsafe fn read_into(name: GLuint, dst: *mut u8, max_side: u32) -> Option<(u32, u32)> {
    // SAFETY: GL calls, only with a context current.
    unsafe {
        if crate::win::wglGetCurrentContext().is_null() {
            return None;
        }
        let f = functions();
        let _saved = Saved::take(f.as_ref().map(|f| f.bind));
        glBindTexture(GL_TEXTURE_2D, name);
        if glGetError() != 0 {
            return None;
        }
        let (mut w, mut h) = (0, 0);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &mut w);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &mut h);
        if w <= 0 || h <= 0 || w as u32 > max_side || h as u32 > max_side {
            return None;
        }
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        if let Some(f) = &f {
            (f.bind)(GL_PIXEL_PACK_BUFFER, 0);
        }
        glGetTexImage(GL_TEXTURE_2D, 0, READ_FORMAT, READ_TYPE, dst.cast());
        (glGetError() == 0).then_some((w as u32, h as u32))
    }
}
