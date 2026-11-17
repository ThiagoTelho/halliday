//! The headset's two bottom cameras as a stereo pair.
//!
//! Camera mode 1 sends their pictures already rectified (640 × 640 each, 60 a second): a point
//! is at the same height in both, and how far apart it appears sideways tells its distance. So
//! the pair is described by one pinhole camera and the distance between the two.
//!
//! No calibration for these cameras has been found in the headset's data so far (and Monado
//! holds none): [`PSVR2_BOTTOM`] was fitted against the controllers' LED layout, from 218 s of
//! both controllers turned about at arm's length in front of one headset, worn (firmware
//! 07000102; `halliday-probe hands FILE --fit` repeats the fit, `tracking/hands.rs`
//! `calibrate`). A plain pinhole fits the whole picture (what is left over is the same from the
//! centre to the corners). How sure the numbers are: quarters of that capture, and an earlier one
//! at 25 cm, give focal lengths from 353 to 377 px and baselines from 79.1 to 81.4 mm, so the
//! focal length (and with it a distance) is good to about 3 %, the baseline to 1 or 2 %.
//!
//! The camera's frame, used for everything seen through the pair: the left camera at the
//! origin, x to the right, y down, z forward, in meters.

use crate::math::Quat;

/// Vectors and rotations here are `f64`: the fit differentiates by small steps.
pub type V3 = [f64; 3];
/// A rotation, as rows.
pub type M3 = [[f64; 3]; 3];

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StereoPair {
    /// Focal length in pixels (365 over 640 pixels: 82° across).
    pub focal: f64,
    /// The optical axis in the left picture, the right picture and (both) down the picture.
    pub cx_left: f64,
    pub cx_right: f64,
    pub cy: f64,
    /// Distance between the two cameras, meters.
    pub baseline: f64,
    /// How far below the head's forward the pair looks, radians.
    pub pitch: f64,
}

/// The PS VR2's bottom pair in camera mode 1.
pub const PSVR2_BOTTOM: StereoPair = StereoPair {
    focal: 365.4,
    cx_left: 313.6,
    cx_right: 313.0,
    cy: 320.5,
    baseline: 0.0797,
    pitch: 0.269,
};

/// Where the PS VR2's left bottom camera sits in the head's frame (x right, y up, z back, from
/// the point the head's tracked pose is of), meters: 4 cm left, 1.7 cm below, 9.5 cm ahead.
/// From 76 s of both controllers lying on a desk while the head moved and turned over half a
/// meter (`halliday-probe hands FILE --mount`, `hands.rs` `camera_place`). The two
/// controllers put it at −51 / −17 / −90 mm and −33 / −13 / −93 mm, their fixes agreeing to
/// 15 mm; sideways the mean is taken for half the baseline, the pair being in the middle of the
/// headset. Good to about a centimeter.
pub const PSVR2_BOTTOM_PLACE: V3 = [-0.040, -0.017, -0.095];

/// One camera of the headset, in the bottom pair's camera frame: a pinhole or a fisheye, turned
/// and set apart from the left bottom camera.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Camera {
    pub focal: f64,
    pub cx: f64,
    pub cy: f64,
    /// The pair's frame seen from this camera's (x right, y down, z forward), as rows.
    pub rotation: M3,
    /// Where it sits in the pair's frame, meters.
    pub place: V3,
    /// A fisheye's lens (Kannala-Brandt, as OpenCV's fisheye: a ray `θ` off the axis lands
    /// `focal · θ · (1 + k1 θ² + k2 θ⁴)` from the centre); `None`: a pinhole.
    pub fisheye: Option<[f64; 2]>,
    /// The picture's size in pixels, across and down.
    pub size: [f64; 2],
}

/// Fisheye rays farther than this off the axis are not used (the lens model is fitted to 65°,
/// and the picture's edge is at about 70°).
const FISHEYE_REACH: f64 = 80.0 * std::f64::consts::PI / 180.0;

impl Camera {
    /// A point of the pair's frame in this camera's own.
    pub fn see(&self, p: V3) -> V3 {
        apply(
            &self.rotation,
            [
                p[0] - self.place[0],
                p[1] - self.place[1],
                p[2] - self.place[2],
            ],
        )
    }

    /// Where a point of the pair's frame appears in this camera's picture, pixels; `None`
    /// behind the camera (or, for a fisheye, beyond what its lens model covers).
    pub fn project(&self, p: V3) -> Option<[f64; 2]> {
        self.project_ray(self.see(p))
    }

