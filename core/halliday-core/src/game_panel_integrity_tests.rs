use super::*;
use core::sync::atomic::{AtomicU32, AtomicU64};

fn fixture() -> (GameBridge, GameSide) {
    let path = std::env::temp_dir().join(format!(
        "halliday-panel-integrity-{}-{}.shm",
        std::process::id(),
        crate::time::host_time_ns()
    ));
    let host = GameBridge::create(
        &path,
        Config {
            eye_width: 8,
            eye_height: 8,
            display_hz: 72.,
            ipd: 0.064,
            tangents: [[-1., 1., 1., -1.]; 2],
        },
    )
    .unwrap();
    let game = GameSide::view(&path).unwrap();
    assert!(game.register_client_as("panel integrity"));
    game.begin_haptics();
    (host, game)
}
fn panel(pixels: &[u8]) -> PanelImage<'_> {
    PanelImage {
        pose: bridge::Pose {
            orientation: [0., 0., 0., 1.],
            valid: 1,
            ..Default::default()
        },
        width_m: 1.,
        height_m: 1.,
        eye_visibility: 0,
        flags: 0,
        order: 1,
        pixels,
        image_width: 8,
        image_height: 8,
        color_space: 1,
        bgra: false,
        anchor: 0,
    }
}
fn batch_word(host: &GameBridge, slot: usize, offset: usize) -> *mut u8 {
    unsafe {
        host.header()
            .cast::<u8>()
            .add(bridge::panels::OFFSET + 16 + slot * 864 + offset)
    }
}
#[test]
fn semantic_batches_never_fall_back_when_metadata_is_torn_stale_or_absent() {
    let (host, mut game) = fixture();
    let pixels = vec![17u8; 8 * 8 * 4];
    for kind in 0..3 {
        let panels = if kind == 0 {
            vec![panel(&pixels)]
        } else {
            vec![]
        };
        let order = if kind == 1 { None } else { Some(0) };
        let flags = if kind == 2 { 3 } else { 0 };
        assert!(game.submit_layers_with_metadata(
            Default::default(),
            (8, 8),
            false,
            false,
            4,
            [1, 1],
            order,
            flags,
            &panels,
            |_, p| p.fill(19)
        ));
        let frame = host.begin_read().unwrap();
        assert_ne!(
            unsafe { (*host.header()).frames[frame.slot].texture_type } & bridge::FRAME_LAYER_BATCH,
            0
        );
        assert!(
            host.checked_panels(frame.slot, frame.frame_index)
                .unwrap()
                .is_some()
        );
        let seq = unsafe { &*batch_word(&host, frame.slot, 0).cast::<AtomicU32>() };
        let saved = seq.load(Ordering::SeqCst);
        seq.store(saved | 1, Ordering::SeqCst);
        assert!(host.checked_panels(frame.slot, frame.frame_index).is_err());
        seq.store(saved, Ordering::SeqCst);
        for offset in [8, 16] {
            let word = unsafe { &*batch_word(&host, frame.slot, offset).cast::<AtomicU64>() };
            let old = word.load(Ordering::SeqCst);
            word.store(old + 1, Ordering::SeqCst);
            assert!(host.checked_panels(frame.slot, frame.frame_index).is_err());
            word.store(old, Ordering::SeqCst);
        }
        let magic = unsafe {
            host.header()
                .cast::<u8>()
                .add(bridge::panels::OFFSET)
                .cast::<u32>()
        };
        unsafe { magic.write(0) };
        assert!(host.checked_panels(frame.slot, frame.frame_index).is_err());
        unsafe { magic.write(bridge::panels::MAGIC) };
        assert!(
            host.checked_panels(frame.slot, frame.frame_index)
                .unwrap()
                .is_some()
        );
        host.end_read();
        assert!(host.checked_panels(frame.slot, frame.frame_index).is_err());
    }
}
#[test]
fn missing_layer_capability_rejects_semantic_frames_before_pixel_transfer_but_preserves_legacy_projection()
 {
    let (host, mut game) = fixture();
    let pixels = vec![17u8; 8 * 8 * 4];
    let magic = unsafe {
        host.header()
            .cast::<u8>()
            .add(bridge::panels::OFFSET)
            .cast::<u32>()
    };
    unsafe { magic.write(0) };
    for kind in [0, 2] {
        let panels = if kind == 0 {
            vec![panel(&pixels)]
        } else {
            vec![]
        };
        assert!(!game.submit_layers_with_metadata(
            Default::default(),
            (8, 8),
            false,
            false,
            4,
            [1, 1],
            if kind == 1 { None } else { Some(0) },
            if kind == 2 { 3 } else { 0 },
            &panels,
            |_, _| panic!("unsupported composition must reject before transfer")
        ));
    }
    assert_eq!(host.client().frames, 0);
    assert!(game.submit_layers_with_metadata(
        Default::default(),
        (8, 8),
        false,
        false,
        4,
        [1, 1],
        Some(0),
        0,
        &[],
        |_, p| p.fill(23)
    ));
    let frame = host.begin_read().unwrap();
    assert!(matches!(
        host.checked_panels(frame.slot, frame.frame_index),
        Ok(None)
    ));
    assert_eq!(unsafe { *host.base().add(frame.offsets[0]) }, 23);
    host.end_read();
    assert!(
        game.submit_layers_with_metadata(
            Default::default(),
            (8, 8),
            false,
            false,
            4,
            [1, 1],
            None,
            0,
            &[],
            |_, p| p.fill(0)
        ),
        "old opaque host can represent an empty frame as black"
    );
    let empty = host.begin_read().unwrap();
    assert!(matches!(
        host.checked_panels(empty.slot, empty.frame_index),
        Ok(None)
    ));
    assert_eq!(unsafe { *host.base().add(empty.offsets[0]) }, 0);
    host.end_read();
}
#[test]
fn batch_sequence_wrap_keeps_a_nonzero_complete_publication() {
    let (host, mut game) = fixture();
    for slot in 0..bridge::SLOTS {
        unsafe { &*batch_word(&host, slot, 0).cast::<AtomicU32>() }
            .store(u32::MAX - 1, Ordering::SeqCst);
    }
    assert!(game.submit_layers_with_metadata(
        Default::default(),
        (8, 8),
        false,
        false,
        4,
        [1, 1],
        None,
        0,
        &[],
        |_, p| p.fill(0)
    ));
    let frame = host.begin_read().unwrap();
    assert!(
        host.checked_panels(frame.slot, frame.frame_index)
            .unwrap()
            .is_some()
    );
    assert_eq!(
        unsafe { &*batch_word(&host, frame.slot, 0).cast::<AtomicU32>() }.load(Ordering::SeqCst),
        2
    );
    host.end_read();
}

