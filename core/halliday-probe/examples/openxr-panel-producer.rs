//! Isolated stdin-driven GameSide producer for the actual Swift bridge/compositor oracle.
//! Build with `cargo build -p halliday-probe --example openxr-panel-producer --release`.
use halliday_bridge as bridge;
use halliday_core::game_bridge::{GameSide, PanelImage};
use std::io::{BufRead, Write};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::sync::atomic::Ordering;

unsafe extern "C" {
    fn mmap(
        addr: *mut core::ffi::c_void,
        len: usize,
        prot: i32,
        flags: i32,
        fd: i32,
        off: i64,
    ) -> *mut core::ffi::c_void;
    fn munmap(addr: *mut core::ffi::c_void, len: usize) -> i32;
}
struct Mapping(*mut bridge::Header);
impl Mapping {
    fn new(path: &Path) -> Self {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .unwrap();
        let base = unsafe {
            mmap(
                std::ptr::null_mut(),
                bridge::FILE_BYTES,
                3,
                1,
                file.as_raw_fd(),
                0,
            )
        };
        assert_ne!(base as isize, -1);
        Self(base.cast())
    }
    fn header(&self) -> &bridge::Header {
        unsafe { &*self.0 }
    }
}
impl Drop for Mapping {
    fn drop(&mut self) {
        unsafe {
            munmap(self.0.cast(), bridge::FILE_BYTES);
        }
    }
}
fn reply(text: &str) {
    println!("{text}");
    std::io::stdout().flush().unwrap();
}
fn main() {
    let path = std::env::args().nth(1).expect("owned bridge path");
    let path = Path::new(&path);
    let folder = path
        .parent()
        .and_then(Path::parent)
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .expect("isolated fixture support folder");
    let token = folder
        .strip_prefix("Halliday OpenXR Panel Acceptance ")
        .expect("uniquely named acceptance host only");
    assert!(
        token.len() == 32 && token.bytes().all(|b| b.is_ascii_hexdigit()),
        "fixture UUID"
    );
    assert!(
        path.ends_with("OpenVR/halliday-bridge.shm"),
        "fixture bridge path"
    );
    assert_eq!(
        std::fs::canonicalize(path).expect("existing owned bridge"),
        path,
        "symlinks and parent traversal are not accepted"
    );
    let mut side = GameSide::view(path).unwrap();
    let map = Mapping::new(path);
    assert!(side.register_client_as("OpenXR panel acceptance producer"));
    let mut epoch = side.begin_haptics();
    assert_ne!(epoch, 0);
    reply(&format!("{{\"ready\":true,\"epoch\":{epoch}}}"));
    let identity = [0.0, 0.0, 0.0, 1.0];
    let mut restore_batch_capability = false;
    for line in std::io::stdin().lock().lines() {
        let command = line.unwrap();
        if restore_batch_capability {
            unsafe {
                map.0
                    .cast::<u8>()
                    .add(bridge::panels::OFFSET)
                    .cast::<u32>()
                    .write_volatile(bridge::panels::MAGIC)
            };
            restore_batch_capability = false;
        }
        if command == "quit" {
            break;
        }
        if command == "input-state" {
            let state = side.state_snapshot().expect("complete input publication");
            let [left, right] = state.controllers;
            reply(&format!(
                "{{\"triggers\":[{},{}],\"pressed\":[{},{}],\"touched\":[{},{}]}}",
                left.axes[1][0],
                right.axes[1][0],
                left.pressed & (1 << 33) != 0,
                right.pressed & (1 << 33) != 0,
                left.touched & (1 << 33) != 0,
                right.touched & (1 << 33) != 0
            ));
            continue;
        }
        if command == "cadence-state" {
            let h = map.header();
            let ext = unsafe { bridge::haptics::extension(map.0) };
            let state = side.state_snapshot().expect("complete input publication");
            reply(&format!(
                "{{\"epoch\":{},\"mapping\":{},\"notifications\":{},\"state_sequence\":{},\"interval_ns\":{},\"frames\":{},\"head_stamp\":{},\"eye_width\":{},\"eye_height\":{},\"reference_epoch\":{}}}",
                ext.client_epoch.load(Ordering::SeqCst),
                map.0 as usize,
                side.host_tick(),
                h.state_seq.load(Ordering::SeqCst),
                h.frame_interval_ns.load(Ordering::SeqCst),
                h.client_frames.load(Ordering::SeqCst),
                state.head.stamp,
                h.eye_width,
                h.eye_height,
                side.space_epoch()
            ));
            continue;
        }
        if command == "restart" {
            let old = epoch;
            side.end_haptics(epoch);
            side.unregister_client();
            side = GameSide::view(path).unwrap();
            assert!(side.register_client_as("OpenXR panel acceptance restarted"));
            epoch = side.begin_haptics();
            assert!(epoch != 0 && epoch != old);
            reply(&format!(
                "{{\"restart\":true,\"epoch\":{epoch},\"frames\":0}}"
            ));
            continue;
        }
        let mut pose = side.state_snapshot().unwrap_or_default().head;
        if pose.valid == 0 {
            pose.valid = 1;
            pose.orientation = identity;
            pose.position = [0.0, 1.6, 0.0];
        }
        let red = vec![[255u8, 0, 0, 255]; 17 * 13].into_flattened();
        let green = vec![
            [
                0u8,
                if command == "premult" { 128 } else { 255 },
                0,
                if command == "quad-only" { 255 } else { 128 }
            ];
            17 * 13
        ]
        .into_flattened();
        let yellow = vec![[255u8, 255, 0, 255]; 17 * 13].into_flattened();
        let image = |pixels, position, eye_visibility, flags, order, anchor| PanelImage {
            pose: bridge::Pose {
                valid: 1,
                orientation: identity,
                position,
                ..pose
            },
            width_m: 4.0,
            height_m: 4.0,
            eye_visibility,
            flags,
            order,
            anchor,
            color_space: bridge::FRAME_COLOR_LINEAR,
            bgra: false,
            image_width: 17,
            image_height: 13,
            pixels,
        };
        let mut panels = Vec::new();
        let layered = matches!(
            command.as_str(),
            "layered"
                | "premult"
                | "stale"
                | "busy"
                | "batch-stale"
                | "batch-epoch"
                | "batch-missing"
        );
        if layered {
            panels.push(image(&red, [0.0, 1.6, -1.0], 0, 0, 0, 0));
            panels.push(image(
                &green,
                [0.0, 0.0, -0.9],
                1,
                if command == "premult" { 1 } else { 3 },
                2,
                1,
            ));
            panels.push(image(&yellow, [0.0, 0.0, -0.8], 2, 0, 3, 1));
        } else if command == "quad-only" {
            panels.push(image(&green, [0.0, 0.0, -0.9], 1, 0, 0, 1));
            panels.push(image(&yellow, [0.0, 0.0, -0.8], 2, 0, 1, 1));
        }
        let clear = command == "clear" || command == "empty-batch-stale";
        let projection = if clear || command == "quad-only" {
            None
        } else {
            Some(if layered { 1 } else { 0 })
        };
        let flags = if layered || command == "alpha-batch-stale" {
            3
        } else {
            0
        };
        side.see_through = layered;
        let geometry_command = command.starts_with("geometry-");
        let gradient = geometry_command || command == "gradient";
        let config = side.config();
        let matrix = bridge::math::pose_matrix(pose.position, pose.orientation);
        let mut geometry = geometry_command.then(|| {
            core::array::from_fn::<_, 2, _>(|eye| {
                let x = if eye == 0 { -0.5 } else { 0.5 } * config.ipd;
                bridge::projection::View {
                    position: core::array::from_fn(|axis| {
                        pose.position[axis] + matrix[axis][0] * x
                    }),
                    orientation: pose.orientation,
                    tangents: config.tangents[eye],
                }
            })
        });
        if let Some(views) = geometry.as_mut() {
            if command == "geometry-zoom" {
                for (eye, view) in views.iter_mut().enumerate() {
                    for tangent in &mut view.tangents {
                        *tangent *= if eye == 0 { 0.65 } else { 0.82 };
                    }
                    view.tangents[0] += 0.12;
                    view.tangents[1] += 0.12;
                }
            } else if command == "geometry-canted" {
                for (eye, view) in views.iter_mut().enumerate() {
                    let angle: f32 = if eye == 0 { 0.17 } else { -0.23 };
                    view.orientation = bridge::math::quat_mul(
                        pose.orientation,
                        [0.0, (angle / 2.0).sin(), 0.0, (angle / 2.0).cos()],
                    );
                }
            } else if command == "geometry-shift" {
                for (eye, view) in views.iter_mut().enumerate() {
                    view.position[0] += if eye == 0 { 0.08 } else { -0.06 };
                    view.position[1] -= 0.03;
                    view.position[2] += 0.05;
                }
            }
        }
        let before = map.header().client_frames.load(Ordering::SeqCst);
        if command == "busy" {
            map.header().overlay_pictures[0]
                .reading
                .store(1, Ordering::SeqCst);
        }
        let published = side.submit_layers_with_geometry(
            pose,
            (64, 64),
            false,
            false,
            6,
            [bridge::FRAME_COLOR_LINEAR; 2],
            projection,
            flags,
            geometry.as_ref(),
            &panels,
            |eye, pixels| {
                let color = if clear || command == "quad-only" {
                    [0u8; 4]
                } else if layered {
                    [0u8, 0, 255, 128]
                } else if eye == 0 {
                    [10u8, 20, 200, 255]
                } else {
                    [0u8, 200, 200, 255]
                };
                for (index, pixel) in pixels.chunks_exact_mut(4).enumerate() {
                    if gradient {
                        pixel.copy_from_slice(&[
                            ((index % 64) as f32 * 255.0 / 63.0).round() as u8,
                            ((index / 64) as f32 * 255.0 / 63.0).round() as u8,
                            if eye == 0 { 160 } else { 80 },
                            255,
                        ]);
                    } else {
                        pixel.copy_from_slice(&color);
                    }
                }
            },
        );
        if command == "busy" {
            map.header().overlay_pictures[0]
                .reading
                .store(0, Ordering::SeqCst);
        }
        if command == "stale" && published {
            if std::env::var_os("HALLIDAY_PANEL_FIXTURE_TORN_BATCH").is_some() {
                let slot = map.header().latest.load(Ordering::SeqCst) as usize - 1;
                let sequence = unsafe {
                    &*map
                        .0
                        .cast::<u8>()
                        .add(bridge::panels::OFFSET + 16 + slot * 864)
                        .cast::<core::sync::atomic::AtomicU32>()
                };
                sequence.fetch_or(1, Ordering::SeqCst);
            } else {
                map.header().overlay_pictures[0]
                    .seq
                    .fetch_add(2, Ordering::SeqCst);
            }
        }
        if command == "geometry-stale" && published {
            let slot = map.header().latest.load(Ordering::SeqCst) as usize - 1;
            let sequence = unsafe {
                &*map
                    .0
                    .cast::<u8>()
                    .add(bridge::projection::OFFSET + 16 + slot * 112)
                    .cast::<core::sync::atomic::AtomicU32>()
            };
            sequence.fetch_or(1, Ordering::SeqCst);
        }
        if published
            && matches!(
                command.as_str(),
                "batch-stale"
                    | "empty-batch-stale"
                    | "alpha-batch-stale"
                    | "batch-epoch"
                    | "batch-missing"
                    | "batch-legacy"
            )
        {
            let slot = map.header().latest.load(Ordering::SeqCst) as usize - 1;
            let base = unsafe {
                map.0
                    .cast::<u8>()
                    .add(bridge::panels::OFFSET + 16 + slot * 864)
            };
            if command == "batch-epoch" {
                unsafe { &*base.add(16).cast::<core::sync::atomic::AtomicU64>() }
                    .fetch_add(1, Ordering::SeqCst);
            } else if command == "batch-missing" || command == "batch-legacy" {
                unsafe {
                    map.0
                        .cast::<u8>()
                        .add(bridge::panels::OFFSET)
                        .cast::<u32>()
                        .write_volatile(0)
                };
                restore_batch_capability = true;
            } else {
                unsafe { &*base.cast::<core::sync::atomic::AtomicU32>() }
                    .fetch_or(1, Ordering::SeqCst);
            }
        }
        let after = map.header().client_frames.load(Ordering::SeqCst);
        assert!(if command == "busy" {
            !published && before == after
        } else {
            published && after == before + 1
        });
        reply(&format!(
            "{{\"published\":{published},\"epoch\":{epoch},\"before\":{before},\"frames\":{after}}}"
        ));
    }
    side.end_haptics(epoch);
    side.unregister_client();
    reply("{\"closed\":true}");
}
