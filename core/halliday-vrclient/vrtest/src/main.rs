//! `vrtest.exe`: a stand-in Direct3D 11 VR game for testing Halliday's OpenVR runtime under Wine
//! (GameHub, CrossOver) without a real game. It loads `vrclient_x64.dll` as `openvr_api.dll`
//! would (path in `HALLIDAY_VRCLIENT`), initializes it, and submits frames of one BGRA texture
//! holding both eyes side by side: the left half reddish with a white square at its top left, the
//! right half bluish with a magenta square at its top right, both brighter at the top. In Halliday
//! (or `halliday-probe game-peek`) the squares tell the eyes and the right way up apart.
//!
//! It also does what SteamVR games ask of the compositor, on a timeline (seconds from its first
//! frame), printing each step:
//! - 0: two overlays, a green panel in the room (`SetOverlayRaw`) and a yellow strip below the
//!   view that follows the head (`SetOverlayTexture`, Direct3D 11); a skybox of six colored faces.
//!   The panel takes the mouse (`VROverlayInputMethod_Mouse`, scroll events on): its events are
//!   printed, and a click leaves a white mark where it landed.
//! - 10–16: no frames, as while loading: Halliday shows the skybox and the overlays.
//! - 18: fades to black over 1 s; 22: back over 0.5 s.
//! - 24–30: the compositor's grid (`FadeGrid`): Halliday's place instead of the frames.
//! - Then frames until Halliday asks it to quit (`VREvent_Quit`), which it acknowledges, or 90 s.
//!
//! Events from Halliday (its interface over the game, quitting) are printed as they come.
//!
//! Run (GameHub's Wine and GPTK, Halliday running):
//! `HALLIDAY_VRCLIENT='Z:\…\Halliday\OpenVR\bin\vrclient_x64.dll' wine Z:\…\vrtest.exe`

#![no_std]
#![no_main]

use core::ffi::c_void;

#[path = "../../src/crt.rs"]
mod crt;

type Obj = *mut c_void;

#[link(name = "kernel32", kind = "raw-dylib")]
unsafe extern "system" {
    fn LoadLibraryW(path: *const u16) -> Obj;
    fn GetProcAddress(module: Obj, name: *const u8) -> *const c_void;
    fn GetEnvironmentVariableW(name: *const u16, buffer: *mut u16, size: u32) -> u32;
    fn GetStdHandle(which: u32) -> Obj;
    fn WriteFile(
        file: Obj,
        buffer: *const u8,
        bytes: u32,
        written: *mut u32,
        overlapped: Obj,
    ) -> i32;
    fn ExitProcess(code: u32) -> !;
    fn QueryPerformanceCounter(count: *mut i64) -> i32;
    fn Sleep(ms: u32);
    fn QueryPerformanceFrequency(frequency: *mut i64) -> i32;
}

#[link(name = "d3d11", kind = "raw-dylib")]
unsafe extern "system" {
    fn D3D11CreateDevice(
        adapter: Obj,
        driver: u32,
        software: Obj,
        flags: u32,
        levels: *const u32,
        level_count: u32,
        sdk: u32,
        device: *mut Obj,
        level: *mut u32,
        context: *mut Obj,
    ) -> i32;
}

fn say(text: &str) {
    let mut written = 0;
    // SAFETY: plain calls; STD_OUTPUT_HANDLE.
    unsafe {
        let out = GetStdHandle(-11i32 as u32);
        WriteFile(
            out,
            text.as_ptr(),
            text.len() as u32,
            &mut written,
            core::ptr::null_mut(),
        );
        WriteFile(out, b"\n".as_ptr(), 1, &mut written, core::ptr::null_mut());
    }
}

fn fail(text: &str) -> ! {
    say(text);
    // SAFETY: plain call.
    unsafe { ExitProcess(1) }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    fail("vrtest: panic")
}

