//! The little math the game's side needs without `std`: square root, sine and cosine
//! (polynomials, ~1e-6 error), quaternions for pose prediction, and where a ray meets an
//! overlay.

use core::f32::consts::{FRAC_PI_2, PI};

pub fn sqrt(x: f32) -> f32 {
    if x <= 0.0 || x.is_nan() {
        return 0.0;
    }
    // A first guess from the exponent, then Newton's steps.
    let mut y = f32::from_bits((x.to_bits() >> 1) + 0x1FC0_0000);
    for _ in 0..4 {
        y = 0.5 * (y + x / y);
    }
    y
}

/// sin(x) for x in [-π/2, π/2] (Taylor to x^11).
fn sin_near(x: f32) -> f32 {
    let x2 = x * x;
    x * (1.0
        - x2 / 6.0 * (1.0 - x2 / 20.0 * (1.0 - x2 / 42.0 * (1.0 - x2 / 72.0 * (1.0 - x2 / 110.0)))))
}

/// Folds `x` into [-π, π].
fn wrap(x: f32) -> f32 {
    let turns = x / (2.0 * PI);
    let k = if turns >= 0.0 {
        (turns + 0.5) as i64 as f32
    } else {
        (turns - 0.5) as i64 as f32
    };
    x - k * 2.0 * PI
}

pub fn sin(x: f32) -> f32 {
    let x = wrap(x);
    if x > FRAC_PI_2 {
        sin_near(PI - x)
    } else if x < -FRAC_PI_2 {
        sin_near(-PI - x)
    } else {
        sin_near(x)
    }
}

pub fn cos(x: f32) -> f32 {
    sin(x + FRAC_PI_2)
}

/// Quaternions as (x, y, z, w).
pub fn quat_mul(a: [f32; 4], b: [f32; 4]) -> [f32; 4] {
    [
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    ]
}

/// `q` turned on by the angular velocity `w` (rad/s, world axes) for `dt` seconds.
pub fn rotate_by(q: [f32; 4], w: [f32; 3], dt: f32) -> [f32; 4] {
    let angle = sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) * dt;
    if angle < 1e-6 {
        return q;
    }
    let s = sin(angle * 0.5) / (angle / dt);
    let d = [w[0] * s, w[1] * s, w[2] * s, cos(angle * 0.5)];
    let r = quat_mul(d, q);
    let n = sqrt(r.iter().map(|c| c * c).sum());
    [r[0] / n, r[1] / n, r[2] / n, r[3] / n]
}

/// A 3 × 4 pose matrix (rows, OpenVR's `HmdMatrix34_t`).
pub type Matrix34 = [[f32; 4]; 3];

/// The pose at `p` turned by `q` as a matrix.
pub fn pose_matrix(p: [f32; 3], q: [f32; 4]) -> Matrix34 {
    let [x, y, z, w] = q;
    [
        [
            1.0 - 2.0 * (y * y + z * z),
            2.0 * (x * y - z * w),
            2.0 * (x * z + y * w),
            p[0],
        ],
        [
            2.0 * (x * y + z * w),
            1.0 - 2.0 * (x * x + z * z),
            2.0 * (y * z - x * w),
            p[1],
        ],
        [
            2.0 * (x * z - y * w),
            2.0 * (y * z + x * w),
            1.0 - 2.0 * (x * x + y * y),
            p[2],
        ],
    ]
}

/// `a` after `b` (`b` expressed in `a`'s frame).
pub fn matrix_mul(a: &Matrix34, b: &Matrix34) -> Matrix34 {
    let mut m = [[0.0; 4]; 3];
    for (r, row) in m.iter_mut().enumerate() {
        for (c, v) in row.iter_mut().enumerate() {
            *v = a[r][0] * b[0][c]
                + a[r][1] * b[1][c]
                + a[r][2] * b[2][c]
                + if c == 3 { a[r][3] } else { 0.0 };
        }
    }
    m
}

/// Where a ray meets an overlay.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hit {
    pub point: [f32; 3],
    pub normal: [f32; 3],
    /// 0…1 over the overlay, from its bottom left (OpenVR's mouse and UV convention).
    pub uv: [f32; 2],
    pub distance: f32,
}

