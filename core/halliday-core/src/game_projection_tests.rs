use super::*;
use bridge::projection::{self, View};

fn fixture() -> (GameBridge, GameSide, u64) {
    let path = std::env::temp_dir().join(format!(
        "halliday-projection-{}-{}.shm",
        std::process::id(),
        crate::time::host_time_ns()
    ));
    let host = GameBridge::create(
        &path,
        Config {
            eye_width: 8,
            eye_height: 8,
            display_hz: 72.0,
            ipd: 0.064,
            tangents: [[-1., 1., 1., -1.]; 2],
        },
    )
    .unwrap();
    let game = GameSide::view(&path).unwrap();
    assert!(game.register_client_as("projection fixture"));
    let epoch = game.begin_haptics();
    (host, game, epoch)
}
fn views() -> [View; 2] {
    [
        View {
            position: [-0.04, 1.6, -0.02],
            orientation: [0., 0.1, 0., 0.9949874],
            tangents: [-1.2, 0.9, 1.1, -0.8],
        },
        View {
            position: [0.035, 1.61, 0.01],
            orientation: [0.05, 0., 0., 0.9987492],
            tangents: [-0.7, 1.3, 1.2, -0.9],
        },
    ]
}
fn submit(game: &mut GameSide, geometry: Option<&[View; 2]>) -> bool {
    game.submit_layers_with_geometry(
        Default::default(),
        (8, 8),
        false,
        true,
        4,
        [1, 2],
        Some(0),
        0,
        geometry,
        &[],
        |eye, p| p.fill(if eye == 0 { 17 } else { 34 }),
    )
}

#[test]
fn projection_geometry_matches_exact_frame_pixels_and_respects_reader_slot() {
    let (host, mut game, epoch) = fixture();
    let expected = views();
    assert!(game.has_projection_geometry());
    assert!(submit(&mut game, Some(&expected)));
    let first = host.begin_read().unwrap();
    let snapshot = host
        .projection_geometry(first.slot, first.frame_index)
        .unwrap()
        .unwrap();
    assert_eq!(
        (snapshot.epoch, snapshot.frame_index, snapshot.views),
        (epoch, first.frame_index, expected)
    );
    assert_eq!(host.frame_color_space(first.slot, 0), 1);
    assert_eq!(host.frame_color_space(first.slot, 1), 2);
    assert_eq!(
        unsafe { (*host.header()).frames[first.slot].texture_type } & 0xff,
        4
    );
    let mut replacement = expected;
    replacement[0].position[0] -= 0.02;
    replacement[1].tangents[2] = 1.4;
    assert!(submit(&mut game, Some(&replacement)));
    assert_eq!(
        host.projection_geometry(first.slot, first.frame_index)
            .unwrap()
            .unwrap(),
        snapshot,
        "busy read slot retains its exact geometry"
    );
    assert_eq!(
        unsafe { *host.base().add(first.offsets[0]) },
        17,
        "busy frame pixels remain intact"
    );
    host.end_read();
    let latest = host.begin_read().unwrap();
    assert_ne!(latest.slot, first.slot);
    assert_eq!(
        host.projection_geometry(latest.slot, latest.frame_index)
            .unwrap()
            .unwrap()
            .views,
        replacement
    );
    assert!(
        host.projection_geometry(latest.slot, first.frame_index)
            .is_err(),
        "cannot reuse a newer slot record for an older frame"
    );
    game.end_haptics(epoch);
    assert!(
        host.projection_geometry(latest.slot, latest.frame_index)
            .is_err(),
        "retired producer invalidates flagged geometry"
    );
    host.end_read();
}

