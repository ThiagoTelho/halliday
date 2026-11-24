use super::*;

fn config() -> Config {
    Config {
        eye_width: 8,
        eye_height: 8,
        display_hz: 72.,
        ipd: 0.064,
        tangents: [[-1., 1., 1., -1.]; 2],
    }
}
#[test]
fn retirement_removes_readiness_and_path_before_a_retained_reader_mapping_is_released() {
    let path = std::env::temp_dir().join(format!(
        "halliday-retire-{}-{}.shm",
        std::process::id(),
        crate::time::host_time_ns()
    ));
    let old = GameBridge::create(&path, config()).unwrap();
    let mut reader = GameSide::view(&path).unwrap();
    reader.submit(Default::default(), |_, pixels| pixels.fill(91));
    let frame = old.begin_read().unwrap();
    old.retire();
    old.retire();
    assert!(
        !path.exists(),
        "pending copy must not keep a stale public host alive"
    );
    assert!(
        !reader.halliday_alive(),
        "already mapped clients see host loss immediately"
    );
    assert_eq!(
        unsafe { *old.base().add(frame.offsets[0]) },
        91,
        "pending GPU read still owns valid old pixels"
    );
    let replacement = GameBridge::create(&path, config()).unwrap();
    let fresh = GameSide::view(&path).unwrap();
    old.retire();
    assert!(
        path.exists(),
        "repeated retirement cannot remove a replacement"
    );
    old.end_read();
    drop(old);
    assert!(
        path.exists() && fresh.halliday_alive(),
        "late final lease release must preserve replacement"
    );
    assert!(!reader.halliday_alive());
    drop(replacement);
    assert!(!path.exists());
}

#[test]
fn retirement_c_abi_preserves_handle_for_gpu_completion_and_never_revives_host() {
    use crate::ffi;
    let path = std::env::temp_dir().join(format!(
        "halliday-retire-capi-{}-{}.shm",
        std::process::id(),
        crate::time::host_time_ns()
    ));
    let name = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
    let c = config();
    let config = ffi::HallidayBridgeConfig {
        eye_width: c.eye_width,
        eye_height: c.eye_height,
        display_hz: c.display_hz,
        ipd: c.ipd,
        tangents: c.tangents,
    };
    let host = unsafe { ffi::halliday_bridge_open(name.as_ptr(), &config) };
    assert!(!host.is_null());
    let game = GameSide::view(&path).unwrap();
    let base = unsafe { ffi::halliday_bridge_base(host) };
    unsafe {
        ffi::halliday_bridge_retire(host);
        ffi::halliday_bridge_retire(host);
        ffi::halliday_bridge_retire(std::ptr::null())
    };
    assert!(!path.exists() && !game.halliday_alive());
    assert_eq!(
        unsafe { ffi::halliday_bridge_base(host) },
        base,
        "retirement is not unmapping"
    );
    let state = State::default();
    unsafe {
        ffi::halliday_bridge_publish(host, &state);
        ffi::halliday_bridge_end_read(host)
    };
    assert!(
        !game.halliday_alive(),
        "late state/copy completion cannot revive a retired host"
    );
    unsafe { ffi::halliday_bridge_close(host) };
    assert!(!path.exists());
}

#[test]
fn stale_producer_replacement_isolated_from_old_session_writes_and_teardown() {
    let path = std::env::temp_dir().join(format!(
        "halliday-stale-lease-{}-{}.shm",
        std::process::id(),
        crate::time::host_time_ns()
    ));
    let old = GameBridge::create(&path, config()).unwrap();
    let mut old_game = GameSide::view(&path).unwrap();
    assert!(old_game.register_client_as("crashed producer"));
    let old_epoch = old_game.begin_haptics();
    old_game.submit(Default::default(), |_, pixels| pixels.fill(91));
    let held = old.begin_read().unwrap();
    assert_eq!(old.client_status(), 1);

    // Host retirement is not shared ownership theft. A delayed producer and
    // GPU reader retain their old inode; the replacement starts unowned.
    old.retire();
    let fresh = GameBridge::create(&path, config()).unwrap();
    assert_eq!(fresh.client_status(), 0);
    let new_game = GameSide::view(&path).unwrap();
    assert!(new_game.register_client_as("next producer"));
    let new_epoch = new_game.begin_haptics();
    assert_ne!(old_epoch, new_epoch);
    let before = fresh.client();

    // These can arrive after publication of the next session, even with the
    // same process ID. None may clear/change its ownership or haptic epoch.
    old_game.submit(Default::default(), |_, pixels| pixels.fill(17));
    old_game.end_haptics(old_epoch);
    old_game.unregister_client();
    old.end_read();
    old.retire();
    assert_eq!(fresh.client(), before);
    assert_eq!(fresh.client_epoch(), new_epoch);
    assert_eq!(fresh.client_status(), 1);
    assert!(new_game.halliday_alive());
    assert_eq!(
        unsafe { *old.base().add(held.offsets[0]) },
        91,
        "retired reader's claimed slot remains valid"
    );
    drop(old);
    assert!(
        path.exists(),
        "late old GPU lease release cannot unlink the new host"
    );
    new_game.unregister_client();
    drop(fresh);
    assert!(!path.exists());
}
