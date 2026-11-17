//! `IVRInput_007`: SteamVR Input (action manifests), answered from the emulated controllers.
//!
//! The game names its manifest (`SetActionManifestPath`); the runtime reads the actions and action
//! sets from it, and the default bindings for the controller Halliday emulates (a Vive wand,
//! `vive_controller`). Each `UpdateActionState` computes every action of the active sets from the
//! controllers' buttons (`button`, `trigger`, `trackpad` and `dpad` modes), and the game reads the
//! results (digital, analog, pose). Skeletons (finger tracking) are reported as unavailable.
//! Interface layout: Valve's openvr.h 1.7.15 (BSD-3-Clause).

use crate::iface::system::write_string;
use crate::json::{self, Doc};
use crate::log::{CStr, log};
use crate::ovr::{self, TrackedDevicePose};
use crate::runtime::{self, Locked};
use crate::{Iface, win};
use core::ffi::{c_char, c_void};
use core::sync::atomic::{AtomicU32, Ordering};

type This = *mut Iface;

const NONE: i32 = 0;
const NAME_NOT_FOUND: i32 = 1;
const INVALID_HANDLE: i32 = 3;
const NO_DATA: i32 = 13;

// Input source handles (`k_ulInvalidInputValueHandle` is 0: "any device").
const LEFT_HAND: u64 = 0x1001;
const RIGHT_HAND: u64 = 0x1002;
const HEAD: u64 = 0x1003;
const ACTION_BASE: u64 = 0x10_0000;
const SET_BASE: u64 = 0x20_0000;

const MAX_ACTIONS: usize = 128;
const MAX_SETS: usize = 32;
const MAX_BINDINGS: usize = 384;
const POOL: usize = 16 * 1024;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Boolean,
    Vector,
    Pose,
    Other,
}

#[derive(Clone, Copy, PartialEq)]
enum Component {
    Trigger,
    Trackpad,
    Grip,
    Menu,
    System,
}

#[derive(Clone, Copy, PartialEq)]
enum Direction {
    North,
    South,
    East,
    West,
    Center,
}

#[derive(Clone, Copy)]
enum Source {
    Click(Component),
    Touch(Component),
    /// The trigger's pull (0..1).
    Pull,
    /// The trackpad's position (x, y).
    Position,
    /// A region of the trackpad, pressed (or touched), and the center's radius in percent of the
    /// pad's (`deadzone_pct`, SteamVR's default 50).
    Dpad(Direction, bool, u8),
    Pose,
}

#[derive(Clone, Copy)]
struct Binding {
    action: u16,
    hand: u8,
    source: Source,
}

#[derive(Clone, Copy)]
struct Name {
    start: u16,
    len: u16,
}

#[derive(Clone, Copy)]
struct Action {
    name: Name,
    kind: Kind,
    set: u8,
}

struct Input {
    pool: [u8; POOL],
    pool_len: usize,
    sets: [Name; MAX_SETS],
    set_count: usize,
    actions: [Action; MAX_ACTIONS],
    action_count: usize,
    bindings: [Binding; MAX_BINDINGS],
    binding_count: usize,
    /// Bit per action set: active since the last `UpdateActionState`.
    active: u32,
    /// Per action and hand (left, right): now and at the update before.
    digital: [[bool; 2]; MAX_ACTIONS],
    previous: [[bool; 2]; MAX_ACTIONS],
    analog: [[[f32; 2]; 2]; MAX_ACTIONS],
    previous_analog: [[[f32; 2]; 2]; MAX_ACTIONS],
}

const NO_NAME: Name = Name { start: 0, len: 0 };
const NO_ACTION: Action = Action {
    name: NO_NAME,
    kind: Kind::Other,
    set: 255,
};
const NO_BINDING: Binding = Binding {
    action: 0,
    hand: 0,
    source: Source::Pose,
};

static INPUT: Locked<Input> = Locked::new(Input {
    pool: [0; POOL],
    pool_len: 0,
    sets: [NO_NAME; MAX_SETS],
    set_count: 0,
    actions: [NO_ACTION; MAX_ACTIONS],
    action_count: 0,
    bindings: [NO_BINDING; MAX_BINDINGS],
    binding_count: 0,
    active: 0,
    digital: [[false; 2]; MAX_ACTIONS],
    previous: [[false; 2]; MAX_ACTIONS],
    analog: [[[0.0; 2]; 2]; MAX_ACTIONS],
    previous_analog: [[[0.0; 2]; 2]; MAX_ACTIONS],
});

