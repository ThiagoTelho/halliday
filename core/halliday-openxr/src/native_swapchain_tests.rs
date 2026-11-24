use super::*;

fn fake_chain(static_image: bool) -> xr::Swapchain {
    with(|r| {
        r.session.as_mut().unwrap().swapchains.insert(
            0x900,
            Swapchain {
                width: 8,
                height: 8,
                layers: 1,
                vulkan: false,
                bgra: false,
                transfer: bridge::FRAME_COLOR_LINEAR,
                textures: vec![std::ptr::null_mut(); if static_image { 1 } else { 3 }],
                next: 0,
                acquired: Default::default(),
                waited: false,
                static_image,
                static_acquired: false,
                released: None,
            },
        );
    });
    xr::Swapchain::from_raw(0x900)
}

fn wait(chain: xr::Swapchain) -> xr::Result {
    let info = xr::SwapchainImageWaitInfo {
        ty: xr::SwapchainImageWaitInfo::TYPE,
        next: std::ptr::null(),
        timeout: xr::Duration::from_nanos(0),
    };
    unsafe { wait_swapchain_image(chain, &info) }
}

#[test]
fn dynamic_image_fifo_requires_wait_then_release_and_recovers() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _f = Fixture::new();
    let chain = fake_chain(false);
    let mut index = 99;
    for expected in 0..3 {
        assert_eq!(
            unsafe { acquire_swapchain_image(chain, std::ptr::null(), &mut index) },
            xr::Result::SUCCESS
        );
        assert_eq!(index, expected);
    }
    assert_eq!(
        unsafe { acquire_swapchain_image(chain, std::ptr::null(), &mut index) },
        xr::Result::ERROR_CALL_ORDER_INVALID
    );
    assert_eq!(
        unsafe { release_swapchain_image(chain, std::ptr::null()) },
        xr::Result::ERROR_CALL_ORDER_INVALID
    );
    for expected in 0..3 {
        assert_eq!(wait(chain), xr::Result::SUCCESS);
        assert_eq!(wait(chain), xr::Result::ERROR_CALL_ORDER_INVALID);
        assert_eq!(
            unsafe { release_swapchain_image(chain, std::ptr::null()) },
            xr::Result::SUCCESS
        );
        assert_eq!(
            with(|r| r.session.as_ref().unwrap().swapchains[&chain.into_raw()].released),
            Some(expected)
        );
    }
    assert_eq!(
        unsafe { acquire_swapchain_image(chain, std::ptr::null(), &mut index) },
        xr::Result::SUCCESS
    );
    assert_eq!(index, 0);
    assert_eq!(wait(chain), xr::Result::SUCCESS);
    assert_eq!(
        unsafe { release_swapchain_image(chain, std::ptr::null()) },
        xr::Result::SUCCESS
    );
}

#[test]
fn static_image_is_acquired_only_once_for_the_entire_lifetime() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _f = Fixture::new();
    let chain = fake_chain(true);
    let mut count = 0;
    assert_eq!(
        unsafe { enumerate_swapchain_images(chain, 0, &mut count, std::ptr::null_mut()) },
        xr::Result::SUCCESS
    );
    assert_eq!(count, 1);
    let mut index = 99;
    assert_eq!(
        unsafe { acquire_swapchain_image(chain, std::ptr::null(), &mut index) },
        xr::Result::SUCCESS
    );
    assert_eq!(index, 0);
    assert_eq!(
        unsafe { acquire_swapchain_image(chain, std::ptr::null(), &mut index) },
        xr::Result::ERROR_CALL_ORDER_INVALID
    );
    assert_eq!(wait(chain), xr::Result::SUCCESS);
    assert_eq!(
        unsafe { release_swapchain_image(chain, std::ptr::null()) },
        xr::Result::SUCCESS
    );
    assert_eq!(
        unsafe { acquire_swapchain_image(chain, std::ptr::null(), &mut index) },
        xr::Result::ERROR_CALL_ORDER_INVALID
    );
    assert_eq!(wait(chain), xr::Result::ERROR_CALL_ORDER_INVALID);
    assert_eq!(
        unsafe { release_swapchain_image(chain, std::ptr::null()) },
        xr::Result::ERROR_CALL_ORDER_INVALID
    );
    assert_eq!(
        with(|r| r.session.as_ref().unwrap().swapchains[&chain.into_raw()].released),
        Some(0)
    );
}

