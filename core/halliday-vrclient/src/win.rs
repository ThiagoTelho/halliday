//! The few Windows and OpenGL functions the runtime uses, imported without import libraries.

#![allow(non_snake_case, clippy::upper_case_acronyms)]

use core::ffi::c_void;

pub type HANDLE = *mut c_void;
pub type BOOL = i32;
pub const INVALID_HANDLE_VALUE: HANDLE = -1isize as HANDLE;

pub const GENERIC_READ: u32 = 0x8000_0000;
pub const GENERIC_WRITE: u32 = 0x4000_0000;
pub const FILE_SHARE_READ: u32 = 1;
pub const FILE_SHARE_WRITE: u32 = 2;
pub const OPEN_EXISTING: u32 = 3;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
pub const PAGE_READWRITE: u32 = 4;
pub const FILE_MAP_ALL_ACCESS: u32 = 0xF001F;
pub const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 4;
pub const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 2;
pub const GET_MODULE_HANDLE_EX_FLAG_PIN: u32 = 1;

#[link(name = "kernel32", kind = "raw-dylib")]
unsafe extern "system" {
    pub fn CreateFileW(
        name: *const u16,
        access: u32,
        share: u32,
        security: *mut c_void,
        disposition: u32,
        flags: u32,
        template: HANDLE,
    ) -> HANDLE;
    pub fn CreateFileMappingW(
        file: HANDLE,
        security: *mut c_void,
        protect: u32,
        size_high: u32,
        size_low: u32,
        name: *const u16,
    ) -> HANDLE;
    pub fn MapViewOfFile(
        mapping: HANDLE,
        access: u32,
        offset_high: u32,
        offset_low: u32,
        bytes: usize,
    ) -> *mut c_void;
    pub fn UnmapViewOfFile(base: *const c_void) -> BOOL;
    pub fn CloseHandle(handle: HANDLE) -> BOOL;
    pub fn CreateFileA(
        name: *const u8,
        access: u32,
        share: u32,
        security: *mut c_void,
        disposition: u32,
        flags: u32,
        template: HANDLE,
    ) -> HANDLE;
    pub fn ReadFile(
        file: HANDLE,
        buffer: *mut c_void,
        bytes: u32,
        read: *mut u32,
        overlapped: *mut c_void,
    ) -> BOOL;
    pub fn WriteFile(
        file: HANDLE,
        buffer: *const c_void,
        bytes: u32,
        written: *mut u32,
        overlapped: *mut c_void,
    ) -> BOOL;
    pub fn Sleep(ms: u32);
    pub fn GetEnvironmentVariableA(name: *const u8, buffer: *mut u8, size: u32) -> u32;
    pub fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut HANDLE) -> BOOL;
    pub fn GetModuleFileNameW(module: HANDLE, name: *mut u16, size: u32) -> u32;
    pub fn GetCurrentProcessId() -> u32;
    pub fn GetCurrentThreadId() -> u32;
    pub fn GetProcessHeap() -> HANDLE;
    pub fn HeapFree(heap: HANDLE, flags: u32, memory: *mut c_void) -> BOOL;
    pub fn GetProcAddress(module: HANDLE, name: *const u8) -> *const c_void;
    pub fn QueryPerformanceCounter(count: *mut i64) -> BOOL;
    pub fn QueryPerformanceFrequency(frequency: *mut i64) -> BOOL;
    pub fn OutputDebugStringA(text: *const u8);
    pub fn GetModuleHandleW(name: *const u16) -> HANDLE;
    pub fn CreateThread(
        security: *mut c_void,
        stack: usize,
        start: unsafe extern "system" fn(*mut c_void) -> u32,
        parameter: *mut c_void,
        flags: u32,
        id: *mut u32,
    ) -> HANDLE;
    pub fn CreateEventW(
        security: *mut c_void,
        manual_reset: BOOL,
        initial: BOOL,
        name: *const u16,
    ) -> HANDLE;
    pub fn SetEvent(event: HANDLE) -> BOOL;
    pub fn WaitForSingleObject(handle: HANDLE, ms: u32) -> u32;
    pub fn VirtualProtect(address: *mut c_void, size: usize, protect: u32, old: *mut u32) -> BOOL;
}

pub type GLenum = u32;
pub type GLint = i32;
pub type GLuint = u32;

pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE_BINDING_2D: GLenum = 0x8069;
pub const GL_TEXTURE_WIDTH: GLenum = 0x1000;
pub const GL_TEXTURE_HEIGHT: GLenum = 0x1001;
pub const GL_PACK_ALIGNMENT: GLenum = 0x0D05;
pub const GL_PACK_ROW_LENGTH: GLenum = 0x0D02;
pub const GL_PIXEL_PACK_BUFFER: GLenum = 0x88EB;
pub const GL_PIXEL_PACK_BUFFER_BINDING: GLenum = 0x88ED;

#[link(name = "opengl32", kind = "raw-dylib")]
unsafe extern "system" {
    pub fn glGetIntegerv(name: GLenum, data: *mut GLint);
    pub fn glBindTexture(target: GLenum, texture: GLuint);
    pub fn glGetTexLevelParameteriv(target: GLenum, level: GLint, name: GLenum, value: *mut GLint);
    pub fn glGetTexImage(
        target: GLenum,
        level: GLint,
        format: GLenum,
        kind: GLenum,
        pixels: *mut c_void,
    );
    pub fn glPixelStorei(name: GLenum, value: GLint);
    pub fn glGetError() -> GLenum;
    pub fn wglGetProcAddress(name: *const u8) -> *const c_void;
    pub fn wglGetCurrentContext() -> HANDLE;
    pub fn wglGetCurrentDC() -> HANDLE;
    pub fn wglCreateContext(dc: HANDLE) -> HANDLE;
    pub fn wglDeleteContext(ctx: HANDLE) -> BOOL;
    pub fn wglMakeCurrent(dc: HANDLE, ctx: HANDLE) -> BOOL;
    pub fn wglShareLists(a: HANDLE, b: HANDLE) -> BOOL;
    pub fn glClearColor(r: f32, g: f32, b: f32, a: f32);
    pub fn glClear(mask: GLenum);
    pub fn glEnable(cap: GLenum);
    pub fn glDisable(cap: GLenum);
    pub fn glScissor(x: GLint, y: GLint, w: GLint, h: GLint);
    pub fn glViewport(x: GLint, y: GLint, w: GLint, h: GLint);
    pub fn glFlush();
}

#[link(name = "gdi32", kind = "raw-dylib")]
unsafe extern "system" {
    pub fn GetPixelFormat(dc: HANDLE) -> i32;
    pub fn SetPixelFormat(dc: HANDLE, format: i32, pfd: *const c_void) -> BOOL;
    pub fn DescribePixelFormat(dc: HANDLE, format: i32, size: u32, pfd: *mut c_void) -> i32;
    pub fn SwapBuffers(dc: HANDLE) -> BOOL;
}