fn say_number(text: &str, n: u64) {
    let mut buf = [0u8; 96];
    let t = text.as_bytes();
    let mut len = t.len().min(64);
    buf[..len].copy_from_slice(&t[..len]);
    let mut digits = [0u8; 20];
    let (mut k, mut v) = (0, n);
    loop {
        digits[k] = b'0' + (v % 10) as u8;
        k += 1;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    while k > 0 {
        k -= 1;
        buf[len] = digits[k];
        len += 1;
    }
    // SAFETY: ASCII.
    say(unsafe { core::str::from_utf8_unchecked(&buf[..len]) });
}

fn seconds_since(start: i64) -> f64 {
    let (mut now, mut f) = (0i64, 0i64);
    // SAFETY: valid out pointers.
    unsafe {
        QueryPerformanceCounter(&mut now);
        QueryPerformanceFrequency(&mut f);
    }
    (now - start) as f64 / f.max(1) as f64
}

unsafe fn method(obj: Obj, index: usize) -> *const c_void {
    // SAFETY: a COM / C++ object starts with a pointer to its table of methods.
    unsafe { *(*(obj as *const *const *const c_void)).add(index) }
}

const WIDTH: u32 = 2048;
const HEIGHT: u32 = 1024;
static mut PIXELS: [u8; (WIDTH * HEIGHT * 4) as usize] = [0; (WIDTH * HEIGHT * 4) as usize];
static mut MOVES: u64 = 0;
static mut PANEL: [u8; 256 * 128 * 4] = [0; 256 * 128 * 4];
static mut SOLID: [u8; 128 * 64 * 4] = [0; 128 * 64 * 4];

/// A texture of one BGRA color (at most 128 × 64).
unsafe fn solid_texture(device: Obj, w: u32, h: u32, bgra: [u8; 4]) -> Obj {
    // SAFETY: our static buffer; COM calls with ID3D11Device::CreateTexture2D's signature.
    unsafe {
        let px = &mut *core::ptr::addr_of_mut!(SOLID);
        for p in px.chunks_mut(4).take((w * h) as usize) {
            p.copy_from_slice(&bgra);
        }
        let desc = TextureDesc {
            width: w,
            height: h,
            mip_levels: 1,
            array_size: 1,
            format: 0x57,
            sample_count: 1,
            sample_quality: 0,
            usage: 0,
            bind_flags: 0x8 | 0x20,
            cpu_access: 0,
            misc_flags: 0,
        };
        let init = InitialData {
            data: px.as_ptr(),
            pitch: w * 4,
            slice_pitch: 0,
        };
        let mut t: Obj = core::ptr::null_mut();
        let create = core::mem::transmute::<
            *const c_void,
            unsafe extern "system" fn(Obj, *const TextureDesc, *const InitialData, *mut Obj) -> i32,
        >(method(device, 5));
        if create(device, &desc, &init, &mut t) < 0 || t.is_null() {
            fail("vrtest: CreateTexture2D (solid) failed");
        }
        t
    }
}

#[repr(C)]
struct TextureDesc {
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
struct InitialData {
    data: *const u8,
    pitch: u32,
    slice_pitch: u32,
}

#[repr(C)]
struct VrTexture {
    handle: Obj,
    kind: i32,
    color_space: i32,
}

#[unsafe(no_mangle)]
pub extern "C" fn start() -> ! {
    // SAFETY (whole program): Win32 and COM calls with their documented signatures.
    unsafe {
        // The test pattern, B G R A, top row first.
        let pixels = &mut *core::ptr::addr_of_mut!(PIXELS);
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                let i = ((y * WIDTH + x) * 4) as usize;
                let right = x >= WIDTH / 2;
                let ex = x % (WIDTH / 2);
                let bright = 255 - (y * 200 / HEIGHT) as u8;
                let (mut r, mut g, mut b) = if right {
                    (40, 60, bright)
                } else {
                    (bright, 50, 40)
                };
                let square = y < 120
                    && if right {
                        ex >= WIDTH / 2 - 120
                    } else {
                        ex < 120
                    };
                if square {
                    (r, g, b) = if right {
                        (255, 0, 255)
                    } else {
                        (255, 255, 255)
                    };
                }
                pixels[i..i + 4].copy_from_slice(&[b, g, r, 255]);
            }
        }

        let (mut device, mut context, mut level): (Obj, Obj, u32) =
            (core::ptr::null_mut(), core::ptr::null_mut(), 0);
        let hr = D3D11CreateDevice(
            core::ptr::null_mut(),
            1, // hardware
            core::ptr::null_mut(),
            0,
            core::ptr::null(),
            0,
            7, // D3D11_SDK_VERSION
            &mut device,
            &mut level,
            &mut context,
        );
        if hr < 0 || device.is_null() {
            fail("vrtest: D3D11CreateDevice failed");
        }
        say("vrtest: Direct3D 11 device made");
        let desc = TextureDesc {
            width: WIDTH,
            height: HEIGHT,
            mip_levels: 1,
            array_size: 1,
            format: 0x57, // B8G8R8A8_UNORM
            sample_count: 1,
            sample_quality: 0,
            usage: 0,
            bind_flags: 0x8 | 0x20, // shader resource, render target
            cpu_access: 0,
            misc_flags: 0,
        };
        let init = InitialData {
            data: pixels.as_ptr(),
            pitch: WIDTH * 4,
            slice_pitch: 0,
        };
        let mut texture: Obj = core::ptr::null_mut();
        let create = core::mem::transmute::<
            *const c_void,
            unsafe extern "system" fn(Obj, *const TextureDesc, *const InitialData, *mut Obj) -> i32,
        >(method(device, 5));
        if create(device, &desc, &init, &mut texture) < 0 || texture.is_null() {
            fail("vrtest: CreateTexture2D failed");
        }

        // The runtime, as openvr_api.dll loads it.
        let mut path = [0u16; 1024];
        let name: [u16; 18] = [
            b'H' as u16,
            b'A' as u16,
            b'L' as u16,
            b'L' as u16,
            b'I' as u16,
            b'D' as u16,
            b'A' as u16,
            b'Y' as u16,
            b'_' as u16,
            b'V' as u16,
            b'R' as u16,
            b'C' as u16,
            b'L' as u16,
            b'I' as u16,
            b'E' as u16,
            b'N' as u16,
            b'T' as u16,
            0,
        ];
        if GetEnvironmentVariableW(name.as_ptr(), path.as_mut_ptr(), 1000) == 0 {
            fail("vrtest: set HALLIDAY_VRCLIENT to the path of vrclient_x64.dll");
        }
        let module = LoadLibraryW(path.as_ptr());
        if module.is_null() {
            fail("vrtest: couldn't load vrclient_x64.dll");
        }
        let factory = GetProcAddress(module, c"VRClientCoreFactory".as_ptr().cast());
        if factory.is_null() {
            fail("vrtest: no VRClientCoreFactory");
        }
        let factory = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(*const u8, *mut i32) -> Obj,
        >(factory);
        let mut code = 0;
        let core = factory(c"IVRClientCore_003".as_ptr().cast(), &mut code);
        if core.is_null() {
            fail("vrtest: no IVRClientCore_003");
        }
        let init = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, i32, *const u8) -> i32,
        >(method(core, 0));
        if init(core, 1, core::ptr::null()) != 0 {
            fail("vrtest: VR_Init failed (is Halliday running?)");
        }
        let get = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, *const u8, *mut i32) -> Obj,
        >(method(core, 3));
        let compositor = get(core, c"IVRCompositor_021".as_ptr().cast(), &mut code);
        if compositor.is_null() {
            fail("vrtest: no IVRCompositor_021");
        }
        let system = get(core, c"IVRSystem_017".as_ptr().cast(), &mut code);
        let overlay = get(core, c"IVROverlay_016".as_ptr().cast(), &mut code);
        if system.is_null() || overlay.is_null() {
            fail("vrtest: no IVRSystem_017 or IVROverlay_016");
        }
        say("vrtest: connected");
        let wait = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, *mut u8, u32, *mut u8, u32) -> i32,
        >(method(compositor, 2));
        let submit = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, i32, *const VrTexture, *const [f32; 4], i32) -> i32,
        >(method(compositor, 5));
        let fade_to_color = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, f32, f32, f32, f32, f32, bool),
        >(method(compositor, 12));
        let fade_grid = core::mem::transmute::<*const c_void, unsafe extern "C" fn(Obj, f32, bool)>(
            method(compositor, 14),
        );
        let set_skybox = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, *const VrTexture, u32) -> i32,
        >(method(compositor, 16));
        let frame_timing = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, *mut u8, u32) -> bool,
        >(method(compositor, 8));
        let poll = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, *mut u8, u32) -> bool,
        >(method(system, 29));
        let acknowledge_quit =
            core::mem::transmute::<*const c_void, unsafe extern "C" fn(Obj)>(method(system, 43));
        let create_overlay = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, *const u8, *const u8, *mut u64) -> i32,
        >(method(overlay, 1));
        let set_texture = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, *const VrTexture) -> i32,
        >(method(overlay, 57));
        let set_raw = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, *const u8, u32, u32, u32) -> i32,
        >(method(overlay, 59));
        let set_width = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, f32) -> i32,
        >(method(overlay, 22));
        let set_absolute = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, u32, *const [[f32; 4]; 3]) -> i32,
        >(method(overlay, 33));
        let set_relative = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, u32, *const [[f32; 4]; 3]) -> i32,
        >(method(overlay, 35));
        let show = core::mem::transmute::<*const c_void, unsafe extern "C" fn(Obj, u64) -> i32>(
            method(overlay, 41),
        );
        let set_flag = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, u32, bool) -> i32,
        >(method(overlay, 12));
        let poll_overlay = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, *mut u8, u32) -> bool,
        >(method(overlay, 45));
        let set_input_method = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, u32) -> i32,
        >(method(overlay, 47));
        let set_mouse_scale = core::mem::transmute::<
            *const c_void,
            unsafe extern "C" fn(Obj, u64, *const [f32; 2]) -> i32,
        >(method(overlay, 49));

        // The panel: green, a lighter border, a little see-through.
        let (pw, ph) = (256u32, 128u32);
        let panel = &mut *core::ptr::addr_of_mut!(PANEL);
        for y in 0..ph {
            for x in 0..pw {
                let border = x < 8 || y < 8 || x >= pw - 8 || y >= ph - 8;
                let i = ((y * pw + x) * 4) as usize;
                panel[i..i + 4].copy_from_slice(if border {
                    &[200, 255, 200, 255]
                } else {
                    &[30, 160, 60, 200]
                });
            }
        }
        let mut panel_handle = 0u64;
        let mut hud_handle = 0u64;
        let r1 = create_overlay(
            overlay,
            c"vrtest.panel".as_ptr().cast(),
            c"vrtest panel".as_ptr().cast(),
            &mut panel_handle,
        );
        let r2 = create_overlay(
            overlay,
            c"vrtest.hud".as_ptr().cast(),
            c"vrtest hud".as_ptr().cast(),
            &mut hud_handle,
        );
        say_number(
            "vrtest: overlays created (errors 0 = none): ",
            (r1 * 100 + r2) as u64,
        );
        set_raw(overlay, panel_handle, panel.as_ptr(), pw, ph, 4);
        set_width(overlay, panel_handle, 0.8);
        // In the room: 1.5 m ahead, 1.4 m up (standing space), a little turned toward the left.
        let place = [
            [0.966, 0.0, 0.259, 0.3],
            [0.0, 1.0, 0.0, 1.4],
            [-0.259, 0.0, 0.966, -1.5],
        ];
        set_absolute(overlay, panel_handle, 1, &place);
        show(overlay, panel_handle);
        // It takes the mouse, in its pixels, with scroll events.
        say_number(
            "vrtest: the panel takes the mouse (0 = done): ",
            (set_input_method(overlay, panel_handle, 1)
                + set_mouse_scale(overlay, panel_handle, &[pw as f32, ph as f32])
                + set_flag(overlay, panel_handle, 6, true)) as u64,
        );
        // The strip: a Direct3D 11 texture, yellow, following the head, below the view's center.
        let hud_texture = solid_texture(device, 128, 32, [0, 220, 255, 255]);
        set_texture(
            overlay,
            hud_handle,
            &VrTexture {
                handle: hud_texture,
                kind: 0,
                color_space: 0,
            },
        );
        set_width(overlay, hud_handle, 0.4);
        let below = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, -0.25],
            [0.0, 0.0, 1.0, -1.0],
        ];
        set_relative(overlay, hud_handle, 0, &below);
        show(overlay, hud_handle);
        // The skybox: front red, back green, left blue, right yellow, top magenta, bottom cyan (BGRA).
        let colors: [[u8; 4]; 6] = [
            [40, 40, 220, 255],
            [40, 200, 40, 255],
            [220, 60, 40, 255],
            [40, 220, 220, 255],
            [220, 40, 220, 255],
            [220, 220, 40, 255],
        ];
        let faces: [VrTexture; 6] = core::array::from_fn(|k| VrTexture {
            handle: solid_texture(device, 64, 64, colors[k]),
            kind: 0,
            color_space: 0,
        });
        say_number(
            "vrtest: skybox set (0 = done): ",
            set_skybox(compositor, faces.as_ptr(), 6) as u64,
        );

        let eye_texture = VrTexture {
            handle: texture,
            kind: 0,
            color_space: 0,
        };
        let mut poses = [0u8; 80 * 16];
        let mut event = [0u8; 64];
        let (mut start, mut frames) = (0i64, 0u64);
        QueryPerformanceCounter(&mut start);
        let mut step = 0;
        loop {
            let t = seconds_since(start);
            while poll(system, event.as_mut_ptr(), 64) {
                let kind = u32::from_le_bytes([event[0], event[1], event[2], event[3]]);
                say_number("vrtest: event ", kind as u64);
                if kind == 700 {
                    acknowledge_quit(system);
                    say_number(
                        "vrtest: Halliday asked to quit; acknowledged after frames: ",
                        frames,
                    );
                    let cleanup = core::mem::transmute::<*const c_void, unsafe extern "C" fn(Obj)>(
                        method(core, 1),
                    );
                    cleanup(core);
                    ExitProcess(0)
                }
            }
            // The panel's mouse: print each event; a click marks the spot (GL: y from the bottom).
            while poll_overlay(overlay, panel_handle, event.as_mut_ptr(), 64) {
                let word = |o: usize| [event[o], event[o + 1], event[o + 2], event[o + 3]];
                let kind = u32::from_le_bytes(word(0));
                let (x, y) = (f32::from_le_bytes(word(16)), f32::from_le_bytes(word(20)));
                match kind {
                    300 => {
                        MOVES += 1;
                        if MOVES % 30 == 1 {
                            say_number("vrtest: panel mouse move, x ", x as u64);
                            say_number("vrtest:   y (from the bottom) ", y as u64);
                        }
                    }
                    301 | 302 => {
                        say_number(
                            if kind == 301 {
                                "vrtest: panel mouse down, x "
                            } else {
                                "vrtest: panel mouse up, x "
                            },
                            x as u64,
                        );
                        say_number("vrtest:   y (from the bottom) ", y as u64);
                        if kind == 301 {
                            let (cx, cy) = (x as i32, ph as i32 - 1 - y as i32);
                            for dy in -6..=6 {
                                for dx in -6..=6 {
                                    let (px, py) = (cx + dx, cy + dy);
                                    if dx * dx + dy * dy <= 36
                                        && px >= 0
                                        && py >= 0
                                        && px < pw as i32
                                        && py < ph as i32
                                    {
                                        let i = ((py as u32 * pw + px as u32) * 4) as usize;
                                        panel[i..i + 4].copy_from_slice(&[255, 255, 255, 255]);
                                    }
                                }
                            }
                            set_raw(overlay, panel_handle, panel.as_ptr(), pw, ph, 4);
                        }
                    }
                    303 => say("vrtest: panel focus enter"),
                    304 => say("vrtest: panel focus leave"),
                    305 => say_number(
                        "vrtest: panel scroll, notches x100 ",
                        (f32::from_le_bytes(word(20)) * 100.0) as i64 as u64,
                    ),
                    _ => say_number("vrtest: panel event ", kind as u64),
                }
            }
            if t > 90.0 {
                say("vrtest: no quit request in 90 s");
                break;
            }
            let steps: [(f64, &str); 6] = [
                (10.0, "vrtest: 10 s: no frames for 6 s (loading)"),
                (16.0, "vrtest: 16 s: frames again"),
                (18.0, "vrtest: 18 s: fading to black"),
                (22.0, "vrtest: 22 s: fading back"),
                (24.0, "vrtest: 24 s: the compositor's grid"),
                (30.0, "vrtest: 30 s: frames, waiting for Halliday's quit"),
            ];
            if step < steps.len() && t >= steps[step].0 {
                say(steps[step].1);
                match step {
                    2 => fade_to_color(compositor, 1.0, 0.0, 0.0, 0.0, 1.0, false),
                    3 => fade_to_color(compositor, 0.5, 0.0, 0.0, 0.0, 0.0, false),
                    4 => fade_grid(compositor, 0.5, true),
                    5 => fade_grid(compositor, 0.5, false),
                    _ => {}
                }
                step += 1;
            }
            if (10.0..16.0).contains(&t) {
                // Loading: no WaitGetPoses, no frames; the runtime's heartbeat keeps Halliday in the game.
                Sleep(20);
                continue;
            }
            wait(compositor, poses.as_mut_ptr(), 16, core::ptr::null_mut(), 0);
            if submit(compositor, 0, &eye_texture, &[0.0, 0.0, 0.5, 1.0], 0) != 0
                || submit(compositor, 1, &eye_texture, &[0.5, 0.0, 1.0, 1.0], 0) != 0
            {
                fail("vrtest: Submit failed");
            }
            frames += 1;
            if frames == 120 {
                let mut timing = [0u8; 184];
                timing[..4].copy_from_slice(&176u32.to_le_bytes());
                if frame_timing(compositor, timing.as_mut_ptr(), 0) {
                    let f = |o: usize| {
                        f32::from_le_bytes([timing[o], timing[o + 1], timing[o + 2], timing[o + 3]])
                    };
                    say_number(
                        "vrtest: frame timing: frame index ",
                        u32::from_le_bytes([timing[4], timing[5], timing[6], timing[7]]) as u64,
                    );
                    say_number(
                        "vrtest:   client frame interval (us) ",
                        (f(56) * 1000.0) as u64,
                    );
                    say_number("vrtest:   wait..submit (us) ", (f(32) * 1000.0) as u64);
                } else {
                    say("vrtest: no frame timing");
                }
            }
        }
        let cleanup =
            core::mem::transmute::<*const c_void, unsafe extern "C" fn(Obj)>(method(core, 1));
        cleanup(core);
        say("vrtest: done");
        ExitProcess(0)
    }
}