/// The ray from `origin` along `direction` (unit length) against the overlay at `m` (its picture
/// in the matrix's x-y plane, centered, `width` × `height` meters), front or back.
pub fn overlay_hit(
    m: &Matrix34,
    width: f32,
    height: f32,
    origin: [f32; 3],
    direction: [f32; 3],
) -> Option<Hit> {
    let col = |c: usize| [m[0][c], m[1][c], m[2][c]];
    let dot = |a: [f32; 3], b: [f32; 3]| a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    let (ax, ay, n, center) = (col(0), col(1), col(2), col(3));
    let facing = dot(direction, n);
    if facing.abs() < 1e-6 {
        return None;
    }
    let to = [
        center[0] - origin[0],
        center[1] - origin[1],
        center[2] - origin[2],
    ];
    let t = dot(to, n) / facing;
    if t <= 0.0 {
        return None;
    }
    let point = [
        origin[0] + direction[0] * t,
        origin[1] + direction[1] * t,
        origin[2] + direction[2] * t,
    ];
    let rel = [
        point[0] - center[0],
        point[1] - center[1],
        point[2] - center[2],
    ];
    // The axes may carry a scale: measure along them as unit vectors.
    let (lx, ly) = (sqrt(dot(ax, ax)), sqrt(dot(ay, ay)));
    if lx < 1e-6 || ly < 1e-6 || width <= 0.0 || height <= 0.0 {
        return None;
    }
    let (x, y) = (dot(rel, ax) / lx, dot(rel, ay) / ly);
    if x.abs() > width / 2.0 || y.abs() > height / 2.0 {
        return None;
    }
    let ln = sqrt(dot(n, n)).max(1e-6);
    Some(Hit {
        point,
        normal: [n[0] / ln, n[1] / ln, n[2] / ln],
        uv: [x / width + 0.5, y / height + 0.5],
        distance: t,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_ray_finds_where_it_meets_an_overlay() {
        // An overlay 2 m ahead, facing the viewer (+z toward it), 1 m wide, 0.5 m tall.
        let m = pose_matrix([0.0, 1.5, -2.0], [0.0, 0.0, 0.0, 1.0]);
        let hit = overlay_hit(&m, 1.0, 0.5, [0.0, 1.5, 0.0], [0.0, 0.0, -1.0]).expect("the center");
        assert!(
            (hit.distance - 2.0).abs() < 1e-5
                && (hit.uv[0] - 0.5).abs() < 1e-5
                && (hit.uv[1] - 0.5).abs() < 1e-5
        );
        // Up and right: toward the top right, v from the bottom.
        let d = [0.2f32, 0.1, -2.0];
        let l = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        let hit = overlay_hit(
            &m,
            1.0,
            0.5,
            [0.0, 1.5, 0.0],
            [d[0] / l, d[1] / l, d[2] / l],
        )
        .unwrap();
        assert!(
            (hit.uv[0] - 0.7).abs() < 1e-4 && (hit.uv[1] - 0.7).abs() < 1e-4,
            "{hit:?}"
        );
        // Past its edge, and behind the ray.
        assert!(overlay_hit(&m, 1.0, 0.5, [0.0, 1.5, 0.0], [0.0, 0.8, -0.6]).is_none());
        assert!(overlay_hit(&m, 1.0, 0.5, [0.0, 1.5, 0.0], [0.0, 0.0, 1.0]).is_none());
        // On a hand: turned 90° about y, the overlay faces +x.
        let s = core::f32::consts::FRAC_1_SQRT_2;
        let hand = pose_matrix([1.0, 1.0, 0.0], [0.0, s, 0.0, s]);
        let world = matrix_mul(&hand, &pose_matrix([0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]));
        let hit = overlay_hit(&world, 0.2, 0.2, [3.0, 1.0, 0.0], [-1.0, 0.0, 0.0]).unwrap();
        assert!(
            (hit.distance - 2.0).abs() < 1e-4 && (hit.normal[0] - 1.0).abs() < 1e-4,
            "{hit:?}"
        );
    }

    #[test]
    fn sine_and_cosine_are_close() {
        for i in -400..400 {
            let x = i as f32 * 0.05;
            assert!((sin(x) - libm_sin(x)).abs() < 2e-5, "sin {x}");
            assert!((cos(x) - libm_sin(x + FRAC_PI_2)).abs() < 2e-5, "cos {x}");
        }
        assert!((sqrt(2.0) - core::f32::consts::SQRT_2).abs() < 1e-6);
    }

    fn libm_sin(x: f32) -> f32 {
        // A slower series around 0 after exact folding, as a reference.
        let x = wrap(x) as f64;
        let mut term = x;
        let mut sum = 0.0;
        for k in 0..20 {
            sum += term;
            term *= -x * x / ((2 * k + 2) as f64 * (2 * k + 3) as f64);
        }
        sum as f32
    }

    #[test]
    fn turning_about_y_for_a_quarter_second() {
        let q = rotate_by([0.0, 0.0, 0.0, 1.0], [0.0, 2.0, 0.0], 0.25);
        // 0.5 rad about y.
        assert!((q[1] - sin(0.25)).abs() < 1e-5 && (q[3] - cos(0.25)).abs() < 1e-5);
    }
}