impl Input {
    fn text(&self, n: Name) -> &[u8] {
        &self.pool[n.start as usize..(n.start + n.len) as usize]
    }

    fn store(&mut self, s: &[u8]) -> Name {
        let len = s.len().min(POOL - self.pool_len).min(u16::MAX as usize);
        let start = self.pool_len;
        for (d, c) in self.pool[start..start + len].iter_mut().zip(s) {
            *d = c.to_ascii_lowercase();
        }
        self.pool_len += len;
        Name {
            start: start as u16,
            len: len as u16,
        }
    }

    fn set_index(&mut self, name: &[u8], add: bool) -> Option<usize> {
        if let Some(i) = (0..self.set_count).find(|&i| json::same(self.text(self.sets[i]), name)) {
            return Some(i);
        }
        if !add || self.set_count == MAX_SETS {
            return None;
        }
        let n = self.store(name);
        self.sets[self.set_count] = n;
        self.set_count += 1;
        Some(self.set_count - 1)
    }

    fn action_index(&mut self, name: &[u8], add: bool) -> Option<usize> {
        if let Some(i) =
            (0..self.action_count).find(|&i| json::same(self.text(self.actions[i].name), name))
        {
            return Some(i);
        }
        if !add || self.action_count == MAX_ACTIONS {
            return None;
        }
        // "/actions/<set>/in/<name>": the set is the path's first two parts.
        let set = set_of(name)
            .and_then(|s| self.set_index(s, true))
            .unwrap_or(255);
        let n = self.store(name);
        self.actions[self.action_count] = Action {
            name: n,
            kind: Kind::Other,
            set: set as u8,
        };
        self.action_count += 1;
        Some(self.action_count - 1)
    }
}

fn set_of(action: &[u8]) -> Option<&[u8]> {
    let mut slashes = 0;
    for (i, &c) in action.iter().enumerate() {
        if c == b'/' {
            slashes += 1;
            if slashes == 3 {
                return Some(&action[..i]);
            }
        }
    }
    None
}

static FILE: Locked<[u8; 64 * 1024]> = Locked::new([0; 64 * 1024]);
static NODES: Locked<[json::Node; json::MAX_NODES]> = Locked::new(
    [json::Node {
        kind: json::Kind::Null,
        start: 0,
        end: 0,
        key_start: 0,
        key_end: 0,
        first: 0,
        next: 0,
    }; json::MAX_NODES],
);

/// Reads a file (ANSI path, NUL-terminated) into `buf`; its length.
fn read_file(path: &[u8], buf: &mut [u8]) -> Option<usize> {
    // SAFETY: plain Win32 calls with a NUL-terminated path and our buffer.
    unsafe {
        let h = win::CreateFileA(
            path.as_ptr(),
            win::GENERIC_READ,
            win::FILE_SHARE_READ,
            core::ptr::null_mut(),
            win::OPEN_EXISTING,
            win::FILE_ATTRIBUTE_NORMAL,
            core::ptr::null_mut(),
        );
        if h == win::INVALID_HANDLE_VALUE {
            return None;
        }
        let mut read = 0u32;
        let ok = win::ReadFile(
            h,
            buf.as_mut_ptr().cast(),
            buf.len() as u32,
            &mut read,
            core::ptr::null_mut(),
        );
        win::CloseHandle(h);
        (ok != 0 && (read as usize) < buf.len()).then_some(read as usize)
    }
}

/// `dir` + `name` as a NUL-terminated path (`/` turned into `\`).
fn join(dir: &[u8], name: &[u8], out: &mut [u8; 1024]) -> Option<()> {
    if dir.len() + name.len() + 1 >= out.len() {
        return None;
    }
    out[..dir.len()].copy_from_slice(dir);
    for (o, &c) in out[dir.len()..].iter_mut().zip(name) {
        *o = if c == b'/' { b'\\' } else { c };
    }
    out[dir.len() + name.len()] = 0;
    Some(())
}

