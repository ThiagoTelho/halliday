use super::*;

type Matrix = [[f64; 4]; 4];
fn matrix(pose: xr::Posef) -> Matrix {
    let (x, y, z, w) = (
        pose.orientation.x as f64,
        pose.orientation.y as f64,
        pose.orientation.z as f64,
        pose.orientation.w as f64,
    );
    [
        [
            1.0 - 2.0 * (y * y + z * z),
            2.0 * (x * y - z * w),
            2.0 * (x * z + y * w),
            pose.position.x as f64,
        ],
        [
            2.0 * (x * y + z * w),
            1.0 - 2.0 * (x * x + z * z),
            2.0 * (y * z - x * w),
            pose.position.y as f64,
        ],
        [
            2.0 * (x * z - y * w),
            2.0 * (y * z + x * w),
            1.0 - 2.0 * (x * x + y * y),
            pose.position.z as f64,
        ],
        [0.0, 0.0, 0.0, 1.0],
    ]
}
fn multiply(a: Matrix, b: Matrix) -> Matrix {
    std::array::from_fn(|row| {
        std::array::from_fn(|column| (0..4).map(|k| a[row][k] * b[k][column]).sum())
    })
}
fn camera(axis: usize, angle: f32, p: [f32; 3]) -> xr::Posef {
    let mut q = [0.0, 0.0, 0.0, (angle * 0.5).cos()];
    q[axis] = (angle * 0.5).sin();
    xr::Posef {
        orientation: xr::Quaternionf {
            x: q[0],
            y: q[1],
            z: q[2],
            w: q[3],
        },
        position: vector(p),
    }
}
fn bridge_pose(pose: xr::Posef) -> bridge::Pose {
    bridge::Pose {
        position: [pose.position.x, pose.position.y, pose.position.z],
        orientation: [
            pose.orientation.x,
            pose.orientation.y,
            pose.orientation.z,
            pose.orientation.w,
        ],
        valid: 1,
        ..Default::default()
    }
}
fn projection_view(pose: xr::Posef, fov: xr::Fovf) -> xr::CompositionLayerProjectionView {
    xr::CompositionLayerProjectionView {
        ty: xr::CompositionLayerProjectionView::TYPE,
        next: std::ptr::null(),
        pose,
        fov,
        sub_image: unsafe { std::mem::zeroed() },
    }
}
fn assert_oracle(actual: &bridge::projection::View, expected: Matrix, source: xr::Fovf) {
    assert!(actual.valid());
    let rotation = matrix(xr::Posef {
        orientation: xr::Quaternionf {
            x: actual.orientation[0],
            y: actual.orientation[1],
            z: actual.orientation[2],
            w: actual.orientation[3],
        },
        position: vector(actual.position),
    });
    for row in 0..3 {
        for column in 0..4 {
            assert!(
                (rotation[row][column] - expected[row][column]).abs() < 3e-6,
                "world matrix row{row} column{column}"
            );
        }
    }
    let f = [
        (source.angle_left.min(source.angle_right) as f64).tan(),
        (source.angle_left.max(source.angle_right) as f64).tan(),
        (source.angle_up.max(source.angle_down) as f64).tan(),
        (source.angle_up.min(source.angle_down) as f64).tan(),
    ];
    for (i, &expected_tangent) in f.iter().enumerate() {
        assert!(
            (actual.tangents[i] as f64 - expected_tangent).abs() < 1e-6,
            "canonical tangent {i}"
        );
    }
}

