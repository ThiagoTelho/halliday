use super::*;
use std::os::unix::fs::FileExt;

#[test]
fn unsupported_swapchain_usage_fails_before_graphics_allocation() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _fixture = Fixture::new();
    let mut info: xr::SwapchainCreateInfo = unsafe { std::mem::zeroed() };
    info.ty = xr::SwapchainCreateInfo::TYPE;
    info.format = 80;
    info.width = 8;
    info.height = 8;
    info.sample_count = 1;
    info.face_count = 1;
    info.array_size = 1;
    info.mip_count = 1;
    // This deliberately GPU-free fixture has no device. Every failure must be
    // decided from the public usage request, before any texture API is called.
    for flags in [1u64 << 48, 128, 2] {
        info.usage_flags = xr::SwapchainUsageFlags::from_raw(1 | flags);
        let mut output = xr::Swapchain::from_raw(0x999);
        assert_eq!(
            unsafe { create_swapchain(session(), &info, &mut output) },
            xr::Result::ERROR_FEATURE_UNSUPPORTED
        );
        assert_eq!(output, xr::Swapchain::NULL);
        assert!(with(|r| r.session.as_ref().unwrap().swapchains.is_empty()));
    }
}

#[test]
fn semantic_frames_require_batch_capability_but_legacy_empty_still_publishes_only_black() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let fixture = Fixture::new();
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&fixture.path)
        .unwrap();
    assert_eq!(file.write_at(&0u32.to_ne_bytes(), 61568).unwrap(), 4);
    assert!(!with(|r| r
        .session
        .as_ref()
        .unwrap()
        .side
        .supports_panels()));
    let swapchain = xr::Swapchain::from_raw(0x900);
    with(|r| {
        r.session.as_mut().unwrap().swapchains.insert(
            swapchain.into_raw(),
            Swapchain {
                width: 8,
                height: 8,
                layers: 1,
                vulkan: false,
                bgra: false,
                transfer: bridge::FRAME_COLOR_LINEAR,
                textures: vec![std::ptr::null_mut(); 3],
                next: 0,
                acquired: Default::default(),
                waited: false,
                static_image: false,
                static_acquired: false,
                released: Some(0),
            },
        );
    });
    let image = xr::SwapchainSubImage {
        swapchain,
        image_array_index: 0,
        image_rect: xr::Rect2Di {
            offset: xr::Offset2Di { x: 0, y: 0 },
            extent: xr::Extent2Di {
                width: 8,
                height: 8,
            },
        },
    };
    let views = std::array::from_fn::<_, 2, _>(|eye| xr::CompositionLayerProjectionView {
        ty: xr::CompositionLayerProjectionView::TYPE,
        next: std::ptr::null(),
        pose: xr::Posef {
            orientation: IDENTITY.orientation,
            position: xr::Vector3f {
                x: if eye == 0 { -0.032 } else { 0.032 },
                y: 1.6,
                z: 0.0,
            },
        },
        fov: xr::Fovf {
            angle_left: -0.7,
            angle_right: 0.7,
            angle_up: 0.7,
            angle_down: -0.7,
        },
        sub_image: image,
    });
    let mut projection = xr::CompositionLayerProjection {
        ty: xr::CompositionLayerProjection::TYPE,
        next: std::ptr::null(),
        layer_flags: xr::CompositionLayerFlags::BLEND_TEXTURE_SOURCE_ALPHA,
        space: xr::Space::from_raw(0x300),
        view_count: 2,
        views: views.as_ptr(),
    };
    let quad = xr::CompositionLayerQuad {
        ty: xr::CompositionLayerQuad::TYPE,
        next: std::ptr::null(),
        layer_flags: xr::CompositionLayerFlags::EMPTY,
        space: xr::Space::from_raw(0x300),
        eye_visibility: xr::EyeVisibility::BOTH,
        sub_image: image,
        pose: IDENTITY,
        size: xr::Extent2Df {
            width: 0.4,
            height: 0.3,
        },
    };
    for mode in 0..3 {
        projection.layer_flags = if mode == 0 {
            xr::CompositionLayerFlags::BLEND_TEXTURE_SOURCE_ALPHA
        } else {
            xr::CompositionLayerFlags::EMPTY
        };
        let pointers = [
            (&projection as *const xr::CompositionLayerProjection)
                .cast::<xr::CompositionLayerBaseHeader>(),
            (&quad as *const xr::CompositionLayerQuad).cast::<xr::CompositionLayerBaseHeader>(),
        ];
        let info = xr::FrameEndInfo {
            ty: xr::FrameEndInfo::TYPE,
            next: std::ptr::null(),
            display_time: xr::Time::from_nanos(1234),
            environment_blend_mode: xr::EnvironmentBlendMode::OPAQUE,
            layer_count: if mode == 0 {
                1
            } else if mode == 1 {
                2
            } else {
                0
            },
            layers: pointers.as_ptr(),
        };
        with(|r| r.session.as_mut().unwrap().begun = true);
        let expected = match mode {
            0 => xr::Result::ERROR_LAYER_INVALID,
            1 => xr::Result::ERROR_FEATURE_UNSUPPORTED,
            _ => xr::Result::SUCCESS,
        };
        assert_eq!(
            unsafe { end_frame(session(), &info) },
            expected,
            "semantic frame mode {mode}"
        );
        with(|r| {
            let s = r.session.as_ref().unwrap();
            assert_eq!(s.frames, if mode == 2 { 1 } else { 0 });
            assert_eq!(s.scratch_bytes, 0);
            if mode < 2 {
                assert!(
                    s.readback.iter().all(Vec::is_empty),
                    "no GPU/output preparation on an unsupported peer"
                );
            }
        });
    }
    let frame = fixture
        ._host
        .begin_read()
        .expect("old host receives a complete black retirement frame");
    assert_eq!((frame.width, frame.height), (8, 8));
    for offset in frame.offsets {
        let mut bytes = [255u8; 8 * 8 * 4];
        file.read_exact_at(&mut bytes, offset as u64).unwrap();
        assert!(
            bytes.iter().all(|v| *v == 0),
            "legacy empty is black without a GPU source"
        );
    }
    fixture._host.end_read();
}