    /// Where a direction of this camera's own frame appears in its picture.
    pub fn project_ray(&self, c: V3) -> Option<[f64; 2]> {
        let Some([k1, k2]) = self.fisheye else {
            return (c[2] > 0.02).then(|| {
                [
                    self.cx + self.focal * c[0] / c[2],
                    self.cy + self.focal * c[1] / c[2],
                ]
            });
        };
        let across = c[0].hypot(c[1]);
        let theta = across.atan2(c[2]);
        if theta > FISHEYE_REACH {
            return None;
        }
        if across < 1e-12 {
            return Some([self.cx, self.cy]);
        }
        let t2 = theta * theta;
        let r = self.focal * theta * (1.0 + k1 * t2 + k2 * t2 * t2);
        Some([self.cx + r * c[0] / across, self.cy + r * c[1] / across])
    }

    /// The direction (unit length) of this camera's own frame that a pixel of its picture sees.
    pub fn ray(&self, x: f64, y: f64) -> V3 {
        let (dx, dy) = ((x - self.cx) / self.focal, (y - self.cy) / self.focal);
        let Some([k1, k2]) = self.fisheye else {
            let n = (dx * dx + dy * dy + 1.0).sqrt();
            return [dx / n, dy / n, 1.0 / n];
        };
        // θ (1 + k1 θ² + k2 θ⁴) = the distance from the centre in focal lengths: Newton's way.
        let target = dx.hypot(dy);
        let mut theta = target;
        for _ in 0..8 {
            let t2 = theta * theta;
            let f = theta * (1.0 + k1 * t2 + k2 * t2 * t2) - target;
            let slope = 1.0 + 3.0 * k1 * t2 + 5.0 * k2 * t2 * t2;
            theta -= f / slope;
        }
        if target < 1e-12 {
            return [0.0, 0.0, 1.0];
        }
        let s = theta.sin() / target;
        [dx * s, dy * s, theta.cos()]
    }
}

/// The PS VR2's two bottom cameras as they really are (camera mode 0x10 sends their raw
/// pictures, 1000 × 1016 of each): fisheyes, the left one then the right one. Each looks 16° out
/// to its side and 15.5° below the rectified pair's forward ([`PSVR2_BOTTOM`], itself 15.4° below
/// the head's), and sees about 70° around its axis inside the picture: together some 170° across
/// where the rectified pair sees 82°. Fitted from three pairs of pictures of the
/// same still room in modes 1 and 0x10 (the same sensors, so one picture is the other turned and
/// undistorted: no parallax to fit): SIFT matches between each rectified view and its raw
/// picture, 954 and 1 093 of them out to 64° off the axis, 0.95 and 0.89 px left over (a fit on
/// half of them puts the other half at 0.95 and 0.90 px). Two lens terms fit as well as four and
/// stay sane beyond the matches; the two cameras came out mirror images (16.4° and 16.2° out,
/// rolled 4.2° and 4.5°) without being asked to. In [`PSVR2_BOTTOM`]'s numbers, so a fix in
/// either mode is in the same frame.
pub const PSVR2_BOTTOM_FISHEYE: [Camera; 2] = [
    Camera {
        focal: 394.59,
        cx: 493.88,
        cy: 516.70,
        rotation: [
            [0.96214, 0.07084, 0.26317],
            [0.00227, 0.96352, -0.26764],
            [-0.27253, 0.25811, 0.92688],
        ],
        place: [0.0; 3],
        fisheye: Some([0.04338, -0.01803]),
        size: [1000.0, 1016.0],
    },
    Camera {
        focal: 398.65,
        cx: 509.23,
        cy: 511.17,
        rotation: [
            [0.96313, -0.07527, -0.25828],
            [0.00323, 0.96323, -0.26867],
            [0.26901, 0.25793, 0.92796],
        ],
        place: [0.0797, 0.0, 0.0],
        fisheye: Some([0.02762, -0.01672]),
        size: [1000.0, 1016.0],
    },
];