#[test]
fn flagged_projection_rejects_odd_stale_invalid_and_missing_metadata_without_legacy_fallback() {
    let (host, mut game, epoch) = fixture();
    let expected = views();
    assert!(submit(&mut game, Some(&expected)));
    let frame = host.begin_read().unwrap();
    let extension = unsafe { projection::extension(host.header()) };
    let record = &extension.records[frame.slot];
    let sequence = record.sequence.load(Ordering::SeqCst);
    record.sequence.store(sequence | 1, Ordering::SeqCst);
    assert!(
        host.projection_geometry(frame.slot, frame.frame_index)
            .is_err()
    );
    record.sequence.store(sequence, Ordering::SeqCst);
    record.epoch.store(epoch + 1, Ordering::SeqCst);
    assert!(
        host.projection_geometry(frame.slot, frame.frame_index)
            .is_err()
    );
    record.epoch.store(epoch, Ordering::SeqCst);
    record
        .frame_index
        .store(frame.frame_index + 1, Ordering::SeqCst);
    assert!(
        host.projection_geometry(frame.slot, frame.frame_index)
            .is_err()
    );
    record
        .frame_index
        .store(frame.frame_index, Ordering::SeqCst);
    record.flags.store(3, Ordering::SeqCst);
    assert!(
        host.projection_geometry(frame.slot, frame.frame_index)
            .is_err()
    );
    record.flags.store(projection::VALID, Ordering::SeqCst);
    let original = record.views[1][0].load(Ordering::SeqCst);
    record.views[1][0].store(f32::NAN.to_bits(), Ordering::SeqCst);
    assert!(
        host.projection_geometry(frame.slot, frame.frame_index)
            .is_err()
    );
    record.views[1][0].store(original, Ordering::SeqCst);
    let pointer = unsafe {
        host.header()
            .cast::<u8>()
            .add(projection::OFFSET)
            .cast::<projection::Extension>()
    };
    unsafe { (*pointer).record_bytes = 111 };
    assert!(!game.has_projection_geometry());
    assert!(
        host.projection_geometry(frame.slot, frame.frame_index)
            .is_err()
    );
    unsafe {
        (*pointer).record_bytes = 112;
        (*pointer).magic = 0
    };
    assert!(
        host.projection_geometry(frame.slot, frame.frame_index)
            .is_err()
    );
    host.end_read();
    assert!(
        !submit(&mut game, Some(&expected)),
        "old host cannot receive a geometry-dependent frame"
    );
    assert!(
        submit(&mut game, None),
        "legacy frame remains usable without the optional capability"
    );
    let old = host.begin_read().unwrap();
    assert_eq!(
        host.projection_geometry(old.slot, old.frame_index),
        Ok(None)
    );
    host.end_read();
    unsafe { (*pointer).magic = projection::MAGIC };
    assert!(submit(&mut game, None));
    let legacy = host.begin_read().unwrap();
    extension.records[legacy.slot]
        .sequence
        .store(1, Ordering::SeqCst);
    assert_eq!(
        host.projection_geometry(legacy.slot, legacy.frame_index),
        Ok(None),
        "unflagged legacy frame ignores stale or busy slot metadata"
    );
    host.end_read();
}

#[test]
fn invalid_projection_is_rejected_before_pixels_and_incomplete_publication_never_becomes_latest() {
    let (host, mut game, epoch) = fixture();
    let mut expected = views();
    expected[1].tangents[1] = expected[1].tangents[0];
    assert!(!game.submit_layers_with_geometry(
        Default::default(),
        (8, 8),
        false,
        false,
        4,
        [1, 1],
        Some(0),
        0,
        Some(&expected),
        &[],
        |_, _| panic!("invalid geometry must not invoke pixel transfer")
    ));
    assert_eq!(host.client().frames, 0);
    expected = views();
    assert!(submit(&mut game, Some(&expected)));
    let first = host.begin_read().unwrap();
    let latest = unsafe { &*host.header() }.latest.load(Ordering::SeqCst);
    let control = unsafe { bridge::haptics::extension(host.header()) };
    assert!(!game.submit_layers_with_geometry(
        Default::default(),
        (8, 8),
        false,
        false,
        4,
        [1, 1],
        Some(0),
        0,
        Some(&expected),
        &[],
        |_, p| {
            p.fill(71);
            control.client_epoch.store(0, Ordering::SeqCst);
        }
    ));
    assert_eq!(
        unsafe { &*host.header() }.latest.load(Ordering::SeqCst),
        latest
    );
    assert_eq!(host.client().frames, 1);
    assert_eq!(unsafe { *host.base().add(first.offsets[0]) }, 17);
    control.client_epoch.store(epoch, Ordering::SeqCst);
    host.end_read();
    assert!(
        submit(&mut game, Some(&expected)),
        "complete frame recovers after a failed epoch check"
    );
}

