use super::*;
use bridge::frame_timing::{self, Time, XR_DISPLAY_TIME_NS};
fn fixture() -> (GameBridge, GameSide, u64) {
    let path = std::env::temp_dir().join(format!(
        "halliday-timing-{}-{}.shm",
        std::process::id(),
        crate::time::host_time_ns()
    ));
    let host = GameBridge::create(
        &path,
        Config {
            eye_width: 8,
            eye_height: 8,
            display_hz: 60.,
            ipd: 0.064,
            tangents: [[-1., 1., 1., -1.]; 2],
        },
    )
    .unwrap();
    let game = GameSide::view(&path).unwrap();
    assert!(game.register_client_as("source timing fixture"));
    let epoch = game.begin_haptics();
    assert_ne!(epoch, 0);
    (host, game, epoch)
}
fn submit(game: &mut GameSide, time: Option<Time>, value: u8) -> bool {
    game.submit_layers_with_geometry_and_timing(
        Default::default(),
        (8, 8),
        false,
        true,
        6,
        [1, 2],
        Some(0),
        0,
        None,
        time,
        &[],
        |_, p| p.fill(value),
    )
}
#[test]
fn frame_timing_matches_held_pixels_despite_delayed_and_bunched_import() {
    let (host, mut game, epoch) = fixture();
    let t = Time {
        nanoseconds: 1_000_000_000,
        clock_kind: XR_DISPLAY_TIME_NS,
    };
    assert!(submit(&mut game, Some(t), 17));
    let first = host.begin_read().unwrap();
    let a = host
        .frame_timing(first.slot, first.frame_index)
        .unwrap()
        .unwrap();
    assert_eq!(a.epoch, epoch);
    assert!(submit(
        &mut game,
        Some(Time {
            nanoseconds: t.nanoseconds + 23_255_814,
            ..t
        }),
        34
    ));
    assert_eq!(
        host.frame_timing(first.slot, first.frame_index)
            .unwrap()
            .unwrap(),
        a
    );
    assert_eq!(unsafe { *host.base().add(first.offsets[0]) }, 17);
    host.end_read();
    let next = host.begin_read().unwrap();
    let b = host
        .frame_timing(next.slot, next.frame_index)
        .unwrap()
        .unwrap();
    assert_eq!(b.nanoseconds - a.nanoseconds, 23_255_814);
    assert_eq!(unsafe { *host.base().add(next.offsets[0]) }, 34);
    host.end_read();
    assert!(
        host.frame_timing(next.slot, next.frame_index).is_err(),
        "released pixel lease cannot fetch timing"
    );
}
#[test]
fn frame_timing_invalid_metadata_never_rejects_real_pixels_or_leaks_to_legacy() {
    let (host, mut game, epoch) = fixture();
    let t = Time {
        nanoseconds: 123,
        clock_kind: XR_DISPLAY_TIME_NS,
    };
    assert!(submit(&mut game, Some(t), 9));
    let f = host.begin_read().unwrap();
    let e = unsafe { frame_timing::extension(host.header()) };
    let r = &e.entries[f.slot];
    r.epoch.store(epoch + 1, Ordering::SeqCst);
    assert!(host.frame_timing(f.slot, f.frame_index).is_err());
    assert_eq!(unsafe { *host.base().add(f.offsets[0]) }, 9);
    r.epoch.store(epoch, Ordering::SeqCst);
    r.sequence.fetch_or(1, Ordering::SeqCst);
    assert!(host.frame_timing(f.slot, f.frame_index).is_err());
    host.end_read();
    for time in [
        None,
        Some(Time {
            nanoseconds: 0,
            ..t
        }),
        Some(Time {
            clock_kind: 99,
            ..t
        }),
    ] {
        assert!(submit(&mut game, time, 31));
        let f = host.begin_read().unwrap();
        assert_eq!(host.frame_timing(f.slot, f.frame_index), Ok(None));
        assert_eq!(unsafe { *host.base().add(f.offsets[0]) }, 31);
        host.end_read();
    }
}
#[test]
fn present_frame_timing_requires_exact_ring_number_index_and_current_epoch() {
    let (host, game, epoch) = fixture();
    let h = host.header();
    let e = unsafe { frame_timing::extension(h) };
    let info = bridge::PresentInfo {
        number: 4,
        eye_width: 8,
        eye_height: 8,
        flipped: false,
        frame_index: 7,
        texture_type: bridge::FRAME_SOURCE_TIMING,
        pose: Default::default(),
    };
    assert!(e.write(
        frame_timing::present_index(info.number),
        epoch,
        7,
        Time {
            nanoseconds: 555,
            clock_kind: 2
        }
    ));
    unsafe { bridge::write_present_frame(h, &info) };
    assert_eq!(
        host.present_frame_timing(4, 7)
            .unwrap()
            .unwrap()
            .nanoseconds,
        555
    );
    assert!(host.present_frame_timing(4, 8).is_err());
    let replacement = bridge::PresentInfo {
        number: 20,
        frame_index: 8,
        ..info
    };
    unsafe { bridge::write_present_frame(h, &replacement) };
    assert!(host.present_frame_timing(4, 7).is_err());
    game.end_haptics(epoch);
    assert!(host.present_frame_timing(20, 8).is_err());
}
#[test]
fn frame_timing_absent_old_host_and_c_abi_nulls_are_explicit() {
    let (host, mut game, _) = fixture();
    let ptr = unsafe {
        host.header()
            .cast::<u8>()
            .add(frame_timing::OFFSET)
            .cast::<frame_timing::Extension>()
    };
    unsafe {
        (*ptr).magic = 0;
    }
    assert!(submit(
        &mut game,
        Some(Time {
            nanoseconds: 999,
            clock_kind: XR_DISPLAY_TIME_NS
        }),
        45
    ));
    let frame = host.begin_read().unwrap();
    assert_eq!(host.frame_timing(frame.slot, frame.frame_index), Ok(None));
    assert_eq!(unsafe { *host.base().add(frame.offsets[0]) }, 45);
    host.end_read();
    let mut out = frame_timing::Snapshot {
        epoch: 99,
        frame_index: 99,
        nanoseconds: 99,
        clock_kind: 99,
        reserved: 99,
    };
    assert_eq!(
        unsafe { crate::ffi::halliday_bridge_frame_timing(std::ptr::null(), 0, 1, &mut out) },
        -1
    );
    assert_eq!(out, Default::default());
    out.epoch = 99;
    assert_eq!(
        unsafe {
            crate::ffi::halliday_bridge_present_frame_timing(std::ptr::null(), 1, 1, &mut out)
        },
        -1
    );
    assert_eq!(out, Default::default());
    assert_eq!(
        unsafe {
            crate::ffi::halliday_bridge_frame_timing(std::ptr::null(), 0, 1, std::ptr::null_mut())
        },
        -1
    );
}