#[test]
fn protected_swapchain_is_rejected_and_bad_call_structures_do_not_advance_fifo() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _f = Fixture::new();
    let mut info: xr::SwapchainCreateInfo = unsafe { std::mem::zeroed() };
    info.ty = xr::SwapchainCreateInfo::TYPE;
    info.create_flags = xr::SwapchainCreateFlags::PROTECTED_CONTENT;
    let mut out = xr::Swapchain::from_raw(0x999);
    assert_eq!(
        unsafe { create_swapchain(xr::Session::from_raw(0x200), &info, &mut out) },
        xr::Result::ERROR_FEATURE_UNSUPPORTED
    );
    assert_eq!(out, xr::Swapchain::NULL);
    let chain = fake_chain(false);
    let mut index = 99;
    assert_eq!(
        unsafe { acquire_swapchain_image(chain, std::ptr::null(), &mut index) },
        xr::Result::SUCCESS
    );
    assert_eq!(
        unsafe { wait_swapchain_image(chain, std::ptr::null()) },
        xr::Result::ERROR_VALIDATION_FAILURE
    );
    assert_eq!(
        unsafe { release_swapchain_image(chain, std::ptr::null()) },
        xr::Result::ERROR_CALL_ORDER_INVALID
    );
    assert_eq!(wait(chain), xr::Result::SUCCESS);
    assert_eq!(
        unsafe { release_swapchain_image(chain, std::ptr::null()) },
        xr::Result::SUCCESS
    );
}

#[test]
fn next_wait_frame_blocks_until_begin_even_after_host_wait_timeout() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _f = Fixture::new();
    let mut first: xr::FrameState = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe { wait_frame(session(), std::ptr::null(), &mut first) },
        xr::Result::SUCCESS
    );
    let first_time = first.predicted_display_time.as_nanos();
    let (send, receive) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let mut next: xr::FrameState = unsafe { std::mem::zeroed() };
        let result = unsafe { wait_frame(session(), std::ptr::null(), &mut next) };
        send.send((result, next.predicted_display_time.as_nanos()))
            .unwrap();
    });
    assert!(
        receive.recv_timeout(Duration::from_millis(300)).is_err(),
        "a second wait cannot overwrite the pending frame even after the 250 ms host timeout"
    );
    assert_eq!(
        with(|r| r.session.as_ref().unwrap().display_time),
        first_time
    );
    assert_eq!(
        unsafe { begin_frame(session(), std::ptr::null()) },
        xr::Result::SUCCESS,
        "blocked WaitFrame leaves the runtime lock available to BeginFrame"
    );
    let (result, second_time) = receive.recv_timeout(Duration::from_secs(1)).unwrap();
    worker.join().unwrap();
    assert_eq!(result, xr::Result::SUCCESS);
    assert!(second_time > first_time);
}

#[test]
fn ending_lost_host_session_releases_a_blocked_next_wait() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _f = Fixture::new();
    let mut first: xr::FrameState = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe { wait_frame(session(), std::ptr::null(), &mut first) },
        xr::Result::SUCCESS
    );
    let (send, receive) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let mut next: xr::FrameState = unsafe { std::mem::zeroed() };
        send.send(unsafe { wait_frame(session(), std::ptr::null(), &mut next) })
            .unwrap();
    });
    assert!(receive.recv_timeout(Duration::from_millis(20)).is_err());
    with(|r| {
        let s = r.session.as_mut().unwrap();
        s.last_host_tick = s.side.host_tick();
        s.last_host_progress = Instant::now() - Duration::from_secs(3);
    });
    assert!(
        events().contains(&Seen::State(xr::SessionState::STOPPING)),
        "event-only host loss is serviced while the next wait is blocked"
    );
    assert_eq!(unsafe { end_session(session()) }, xr::Result::SUCCESS);
    assert_eq!(
        receive.recv_timeout(Duration::from_secs(1)).unwrap(),
        xr::Result::ERROR_SESSION_NOT_RUNNING
    );
    worker.join().unwrap();
}