fn component(name: &[u8]) -> Option<Component> {
    Some(match name {
        b"trigger" => Component::Trigger,
        b"trackpad" => Component::Trackpad,
        b"grip" => Component::Grip,
        b"application_menu" => Component::Menu,
        b"system" => Component::System,
        _ => return None, // not on a Vive wand (a, b, x, y, thumbstick, joystick, pinch)
    })
}

/// "/user/hand/left/input/trigger" → (left, "trigger"); poses "/user/hand/right/pose/raw".
fn hand_and_part(path: &[u8]) -> Option<(u8, &[u8])> {
    let rest = if path.len() > 15 && json::same(&path[..15], b"/user/hand/left") {
        (0, &path[15..])
    } else if path.len() > 16 && json::same(&path[..16], b"/user/hand/right") {
        (1, &path[16..])
    } else {
        return None;
    };
    let part = rest
        .1
        .strip_prefix(b"/input/")
        .or_else(|| rest.1.strip_prefix(b"/pose/"))
        .unwrap_or(rest.1);
    Some((rest.0, part))
}

/// Reads the action manifest and the Vive bindings it points to.
fn load_manifest(path: &[u8]) -> bool {
    FILE.with(|file| NODES.with(|nodes| load_with(path, file, nodes)))
}

fn load_with(
    path: &[u8],
    file: &mut [u8; 64 * 1024],
    nodes: &mut [json::Node; json::MAX_NODES],
) -> bool {
    let Some(len) = read_file(path, file) else {
        log!(
            "input: can't read the action manifest {}",
            CStr(path.as_ptr().cast())
        );
        return false;
    };
    let mut binding_url = [0u8; 256];
    let mut url_len = 0;
    let doc_ok = {
        let Some(doc) = Doc::parse(&file[..len], nodes) else {
            log!("input: the action manifest isn't valid JSON");
            return false;
        };
        INPUT.with(|input| {
            input.pool_len = 0;
            input.set_count = 0;
            input.action_count = 0;
            input.binding_count = 0;
            if let Some(sets) = doc.get(0, b"action_sets") {
                for s in doc.children(sets) {
                    if let Some(name) = doc.string(s, b"name") {
                        input.set_index(name, true);
                    }
                }
            }
            if let Some(actions) = doc.get(0, b"actions") {
                for a in doc.children(actions) {
                    let (Some(name), kind) = (
                        doc.string(a, b"name"),
                        doc.string(a, b"type").unwrap_or(b""),
                    ) else {
                        continue;
                    };
                    if let Some(i) = input.action_index(name, true) {
                        input.actions[i].kind = match kind {
                            b"boolean" => Kind::Boolean,
                            b"vector1" | b"vector2" | b"vector3" => Kind::Vector,
                            b"pose" => Kind::Pose,
                            _ => Kind::Other,
                        };
                    }
                }
            }
        });
        if let Some(bindings) = doc.get(0, b"default_bindings") {
            for b in doc.children(bindings) {
                if doc.string(b, b"controller_type") == Some(b"vive_controller")
                    && let Some(url) = doc.string(b, b"binding_url")
                {
                    url_len = url.len().min(binding_url.len());
                    binding_url[..url_len].copy_from_slice(&url[..url_len]);
                }
            }
        }
        true
    };
    if !doc_ok {
        return false;
    }
    let (actions, sets) = INPUT.with(|i| (i.action_count, i.set_count));
    if url_len == 0 {
        log!("input: {actions} actions in {sets} sets; no default bindings for a Vive controller");
        return true;
    }
    // The bindings file, next to the manifest.
    let dir_len = path
        .iter()
        .rposition(|&c| c == b'\\' || c == b'/')
        .map_or(0, |i| i + 1);
    let mut full = [0u8; 1024];
    if join(&path[..dir_len], &binding_url[..url_len], &mut full).is_none() {
        return true;
    }
    let Some(len) = read_file(&full, file) else {
        log!(
            "input: can't read the Vive bindings {}",
            CStr(full.as_ptr().cast())
        );
        return true;
    };
    let Some(doc) = Doc::parse(&file[..len], nodes) else {
        log!("input: the Vive bindings aren't valid JSON");
        return true;
    };
    INPUT.with(|input| {
        let Some(all) = doc.get(0, b"bindings") else {
            return;
        };
        for set in doc.children(all) {
            for group in [b"sources".as_slice(), b"poses"] {
                let Some(list) = doc.get(set, group) else {
                    continue;
                };
                for entry in doc.children(list) {
                    let Some(path) = doc.string(entry, b"path") else {
                        continue;
                    };
                    let Some((hand, part)) = hand_and_part(path) else {
                        continue;
                    };
                    let add = |input: &mut Input, output: &[u8], source: Source| {
                        if input.binding_count < MAX_BINDINGS
                            && let Some(action) = input.action_index(output, false)
                        {
                            input.bindings[input.binding_count] = Binding {
                                action: action as u16,
                                hand,
                                source,
                            };
                            input.binding_count += 1;
                        }
                    };
                    if group == b"poses" {
                        if let Some(output) = doc.string(entry, b"output") {
                            add(input, output, Source::Pose);
                        }
                        continue;
                    }
                    let (Some(comp), Some(inputs)) = (component(part), doc.get(entry, b"inputs"))
                    else {
                        continue;
                    };
                    let mode = doc.string(entry, b"mode").unwrap_or(b"button");
                    let parameters = doc.get(entry, b"parameters");
                    let touch_dpad = parameters
                        .and_then(|p| doc.string(p, b"sub_mode"))
                        .is_some_and(|m| m == b"touch");
                    let deadzone = parameters
                        .and_then(|p| doc.string(p, b"deadzone_pct"))
                        .and_then(|t| core::str::from_utf8(t).ok()?.parse::<u8>().ok())
                        .unwrap_or(50)
                        .min(99);
                    for input_node in doc.children(inputs) {
                        let Some(output) = doc.string(input_node, b"output") else {
                            continue;
                        };
                        let source = match (mode, doc.key(input_node)) {
                            (_, b"click") => Source::Click(comp),
                            (_, b"touch") => Source::Touch(comp),
                            (b"trigger", b"pull") => Source::Pull,
                            (_, b"position") if comp == Component::Trackpad => Source::Position,
                            (b"dpad", dir) => Source::Dpad(
                                match dir {
                                    b"north" => Direction::North,
                                    b"south" => Direction::South,
                                    b"east" => Direction::East,
                                    b"west" => Direction::West,
                                    _ => Direction::Center,
                                },
                                touch_dpad,
                                deadzone,
                            ),
                            _ => continue,
                        };
                        add(input, output, source);
                    }
                }
            }
        }
    });
    let bound = INPUT.with(|i| i.binding_count);
    log!(
        "input: {actions} actions in {sets} sets; {bound} bindings to the emulated Vive controllers"
    );
    true
}

