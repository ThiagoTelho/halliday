//! A plain-text log next to the runtime (`vrclient.log`), and Wine's debug channel.

use crate::win;
use core::fmt::Write;
use core::sync::atomic::{AtomicPtr, Ordering};

static FILE: AtomicPtr<core::ffi::c_void> = AtomicPtr::new(core::ptr::null_mut());
const FILE_APPEND_DATA: u32 = 0x4;
const OPEN_ALWAYS: u32 = 4;

/// Opens the log at `path` (NUL-terminated UTF-16) for appending: a game may load the runtime more
/// than once (Unity does), and Halliday clears the log when it starts.
pub fn open(path: &[u16]) {
    if !FILE.load(Ordering::SeqCst).is_null() {
        return;
    }
    // SAFETY: `path` is NUL-terminated.
    let h = unsafe {
        win::CreateFileW(
            path.as_ptr(),
            FILE_APPEND_DATA,
            win::FILE_SHARE_READ | win::FILE_SHARE_WRITE,
            core::ptr::null_mut(),
            OPEN_ALWAYS,
            win::FILE_ATTRIBUTE_NORMAL,
            core::ptr::null_mut(),
        )
    };
    if h != win::INVALID_HANDLE_VALUE {
        FILE.store(h, Ordering::SeqCst);
    }
}

/// A line of text built on the stack.
pub struct Line {
    buf: [u8; 512],
    len: usize,
}

impl Line {
    pub const fn new() -> Self {
        Line {
            buf: [0; 512],
            len: 0,
        }
    }
}

impl Write for Line {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        let room = self.buf.len() - 2 - self.len;
        let n = s.len().min(room);
        self.buf[self.len..self.len + n].copy_from_slice(&s.as_bytes()[..n]);
        self.len += n;
        Ok(())
    }
}

pub fn write(args: core::fmt::Arguments) {
    let mut line = Line::new();
    let _ = line.write_str("[halliday-vrclient] ");
    let _ = line.write_fmt(args);
    line.buf[line.len] = b'\n';
    line.len += 1;
    line.buf[line.len] = 0;
    // SAFETY: NUL-terminated buffer.
    unsafe { win::OutputDebugStringA(line.buf.as_ptr()) };
    let h = FILE.load(Ordering::SeqCst);
    if !h.is_null() {
        let mut written = 0;
        // SAFETY: `h` is an open file; the buffer holds `len` bytes.
        unsafe {
            win::WriteFile(
                h,
                line.buf.as_ptr().cast(),
                line.len as u32,
                &mut written,
                core::ptr::null_mut(),
            )
        };
    }
}

macro_rules! log {
    ($($t:tt)*) => { $crate::log::write(format_args!($($t)*)) };
}
pub(crate) use log;

/// A C string for logging (at most 200 bytes, lossy).
pub struct CStr(pub *const core::ffi::c_char);

impl core::fmt::Display for CStr {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        if self.0.is_null() {
            return f.write_str("(null)");
        }
        for i in 0..200 {
            // SAFETY: a NUL-terminated string from the caller; stops at the NUL.
            let c = unsafe { *self.0.add(i) } as u8;
            if c == 0 {
                break;
            }
            f.write_char(if c.is_ascii_graphic() || c == b' ' {
                c as char
            } else {
                '?'
            })?;
        }
        Ok(())
    }
}

/// Logs the first call of a function (up to 256 distinct ones): what the game uses, in order.
pub fn first_call(name: &'static str) {
    static SEEN: crate::runtime::Locked<([usize; 256], usize)> =
        crate::runtime::Locked::new(([0; 256], 0));
    let key = name.as_ptr() as usize;
    let new = SEEN.with(|(seen, n)| {
        if seen[..*n].contains(&key) || *n == seen.len() {
            return false;
        }
        seen[*n] = key;
        *n += 1;
        true
    });
    if new {
        write(format_args!("call {name}"));
    }
}

macro_rules! seen {
    ($name:literal) => {
        $crate::log::first_call($name)
    };
}
pub(crate) use seen;
