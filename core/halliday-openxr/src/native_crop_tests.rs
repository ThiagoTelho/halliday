use super::*;

// Independent golden camera: Swift's geometry replay tests verify the same
// aligned dimensions and original-pixel rays, without using this reader.
fn configuration(cropped: bool) -> Config {
    let mut config = Config {
        eye_width: 2016,
        eye_height: 2048,
        display_hz: 120.,
        ipd: 0.064,
        tangents: [[-1.88, 0.95, 1.33, -1.22], [-0.95, 1.88, 1.27, -1.33]],
    };
    if cropped {
        config.eye_width = 1728;
        config.eye_height = 1856;
        config.tangents = [
            [-1.4757142, 0.95, 1.2104688, -1.1004688],
            [-0.95, 1.4757142, 1.1481249, -1.208125],
        ];
    }
    config
}

#[test]
fn host_config_reaches_actual_native_view_size_and_fov_without_changing_tracking() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    for cropped in [false, true, false] {
        let config = configuration(cropped);
        let fixture = Fixture::with_config(false, config);
        let mapped = GameSide::view(&fixture.path).unwrap().config();
        assert_eq!(
            (mapped.eye_width, mapped.eye_height, mapped.tangents),
            (config.eye_width, config.eye_height, config.tangents),
            "unchanged original bridge ABI"
        );
        assert_eq!(
            crate::eye_size(),
            (config.eye_width, config.eye_height),
            "the actual native view-configuration recommendation reads the negotiated crop"
        );
        for angle in [-0.8f32, 0., 0.37] {
            let (y, w) = ((angle * 0.5).sin(), (angle * 0.5).cos());
            fixture.state(|state| {
                state.head.position = [0.2, 1.6, -0.4];
                state.head.orientation = [0., y, 0., w];
            });
            let (views, flags) = views_at(
                halliday_core::time::host_time_ns(),
                xr::Space::from_raw(0x300),
            );
            assert!(flags.contains(
                xr::ViewStateFlags::ORIENTATION_VALID | xr::ViewStateFlags::POSITION_VALID
            ));
            for (eye, view) in views.iter().enumerate() {
                let f = view.fov;
                let actual = [
                    f.angle_left.tan(),
                    f.angle_right.tan(),
                    f.angle_up.tan(),
                    f.angle_down.tan(),
                ];
                for (i, &actual_tangent) in actual.iter().enumerate() {
                    assert!(
                        (actual_tangent - config.tangents[eye][i]).abs() < 4e-7,
                        "native crop FOV edge {eye}/{i}"
                    );
                }
                let offset = if eye == 0 {
                    -config.ipd * 0.5
                } else {
                    config.ipd * 0.5
                };
                assert!((view.pose.position.x - (0.2 + angle.cos() * offset)).abs() < 1e-6);
                assert!((view.pose.position.z - (-0.4 - angle.sin() * offset)).abs() < 1e-6);
                assert_eq!(view.pose.orientation.y, y);
                assert_eq!(view.pose.orientation.w, w);
            }
        }
    }
}

#[test]
fn quad_view_foundation_is_not_falsely_advertised_or_silently_treated_as_stereo() {
    assert!(
        !crate::EXTENSIONS
            .iter()
            .any(|(name, _)| *name == "XR_VARJO_quad_views")
    );
    let info = xr::ViewLocateInfo {
        ty: xr::ViewLocateInfo::TYPE,
        next: std::ptr::null(),
        view_configuration_type: xr::ViewConfigurationType::from_raw(1000037000),
        display_time: xr::Time::from_nanos(1),
        space: xr::Space::NULL,
    };
    let mut state: xr::ViewState = unsafe { std::mem::zeroed() };
    let mut count = 0;
    assert_eq!(
        unsafe {
            locate_views(
                xr::Session::NULL,
                &info,
                &mut state,
                0,
                &mut count,
                std::ptr::null_mut(),
            )
        },
        xr::Result::ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED
    );
}