pub unsafe extern "C" fn set_action_manifest_path(_: This, path: *const c_char) -> i32 {
    crate::log::seen!("IVRInput::set_action_manifest_path");
    if path.is_null() {
        return NAME_NOT_FOUND;
    }
    let mut p = [0u8; 1024];
    let mut n = 0;
    // SAFETY: the game's NUL-terminated path.
    while n < 1023 && unsafe { *path.add(n) } != 0 {
        p[n] = unsafe { *path.add(n) } as u8;
        n += 1;
    }
    log!("input: action manifest {}", CStr(path));
    load_manifest(&p[..=n]);
    NONE
}

fn name_bytes(s: *const c_char) -> &'static [u8] {
    if s.is_null() {
        return b"";
    }
    let mut n = 0;
    // SAFETY: a NUL-terminated string from the game; at most 512 bytes looked at.
    while n < 512 && unsafe { *s.add(n) } != 0 {
        n += 1;
    }
    // SAFETY: `n` bytes just read.
    unsafe { core::slice::from_raw_parts(s.cast(), n) }
}

fn put(out: *mut u64, v: u64) {
    if !out.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *out = v };
    }
}

pub unsafe extern "C" fn get_action_set_handle(_: This, name: *const c_char, out: *mut u64) -> i32 {
    crate::log::seen!("IVRInput::get_action_set_handle");
    match INPUT.with(|i| i.set_index(name_bytes(name), true)) {
        Some(i) => {
            put(out, SET_BASE + i as u64);
            NONE
        }
        None => NAME_NOT_FOUND,
    }
}