#[test]
fn c_api_distinguishes_required_failure_from_optional_legacy_and_clears_output() {
    use crate::ffi;
    let path = std::env::temp_dir().join(format!(
        "halliday-panel-capi-{}-{}.shm",
        std::process::id(),
        crate::time::host_time_ns()
    ));
    let name = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
    let config = ffi::HallidayBridgeConfig {
        eye_width: 8,
        eye_height: 8,
        display_hz: 72.,
        ipd: 0.064,
        tangents: [[-1., 1., 1., -1.]; 2],
    };
    let host = unsafe { ffi::halliday_bridge_open(name.as_ptr(), &config) };
    assert!(!host.is_null());
    let mut game = GameSide::view(&path).unwrap();
    assert!(game.register_client_as("panel C ABI"));
    game.begin_haptics();
    assert!(game.submit_layers_with_metadata(
        Default::default(),
        (8, 8),
        false,
        false,
        4,
        [1, 1],
        None,
        0,
        &[],
        |_, p| p.fill(0)
    ));
    let mut frame: ffi::HallidayBridgeFrame = unsafe { std::mem::zeroed() };
    assert!(unsafe { ffi::halliday_bridge_begin_read(host, &mut frame) });
    let mut batch: ffi::HallidayBridgePanelBatch = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe {
            ffi::halliday_bridge_layer_batch(
                host,
                frame.slot,
                frame.frame_index,
                &mut batch,
                std::ptr::null_mut(),
                0,
            )
        },
        1
    );
    assert_eq!(batch.projection_order, bridge::panels::NONE);
    let header = unsafe { ffi::halliday_bridge_base(host) }.cast::<Header>();
    let sequence = unsafe {
        &*header
            .cast::<u8>()
            .add(bridge::panels::OFFSET + 16 + frame.slot as usize * 864)
            .cast::<AtomicU32>()
    };
    sequence.store(1, Ordering::SeqCst);
    assert_eq!(
        unsafe {
            ffi::halliday_bridge_layer_batch(
                host,
                frame.slot,
                frame.frame_index,
                &mut batch,
                std::ptr::null_mut(),
                0,
            )
        },
        -1
    );
    assert_eq!(
        (
            batch.epoch,
            batch.frame_index,
            batch.count,
            batch.projection_order
        ),
        (0, 0, 0, 0)
    );
    unsafe { (*header).frames[frame.slot as usize].texture_type &= !bridge::FRAME_LAYER_BATCH };
    assert_eq!(
        unsafe {
            ffi::halliday_bridge_layer_batch(
                host,
                frame.slot,
                frame.frame_index,
                &mut batch,
                std::ptr::null_mut(),
                0,
            )
        },
        0
    );
    batch.epoch = 99;
    assert_eq!(
        unsafe {
            ffi::halliday_bridge_layer_batch(
                std::ptr::null(),
                frame.slot,
                frame.frame_index,
                &mut batch,
                std::ptr::null_mut(),
                0,
            )
        },
        -1
    );
    assert_eq!(batch.epoch, 0);
    unsafe {
        ffi::halliday_bridge_end_read(host);
        ffi::halliday_bridge_close(host)
    };
}