/// The PS VR2's two top cameras (camera mode 3 sends them with the bottom pair, views 2 and 3):
/// the left one, then the right one. Each looks 58° out to its side and 11° up from the bottom
/// pair's forward, rolled 11°, from about 7 cm above the bottom cameras and 3 cm outside them;
/// they hardly overlap each other, so each is used alone. Fitted from 97 s of the
/// controllers moved slowly between the bottom pair's sight and theirs: where the bottom pair
/// placed a controller's LEDs against the spots a top camera saw of them (1 817 sightings for the
/// right camera, 442 for the left, 1.8 and 1.9 px left over). The two were fitted apart and came
/// out mirror images within 4 mm and 0.5°. The lens is taken to be the bottom cameras' (left
/// free, the focal length comes out at 361 and 351 px): only the strip of each picture that
/// overlaps the bottom pair's sight was covered, which can't settle a lens by itself.
pub const PSVR2_TOP: [Camera; 2] = [
    Camera {
        focal: 365.4,
        cx: 313.3,
        cy: 320.5,
        rotation: [
            [0.48615, 0.18980, 0.85302],
            [-0.25187, 0.96514, -0.07120],
            [-0.83679, -0.18024, 0.51700],
        ],
        place: [-0.02548, -0.06717, -0.02472],
        fisheye: None,
        size: [640.0, 640.0],
    },
    Camera {
        focal: 365.4,
        cx: 313.3,
        cy: 320.5,
        rotation: [
            [0.48500, -0.19589, -0.85229],
            [0.26194, 0.96239, -0.07214],
            [0.83436, -0.18826, 0.51807],
        ],
        place: [0.10915, -0.06672, -0.01593],
        fisheye: None,
        size: [640.0, 640.0],
    },
];

impl StereoPair {
    /// The pair's two cameras, left then right, as cameras like any other.
    pub fn cameras(&self) -> [Camera; 2] {
        let identity = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
        [
            Camera {
                focal: self.focal,
                cx: self.cx_left,
                cy: self.cy,
                rotation: identity,
                place: [0.0; 3],
                fisheye: None,
                size: [640.0, 640.0],
            },
            Camera {
                focal: self.focal,
                cx: self.cx_right,
                cy: self.cy,
                rotation: identity,
                place: [self.baseline, 0.0, 0.0],
                fisheye: None,
                size: [640.0, 640.0],
            },
        ]
    }

    /// A point of the camera's frame in the head's, the left camera sitting at `place`.
    pub fn in_head(&self, place: V3, p: V3) -> V3 {
        let turned = apply(&transpose(&self.camera_from_head()), p);
        [
            turned[0] + place[0],
            turned[1] + place[1],
            turned[2] + place[2],
        ]
    }

    /// Where a point of the camera's frame appears: `[[x, y] in the left picture, [x, y] in the
    /// right]`, in pixels.
    pub fn project(&self, p: V3) -> [[f64; 2]; 2] {
        let y = self.cy + self.focal * p[1] / p[2];
        [
            [self.cx_left + self.focal * p[0] / p[2], y],
            [
                self.cx_right + self.focal * (p[0] - self.baseline) / p[2],
                y,
            ],
        ]
    }

    /// How much farther right a point at this depth appears in the left picture than in the
    /// right one, in pixels.
    pub fn disparity(&self, depth: f64) -> f64 {
        self.focal * self.baseline / depth + self.cx_left - self.cx_right
    }

    /// The point seen at `x_left`, `y` in the left picture and `x_right` in the right one.
    pub fn triangulate(&self, x_left: f64, x_right: f64, y: f64) -> V3 {
        let depth =
            self.focal * self.baseline / (x_left - x_right - (self.cx_left - self.cx_right));
        [
            (x_left - self.cx_left) * depth / self.focal,
            (y - self.cy) * depth / self.focal,
            depth,
        ]
    }

    /// The head's frame (x right, y up, z back) seen from the camera's: the same x, the camera
    /// looking `pitch` below the head's forward. Only the rotation: [`StereoPair::in_head`]
    /// takes a point across.
    pub fn camera_from_head(&self) -> M3 {
        let (s, c) = self.pitch.sin_cos();
        [[1.0, 0.0, 0.0], [0.0, -c, s], [0.0, -s, -c]]
    }

    /// The tracking space seen from the camera's frame, for a head at `head` (its orientation
    /// in the tracking space).
    pub fn camera_from_world(&self, head: Quat) -> M3 {
        mul(&self.camera_from_head(), &transpose(&from_quat(head)))
    }
}

pub fn mul(a: &M3, b: &M3) -> M3 {
    std::array::from_fn(|i| std::array::from_fn(|j| (0..3).map(|k| a[i][k] * b[k][j]).sum()))
}

pub fn transpose(a: &M3) -> M3 {
    std::array::from_fn(|i| std::array::from_fn(|j| a[j][i]))
}

pub fn apply(m: &M3, v: V3) -> V3 {
    std::array::from_fn(|i| m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2])
}