pub unsafe extern "C" fn get_action_handle(_: This, name: *const c_char, out: *mut u64) -> i32 {
    crate::log::seen!("IVRInput::get_action_handle");
    match INPUT.with(|i| i.action_index(name_bytes(name), true)) {
        Some(i) => {
            put(out, ACTION_BASE + i as u64);
            NONE
        }
        None => NAME_NOT_FOUND,
    }
}

pub unsafe extern "C" fn get_input_source_handle(
    _: This,
    path: *const c_char,
    out: *mut u64,
) -> i32 {
    crate::log::seen!("IVRInput::get_input_source_handle");
    let p = name_bytes(path);
    let h = if json::same(p, b"/user/hand/left") {
        LEFT_HAND
    } else if json::same(p, b"/user/hand/right") {
        RIGHT_HAND
    } else if json::same(p, b"/user/head") {
        HEAD
    } else {
        0x2000
            + (p.iter().fold(0u32, |h, &c| {
                h.wrapping_mul(31)
                    .wrapping_add(c.to_ascii_lowercase() as u32)
            }) & 0xFFFF) as u64
    };
    put(out, h);
    NONE
}

fn pressed_bit(c: Component) -> u64 {
    1 << match c {
        Component::System => 0,
        Component::Menu => 1,
        Component::Grip => 2,
        Component::Trackpad => 32,
        Component::Trigger => 33,
    }
}

pub unsafe extern "C" fn update_action_state(
    _: This,
    sets: *const u8,
    size: u32,
    count: u32,
) -> i32 {
    crate::log::seen!("IVRInput::update_action_state");
    let state = runtime::latest_state();
    INPUT.with(|input| {
        input.active = 0;
        for k in 0..count as usize {
            // SAFETY: the game's array of `count` VRActiveActionSet_t of `size` bytes (handle first).
            let handle = unsafe { (sets.add(k * size as usize) as *const u64).read_unaligned() };
            if (SET_BASE..SET_BASE + MAX_SETS as u64).contains(&handle) {
                input.active |= 1 << (handle - SET_BASE);
            }
        }
        // Diagnostics: the sets the game turns on, whenever they change.
        static LOGGED_SETS: AtomicU32 = AtomicU32::new(u32::MAX);
        if LOGGED_SETS.swap(input.active, Ordering::Relaxed) != input.active {
            let mut names = [0u8; 256];
            let mut n = 0;
            for set in 0..input.set_count {
                if input.active & (1 << set) != 0 {
                    for &c in input.text(input.sets[set]).iter().chain(b" ") {
                        if n < names.len() {
                            names[n] = c;
                            n += 1;
                        }
                    }
                }
            }
            log!(
                "input: action sets on: {}",
                core::str::from_utf8(&names[..n]).unwrap_or("?")
            );
        }
        input.previous = input.digital;
        input.previous_analog = input.analog;
        input.digital = [[false; 2]; MAX_ACTIONS];
        input.analog = [[[0.0; 2]; 2]; MAX_ACTIONS];
        for b in &input.bindings[..input.binding_count] {
            let a = b.action as usize;
            let set = input.actions[a].set;
            if set as usize >= MAX_SETS || input.active & (1 << set) == 0 {
                continue;
            }
            let c = &state.controllers[b.hand as usize];
            if c.connected == 0 {
                continue;
            }
            let pad = c.axes[0];
            let hand = b.hand as usize;
            match b.source {
                Source::Click(comp) => input.digital[a][hand] |= c.pressed & pressed_bit(comp) != 0,
                Source::Touch(comp) => input.digital[a][hand] |= c.touched & pressed_bit(comp) != 0,
                Source::Pull => {
                    let v = c.axes[1][0];
                    if v > input.analog[a][hand][0] {
                        input.analog[a][hand] = [v, 0.0];
                    }
                }
                Source::Position => {
                    if c.touched & pressed_bit(Component::Trackpad) != 0 {
                        input.analog[a][hand] = pad;
                    }
                }
                Source::Dpad(dir, touch, deadzone) => {
                    let on = if touch { c.touched } else { c.pressed }
                        & pressed_bit(Component::Trackpad)
                        != 0;
                    let (x, y) = (pad[0], pad[1]);
                    let r2 = x * x + y * y;
                    let center = deadzone as f32 / 100.0;
                    let region = if r2 < center * center {
                        Direction::Center
                    } else if y.abs() >= x.abs() {
                        if y > 0.0 {
                            Direction::North
                        } else {
                            Direction::South
                        }
                    } else if x > 0.0 {
                        Direction::East
                    } else {
                        Direction::West
                    };
                    input.digital[a][hand] |= on && region == dir;
                }
                Source::Pose => {}
            }
        }
        // Diagnostics: the first presses of digital actions (which action, which hand).
        static LOGGED_PRESSES: AtomicU32 = AtomicU32::new(0);
        for a in 0..input.action_count {
            for hand in 0..2 {
                if input.digital[a][hand]
                    && !input.previous[a][hand]
                    && LOGGED_PRESSES.fetch_add(1, Ordering::Relaxed) < 40
                {
                    log!(
                        "input: {} on ({} hand)",
                        core::str::from_utf8(input.text(input.actions[a].name)).unwrap_or("?"),
                        if hand == 0 { "left" } else { "right" }
                    );
                }
            }
        }
    });
    NONE
}