#[test]
fn projection_sequence_and_frame_counter_wrap_keep_nonzero_complete_tags() {
    let (host, mut game, _) = fixture();
    let extension = unsafe { projection::extension(host.header()) };
    for record in &extension.records {
        record.sequence.store(u32::MAX - 1, Ordering::SeqCst);
    }
    game.frame_index = u64::MAX;
    assert!(submit(&mut game, Some(&views())));
    let frame = host.begin_read().unwrap();
    assert_eq!(frame.frame_index, 1);
    assert_eq!(
        extension.records[frame.slot]
            .sequence
            .load(Ordering::SeqCst),
        2
    );
    assert!(
        host.projection_geometry(frame.slot, frame.frame_index)
            .unwrap()
            .is_some()
    );
    host.end_read();
}

#[test]
fn projection_view_validation_accepts_offaxis_frusta_and_rejects_nonfinite_or_degenerate_input() {
    let mut view = views()[0];
    view.tangents = [0.1, 0.6, 0.8, 0.2];
    assert!(view.valid(), "off-axis FOV need not straddle zero");
    view.orientation = [0.; 4];
    assert!(!view.valid());
    view = views()[0];
    view.position[2] = f32::INFINITY;
    assert!(!view.valid());
    view = views()[0];
    view.tangents = [-f32::MAX, f32::MAX, 1., -1.];
    assert!(
        !view.valid(),
        "finite endpoints must also produce finite spans"
    );
    view = views()[0];
    view.tangents[2] = view.tangents[3];
    assert!(!view.valid());
}

#[test]
fn projection_c_api_distinguishes_valid_invalid_and_legacy_without_stale_output() {
    use crate::ffi;
    struct Host(*mut ffi::HallidayGameBridge);
    impl Drop for Host {
        fn drop(&mut self) {
            unsafe { ffi::halliday_bridge_close(self.0) }
        }
    }
    let path = std::env::temp_dir().join(format!(
        "halliday-projection-capi-{}-{}.shm",
        std::process::id(),
        crate::time::host_time_ns()
    ));
    let cpath = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
    let config = ffi::HallidayBridgeConfig {
        eye_width: 8,
        eye_height: 8,
        display_hz: 72.,
        ipd: 0.064,
        tangents: [[-1., 1., 1., -1.]; 2],
    };
    let host = Host(unsafe { ffi::halliday_bridge_open(cpath.as_ptr(), &config) });
    assert!(!host.0.is_null());
    let mut game = GameSide::view(&path).unwrap();
    assert!(game.register_client_as("projection C ABI"));
    game.begin_haptics();
    assert!(submit(&mut game, Some(&views())));
    let mut frame: ffi::HallidayBridgeFrame = unsafe { std::mem::zeroed() };
    assert!(unsafe { ffi::halliday_bridge_begin_read(host.0, &mut frame) });
    let mut output = ffi::HallidayBridgeProjectionGeometry::default();
    assert_eq!(
        unsafe {
            ffi::halliday_bridge_projection_geometry(
                host.0,
                frame.slot,
                frame.frame_index,
                &mut output,
            )
        },
        1
    );
    assert_eq!(output.views, views());
    let header = unsafe { ffi::halliday_bridge_base(host.0) }.cast::<Header>();
    unsafe { projection::extension(header) }.records[frame.slot as usize]
        .sequence
        .store(1, Ordering::SeqCst);
    assert_eq!(
        unsafe {
            ffi::halliday_bridge_projection_geometry(
                host.0,
                frame.slot,
                frame.frame_index,
                &mut output,
            )
        },
        -1
    );
    assert_eq!(output, Default::default());
    unsafe {
        (*header).frames[frame.slot as usize].texture_type &= !bridge::FRAME_PROJECTION_GEOMETRY
    };
    assert_eq!(
        unsafe {
            ffi::halliday_bridge_projection_geometry(
                host.0,
                frame.slot,
                frame.frame_index,
                &mut output,
            )
        },
        0
    );
    assert_eq!(output, Default::default());
    output.epoch = 99;
    assert_eq!(
        unsafe {
            ffi::halliday_bridge_projection_geometry(
                std::ptr::null(),
                frame.slot,
                frame.frame_index,
                &mut output,
            )
        },
        -1
    );
    assert_eq!(output, Default::default());
    unsafe { ffi::halliday_bridge_end_read(host.0) };
}