/// A turn about +y (up in the tracking space), counter-clockwise seen from above.
pub fn turn_y(angle: f64) -> M3 {
    let (s, c) = angle.sin_cos();
    [[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]]
}

pub fn from_quat(q: Quat) -> M3 {
    let q = q.normalized();
    let (w, x, y, z) = (
        f64::from(q.w),
        f64::from(q.x),
        f64::from(q.y),
        f64::from(q.z),
    );
    [
        [
            1.0 - 2.0 * (y * y + z * z),
            2.0 * (x * y - z * w),
            2.0 * (x * z + y * w),
        ],
        [
            2.0 * (x * y + z * w),
            1.0 - 2.0 * (x * x + z * z),
            2.0 * (y * z - x * w),
        ],
        [
            2.0 * (x * z - y * w),
            2.0 * (y * z + x * w),
            1.0 - 2.0 * (x * x + y * y),
        ],
    ]
}

/// The rotation by the rotation vector `r` (axis × angle).
pub fn from_rotation_vector(r: V3) -> M3 {
    let angle = (r[0] * r[0] + r[1] * r[1] + r[2] * r[2]).sqrt();
    if angle < 1e-12 {
        return [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
    }
    let k = [r[0] / angle, r[1] / angle, r[2] / angle];
    let (s, c) = angle.sin_cos();
    std::array::from_fn(|i| {
        std::array::from_fn(|j| {
            let cross = match (i, j) {
                (0, 1) => -k[2],
                (0, 2) => k[1],
                (1, 0) => k[2],
                (1, 2) => -k[0],
                (2, 0) => -k[1],
                (2, 1) => k[0],
                _ => 0.0,
            };
            let identity = if i == j { 1.0 } else { 0.0 };
            c * identity + s * cross + (1.0 - c) * k[i] * k[j]
        })
    })
}

#[cfg(test)]
mod tests {

    #[test]
    fn a_fisheye_ray_comes_back_to_its_pixel() {
        for camera in PSVR2_BOTTOM_FISHEYE {
            for (x, y) in [
                (500.0, 510.0),
                (60.0, 516.0),
                (950.0, 510.0),
                (700.0, 300.0),
                (200.0, 250.0),
            ] {
                let back = camera.project_ray(camera.ray(x, y)).unwrap();
                assert!(
                    (back[0] - x).abs() < 1e-6 && (back[1] - y).abs() < 1e-6,
                    "{back:?}"
                );
            }
        }
    }

    #[test]
    fn the_fisheyes_see_what_the_rectified_pair_sees() {
        // A point straight ahead of the rectified pair, a meter out, lands in both raw pictures
        // up and inwards of their centres (each looks out and down), and the pictures' edges
        // reach about 70° off each axis.
        let ahead = [0.04, 0.0, 1.0];
        let [l, r] = PSVR2_BOTTOM_FISHEYE.map(|c| c.project(ahead).unwrap());
        assert!(l[0] > 493.88 + 60.0 && l[1] < 516.7 - 60.0, "{l:?}");
        assert!(r[0] < 509.23 - 60.0 && r[1] < 511.17 - 60.0, "{r:?}");
        for camera in PSVR2_BOTTOM_FISHEYE {
            let edge = camera.ray(0.0, camera.cy);
            let off = edge[2].acos().to_degrees();
            assert!((65.0..75.0).contains(&off), "{off}");
        }
    }

    use super::*;

    #[test]
    fn a_point_projected_is_found_again() {
        let pair = PSVR2_BOTTOM;
        for p in [[0.05, -0.1, 0.3], [-0.2, 0.15, 0.6], [0.0, 0.0, 0.25]] {
            let [l, r] = pair.project(p);
            assert_eq!(l[1], r[1]);
            assert!((l[0] - r[0] - pair.disparity(p[2])).abs() < 1e-9);
            let back = pair.triangulate(l[0], r[0], l[1]);
            for k in 0..3 {
                assert!((back[k] - p[k]).abs() < 1e-9);
            }
        }
        // At arm's length the two pictures differ by about 60 px.
        assert!((50.0..70.0).contains(&pair.disparity(0.45)));
    }

    #[test]
    fn the_pair_looks_below_the_heads_forward() {
        let pair = PSVR2_BOTTOM;
        // A level head: something ahead and below the eyes is on the cameras' axis.
        let m = pair.camera_from_world(Quat::IDENTITY);
        let ahead = apply(&m, [0.0, -pair.pitch.sin(), -pair.pitch.cos()]);
        assert!(ahead[0].abs() < 1e-9 && ahead[1].abs() < 1e-9 && (ahead[2] - 1.0).abs() < 1e-9);
        // Up in the room is up in the picture (y runs down), and right stays right.
        assert!(apply(&m, [0.0, 1.0, 0.0])[1] < -0.9);
        assert_eq!(apply(&m, [1.0, 0.0, 0.0]), [1.0, 0.0, 0.0]);
        // A head turned left sees what was ahead of it to its right.
        let turned = pair.camera_from_world(Quat::from_axis_angle([0.0, 1.0, 0.0], 0.5));
        assert!(apply(&turned, [0.0, 0.0, -1.0])[0] > 0.4);
    }

    #[test]
    fn a_point_on_the_cameras_axis_is_ahead_of_and_below_the_head() {
        let pair = PSVR2_BOTTOM;
        let p = pair.in_head(PSVR2_BOTTOM_PLACE, [0.0, 0.0, 0.5]);
        assert!((p[0] - PSVR2_BOTTOM_PLACE[0]).abs() < 1e-12);
        assert!((p[1] - (PSVR2_BOTTOM_PLACE[1] - 0.5 * pair.pitch.sin())).abs() < 1e-12);
        assert!((p[2] - (PSVR2_BOTTOM_PLACE[2] - 0.5 * pair.pitch.cos())).abs() < 1e-12);
        // The right camera is one baseline to the head's right of the left one.
        let right = pair.in_head(PSVR2_BOTTOM_PLACE, [pair.baseline, 0.0, 0.0]);
        assert!((right[0] + PSVR2_BOTTOM_PLACE[0]).abs() < 0.001);
    }

    #[test]
    fn the_pairs_cameras_see_what_the_pair_projects() {
        let pair = PSVR2_BOTTOM;
        let p = [0.07, -0.05, 0.4];
        let both = pair.project(p);
        for (camera, expected) in pair.cameras().iter().zip(both) {
            let seen = camera.project(p).unwrap();
            assert!((seen[0] - expected[0]).abs() < 1e-9 && (seen[1] - expected[1]).abs() < 1e-9);
        }
        assert_eq!(pair.cameras()[0].project([0.0, 0.0, -0.3]), None);
    }

    #[test]
    fn the_top_cameras_look_up_and_out_as_mirror_images() {
        let [left, right] = PSVR2_TOP;
        for (camera, side) in [(left, -1.0), (right, 1.0)] {
            // Proper rotations.
            for i in 0..3 {
                for j in 0..3 {
                    let d: f64 = (0..3)
                        .map(|k| camera.rotation[i][k] * camera.rotation[j][k])
                        .sum();
                    assert!((d - if i == j { 1.0 } else { 0.0 }).abs() < 1e-3);
                }
            }
            // Forward (the third row) points out to its side, a little up (y runs down).
            let forward = camera.rotation[2];
            assert!(forward[0] * side > 0.8 && forward[1] < -0.1 && forward[2] > 0.4);
            // A hand up and out to that side, out of the bottom pair's picture, is in its own.
            let hand = [0.04 + side * 0.45, -0.25, 0.35];
            let seen = camera.project(hand).unwrap();
            assert!(
                (0.0..640.0).contains(&seen[0]) && (0.0..640.0).contains(&seen[1]),
                "{seen:?}"
            );
            let below = PSVR2_BOTTOM.cameras()[0].project(hand).unwrap();
            assert!(!(0.0..640.0).contains(&below[0]));
        }
        assert!((left.rotation[2][0] + right.rotation[2][0]).abs() < 0.01);
        assert!((left.place[1] - right.place[1]).abs() < 0.005);
    }

    #[test]
    fn rotation_helpers_agree() {
        let q = Quat::from_axis_angle([0.0, 1.0, 0.0], 0.7);
        let (a, b, c) = (
            from_quat(q),
            turn_y(0.7),
            from_rotation_vector([0.0, 0.7, 0.0]),
        );
        for i in 0..3 {
            for j in 0..3 {
                assert!((a[i][j] - b[i][j]).abs() < 1e-6);
                assert!((b[i][j] - c[i][j]).abs() < 1e-12);
            }
        }
        let v = q.rotate([0.2, -0.3, 0.9]);
        let w = apply(&a, [0.2, -0.3, 0.9]);
        for k in 0..3 {
            assert!((f64::from(v[k]) - w[k]).abs() < 1e-6);
        }
    }
}