fn hands(restrict: u64) -> core::ops::Range<usize> {
    match restrict {
        LEFT_HAND => 0..1,
        RIGHT_HAND => 1..2,
        _ => 0..2,
    }
}

fn action_of(handle: u64) -> Option<usize> {
    let a = handle.checked_sub(ACTION_BASE)? as usize;
    (a < INPUT.with(|i| i.action_count)).then_some(a)
}

/// Whether the action is bound for `hand` and its set active.
fn live(input: &Input, a: usize, hand: usize) -> bool {
    let set = input.actions[a].set;
    (set as usize) < MAX_SETS
        && input.active & (1 << set) != 0
        && input.bindings[..input.binding_count]
            .iter()
            .any(|b| b.action as usize == a && b.hand as usize == hand)
}

fn clear(out: *mut u8, size: u32) {
    // SAFETY: the game's struct of `size` bytes.
    unsafe { core::ptr::write_bytes(out, 0, size as usize) };
}

pub unsafe extern "C" fn get_digital_action_data(
    _: This,
    action: u64,
    out: *mut u8,
    size: u32,
    restrict: u64,
) -> i32 {
    crate::log::seen!("IVRInput::get_digital_action_data");
    if out.is_null() || size < 24 {
        return INVALID_HANDLE;
    }
    clear(out, size);
    let Some(a) = action_of(action) else {
        return INVALID_HANDLE;
    };
    INPUT.with(|input| {
        for hand in hands(restrict) {
            if !live(input, a, hand) {
                continue;
            }
            let (now, before) = (input.digital[a][hand], input.previous[a][hand]);
            // SAFETY: InputDigitalActionData_t: bActive @0, activeOrigin @8, bState @16, bChanged @17.
            unsafe {
                *out = 1;
                if now || (out.add(8) as *const u64).read_unaligned() == 0 {
                    (out.add(8) as *mut u64).write_unaligned(if hand == 0 {
                        LEFT_HAND
                    } else {
                        RIGHT_HAND
                    });
                }
                *out.add(16) |= now as u8;
                *out.add(17) |= (now != before) as u8;
            }
        }
    });
    NONE
}

pub unsafe extern "C" fn get_analog_action_data(
    _: This,
    action: u64,
    out: *mut u8,
    size: u32,
    restrict: u64,
) -> i32 {
    crate::log::seen!("IVRInput::get_analog_action_data");
    if out.is_null() || size < 44 {
        return INVALID_HANDLE;
    }
    clear(out, size);
    let Some(a) = action_of(action) else {
        return INVALID_HANDLE;
    };
    INPUT.with(|input| {
        let mut best = 0.0f32;
        for hand in hands(restrict) {
            if !live(input, a, hand) {
                continue;
            }
            let [x, y] = input.analog[a][hand];
            let [px, py] = input.previous_analog[a][hand];
            // SAFETY: InputAnalogActionData_t: bActive @0, activeOrigin @8, x y z @16, deltas @28.
            unsafe {
                *out = 1;
                let m = x * x + y * y;
                if m >= best {
                    best = m;
                    (out.add(8) as *mut u64).write_unaligned(if hand == 0 {
                        LEFT_HAND
                    } else {
                        RIGHT_HAND
                    });
                    let f = out.add(16) as *mut f32;
                    f.write_unaligned(x);
                    f.add(1).write_unaligned(y);
                    f.add(3).write_unaligned(x - px);
                    f.add(4).write_unaligned(y - py);
                }
            }
        }
    });
    NONE
}