#[test]
fn both_submitted_cameras_match_independent_double_matrix_oracle_in_stage_local_and_offset_action_spaces()
 {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _fixture = Fixture::new();
    with(|r| {
        let s = r.session.as_mut().unwrap();
        let mut sample = PoseSample {
            time: 1234,
            state: s.newest.unwrap(),
            motion_mask: 0,
            controller_frames: bridge::controller_frames::LEGACY,
            local: Some(camera(1, 0.7, [0.4, 0.2, -0.3])),
        };
        sample.state.controllers[0].pose = bridge_pose(camera(0, -0.4, [-0.35, 1.1, -0.45]));
        sample.state.controllers[1].pose = bridge_pose(camera(2, 0.5, [0.32, 0.9, -0.5]));
        s.pose_sources.insert(
            99,
            PoseSources {
                eligible: [true, true],
                kinds: [Some(Part::GripPose), Some(Part::GripPose)],
                selected: Some(0),
            },
        );
        let views = [
            projection_view(
                camera(0, -0.24, [-0.041, 0.016, -0.025]),
                xr::Fovf {
                    angle_left: 0.9,
                    angle_right: -0.65,
                    angle_up: 0.7,
                    angle_down: -1.0,
                },
            ),
            projection_view(
                camera(2, 0.18, [0.038, -0.012, 0.02]),
                xr::Fovf {
                    angle_left: -0.3,
                    angle_right: 0.6,
                    angle_up: -0.5,
                    angle_down: 0.8,
                },
            ),
        ];
        let offset = camera(2, 0.32, [0.13, -0.07, 0.09]);
        let cases = [
            (SpaceKind::Stage, IDENTITY),
            (SpaceKind::Local, sample.local.unwrap()),
            (
                SpaceKind::Action {
                    action: 99,
                    hand: Some(0),
                },
                from_bridge(&sample.state.controllers[0].pose),
            ),
            (
                SpaceKind::Action {
                    action: 99,
                    hand: Some(1),
                },
                from_bridge(&sample.state.controllers[1].pose),
            ),
        ];
        for (kind, base) in cases {
            let space = Space { kind, offset };
            let actual = s.projection_views(&space, &sample, &views).unwrap();
            let world_base = multiply(matrix(base), matrix(offset));
            for eye in 0..2 {
                assert_oracle(
                    &actual[eye],
                    multiply(world_base, matrix(views[eye].pose)),
                    views[eye].fov,
                );
            }
        }
        s.pose_sources.get_mut(&99).unwrap().eligible = [false, false];
        assert!(
            s.projection_views(
                &Space {
                    kind: SpaceKind::Action {
                        action: 99,
                        hand: Some(0)
                    },
                    offset
                },
                &sample,
                &views
            )
            .is_none(),
            "unlocatable layer cannot be published at an invented identity origin"
        );
    });
}

#[test]
fn old_peer_accepts_only_geometry_representable_by_its_rendered_head_and_calibrated_fov() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _fixture = Fixture::new();
    with(|r| {
        let s = r.session.as_ref().unwrap();
        let head = bridge::Pose {
            position: [0.2, 1.5, -0.4],
            orientation: [0., 0., 0., 1.],
            valid: 1,
            ..Default::default()
        };
        let mut views = std::array::from_fn(|eye| bridge::projection::View {
            position: [
                head.position[0]
                    + if eye == 0 {
                        -s.config.ipd * 0.5
                    } else {
                        s.config.ipd * 0.5
                    },
                head.position[1],
                head.position[2],
            ],
            orientation: head.orientation,
            tangents: s.config.tangents[eye],
        });
        assert!(projection_geometry::legacy_compatible(
            &views, head, &s.config
        ));
        for q in &mut views[1].orientation {
            *q = -*q;
        }
        assert!(
            projection_geometry::legacy_compatible(&views, head, &s.config),
            "quaternion sign does not change the camera"
        );
        let original = views;
        views[1].position[2] += 0.01;
        assert!(!projection_geometry::legacy_compatible(
            &views, head, &s.config
        ));
        views = original;
        views[0].tangents[0] *= 0.8;
        assert!(!projection_geometry::legacy_compatible(
            &views, head, &s.config
        ));
        views = original;
        let q = camera(1, 0.1, [0., 0., 0.]).orientation;
        views[1].orientation = [q.x, q.y, q.z, q.w];
        assert!(!projection_geometry::legacy_compatible(
            &views, head, &s.config
        ));
    });
}
