//! What a C runtime would provide: memory functions the compiler calls, the stack probe and
//! `_fltused`. Shared by the DLL and `vrtest` (`#[path]`), which link no C runtime.

#![allow(clippy::missing_safety_doc)]

use core::ffi::c_void;

// `memcpy` is `rep movsb`; the others go byte by byte through volatile accesses, so the compiler
// can't turn their loops back into calls to these very functions.

#[unsafe(no_mangle)]
pub static _fltused: i32 = 0;

/// A fast forward copy (`rep movsb`): the images' rows, and `memcpy`.
///
/// # Safety
/// `dst` and `src` hold `n` bytes; a forward copy is correct for them.
#[inline]
pub unsafe fn fast_copy(dst: *mut u8, src: *const u8, n: usize) {
    // SAFETY: the caller's buffers; `rep movsb` copies RCX bytes from RSI to RDI, forwards.
    unsafe {
        core::arch::asm!(
            "rep movsb",
            inout("rcx") n => _,
            inout("rdi") dst => _,
            inout("rsi") src => _,
            options(nostack, preserves_flags)
        )
    };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void {
    // SAFETY: the caller's buffers, not overlapping.
    unsafe { fast_copy(dst.cast(), src.cast(), n) };
    dst
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memmove(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void {
    if (dst as usize) < (src as usize) {
        // SAFETY: a forward copy is safe when dst is below src.
        return unsafe { memcpy(dst, src, n) };
    }
    let (d, s) = (dst.cast::<u8>(), src.cast::<u8>());
    let mut i = n;
    while i > 0 {
        i -= 1;
        // SAFETY: the caller's buffers hold `n` bytes.
        unsafe { d.add(i).write_volatile(s.add(i).read_volatile()) };
    }
    dst
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memset(dst: *mut c_void, c: i32, n: usize) -> *mut c_void {
    let d = dst.cast::<u8>();
    let mut i = 0;
    while i < n {
        // SAFETY: the caller's buffer holds `n` bytes.
        unsafe { d.add(i).write_volatile(c as u8) };
        i += 1;
    }
    dst
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memcmp(a: *const c_void, b: *const c_void, n: usize) -> i32 {
    let (a, b) = (a.cast::<u8>(), b.cast::<u8>());
    let mut i = 0;
    while i < n {
        // SAFETY: the caller's buffers hold `n` bytes.
        let (x, y) = unsafe { (a.add(i).read_volatile(), b.add(i).read_volatile()) };
        if x != y {
            return x as i32 - y as i32;
        }
        i += 1;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strlen(s: *const core::ffi::c_char) -> usize {
    let mut n = 0;
    // SAFETY: a NUL-terminated string from the caller.
    while unsafe { s.add(n).read_volatile() } != 0 {
        n += 1;
    }
    n
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bcmp(a: *const c_void, b: *const c_void, n: usize) -> i32 {
    // SAFETY: same contract.
    unsafe { memcmp(a, b, n) }
}

/// The stack probe the compiler calls before a frame larger than a page: touches each page from
/// the caller's stack pointer down by RAX bytes, so Windows grows the stack in order. Keeps every
/// register. As compiler-rt's `chkstk.S` (Apache-2.0 with LLVM exception).
#[unsafe(naked)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn __chkstk() {
    core::arch::naked_asm!(
        "push rcx",
        "push rax",
        "cmp rax, 0x1000",
        "lea rcx, [rsp + 24]",
        "jb 3f",
        "2:",
        "sub rcx, 0x1000",
        "test [rcx], rcx",
        "sub rax, 0x1000",
        "cmp rax, 0x1000",
        "ja 2b",
        "3:",
        "sub rcx, rax",
        "test [rcx], rcx",
        "pop rax",
        "pop rcx",
        "ret",
    )
}