fn pose_data(action: u64, universe: u32, out: *mut u8, size: u32, restrict: u64) -> i32 {
    if out.is_null() || size < 96 {
        return INVALID_HANDLE;
    }
    clear(out, size);
    let Some(a) = action_of(action) else {
        return INVALID_HANDLE;
    };
    let state = runtime::latest_state();
    let mut poses = [ovr::INVALID_POSE; 3];
    runtime::fill_poses(&state, universe, poses.as_mut_ptr(), 3);
    INPUT.with(|input| {
        for hand in hands(restrict) {
            if !live(input, a, hand) || !poses[hand + 1].device_is_connected {
                continue;
            }
            // SAFETY: InputPoseActionData_t: bActive @0, activeOrigin @8, pose @16 (80 bytes).
            unsafe {
                *out = 1;
                (out.add(8) as *mut u64).write_unaligned(if hand == 0 {
                    LEFT_HAND
                } else {
                    RIGHT_HAND
                });
                (out.add(16) as *mut TrackedDevicePose).write_unaligned(poses[hand + 1]);
            }
            break;
        }
    });
    NONE
}

pub unsafe extern "C" fn get_pose_action_data_relative_to_now(
    _: This,
    action: u64,
    universe: u32,
    _seconds: f32,
    out: *mut u8,
    size: u32,
    restrict: u64,
) -> i32 {
    crate::log::seen!("IVRInput::get_pose_action_data_relative_to_now");
    pose_data(action, universe, out, size, restrict)
}

pub unsafe extern "C" fn get_pose_action_data_for_next_frame(
    _: This,
    action: u64,
    universe: u32,
    out: *mut u8,
    size: u32,
    restrict: u64,
) -> i32 {
    crate::log::seen!("IVRInput::get_pose_action_data_for_next_frame");
    pose_data(action, universe, out, size, restrict)
}

pub unsafe extern "C" fn get_skeletal_action_data(
    _: This,
    _action: u64,
    out: *mut u8,
    size: u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_skeletal_action_data");
    if !out.is_null() {
        clear(out, size); // bActive false: no finger tracking
    }
    NONE
}

pub unsafe extern "C" fn get_bone_count(_: This, _action: u64, count: *mut u32) -> i32 {
    crate::log::seen!("IVRInput::get_bone_count");
    if !count.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *count = 0 };
    }
    NO_DATA
}

pub unsafe extern "C" fn get_bone_hierarchy(
    _: This,
    _action: u64,
    _out: *mut i32,
    _count: u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_bone_hierarchy");
    NO_DATA
}

pub unsafe extern "C" fn get_bone_name(
    _: This,
    _action: u64,
    _bone: i32,
    out: *mut c_char,
    size: u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_bone_name");
    write_string(b"\0", out, size);
    NO_DATA
}

pub unsafe extern "C" fn get_skeletal_reference_transforms(
    _: This,
    _action: u64,
    _space: i32,
    _pose: i32,
    _out: *mut c_void,
    _count: u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_skeletal_reference_transforms");
    NO_DATA
}

pub unsafe extern "C" fn get_skeletal_tracking_level(
    _: This,
    _action: u64,
    level: *mut i32,
) -> i32 {
    crate::log::seen!("IVRInput::get_skeletal_tracking_level");
    if !level.is_null() {
        // SAFETY: the game's out pointer (VRSkeletalTracking_Estimated).
        unsafe { *level = 0 };
    }
    NONE
}

pub unsafe extern "C" fn get_skeletal_bone_data(
    _: This,
    _action: u64,
    _space: i32,
    _range: i32,
    _out: *mut c_void,
    _count: u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_skeletal_bone_data");
    NO_DATA
}

pub unsafe extern "C" fn get_skeletal_summary_data(
    _: This,
    _action: u64,
    _kind: i32,
    _out: *mut c_void,
) -> i32 {
    crate::log::seen!("IVRInput::get_skeletal_summary_data");
    NO_DATA
}

pub unsafe extern "C" fn get_skeletal_bone_data_compressed(
    _: This,
    _action: u64,
    _range: i32,
    _out: *mut c_void,
    _size: u32,
    required: *mut u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_skeletal_bone_data_compressed");
    if !required.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *required = 0 };
    }
    NO_DATA
}

pub unsafe extern "C" fn decompress_skeletal_bone_data(
    _: This,
    _buf: *const c_void,
    _size: u32,
    _space: i32,
    _out: *mut c_void,
    _count: u32,
) -> i32 {
    crate::log::seen!("IVRInput::decompress_skeletal_bone_data");
    NO_DATA
}

pub unsafe extern "C" fn trigger_haptic_vibration_action(
    _: This,
    _action: u64,
    _start: f32,
    _duration: f32,
    _frequency: f32,
    _amplitude: f32,
    _restrict: u64,
) -> i32 {
    crate::log::seen!("IVRInput::trigger_haptic_vibration_action");
    NONE
}

pub unsafe extern "C" fn get_action_origins(
    _: This,
    _set: u64,
    action: u64,
    out: *mut u64,
    count: u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_action_origins");
    if out.is_null() {
        return NONE;
    }
    // SAFETY: the game's array of `count` handles.
    unsafe { core::ptr::write_bytes(out, 0, count as usize) };
    let Some(a) = action_of(action) else {
        return INVALID_HANDLE;
    };
    let mut n = 0;
    INPUT.with(|input| {
        for hand in 0..2 {
            if n < count as usize && live(input, a, hand) {
                // SAFETY: as above.
                unsafe { *out.add(n) = if hand == 0 { LEFT_HAND } else { RIGHT_HAND } };
                n += 1;
            }
        }
    });
    NONE
}

pub unsafe extern "C" fn get_origin_localized_name(
    _: This,
    origin: u64,
    out: *mut c_char,
    size: u32,
    _sections: i32,
) -> i32 {
    crate::log::seen!("IVRInput::get_origin_localized_name");
    let name: &[u8] = match origin {
        LEFT_HAND => b"Left Controller\0",
        RIGHT_HAND => b"Right Controller\0",
        _ => b"Headset\0",
    };
    write_string(name, out, size);
    NONE
}

pub unsafe extern "C" fn get_origin_tracked_device_info(
    _: This,
    origin: u64,
    out: *mut u8,
    size: u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_origin_tracked_device_info");
    if out.is_null() || size < 12 {
        return INVALID_HANDLE;
    }
    clear(out, size);
    let device = match origin {
        LEFT_HAND => ovr::LEFT,
        RIGHT_HAND => ovr::RIGHT,
        HEAD => ovr::HMD,
        _ => return INVALID_HANDLE,
    };
    // SAFETY: InputOriginInfo_t: devicePath @0, trackedDeviceIndex @8, component name @12.
    unsafe {
        (out as *mut u64).write_unaligned(origin);
        (out.add(8) as *mut u32).write_unaligned(device);
    }
    NONE
}

pub unsafe extern "C" fn get_action_binding_info(
    _: This,
    _action: u64,
    _out: *mut c_void,
    _size: u32,
    _count: u32,
    returned: *mut u32,
) -> i32 {
    crate::log::seen!("IVRInput::get_action_binding_info");
    if !returned.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *returned = 0 };
    }
    NONE
}

pub unsafe extern "C" fn show_action_origins(_: This, _set: u64, _action: u64) -> i32 {
    crate::log::seen!("IVRInput::show_action_origins");
    NONE
}

pub unsafe extern "C" fn show_bindings_for_action_set(
    _: This,
    _sets: *const c_void,
    _size: u32,
    _count: u32,
    _highlight: u64,
) -> i32 {
    crate::log::seen!("IVRInput::show_bindings_for_action_set");
    NONE
}

pub unsafe extern "C" fn is_using_legacy_input(_: This) -> bool {
    crate::log::seen!("IVRInput::is_using_legacy_input");
    false
}
