//! Small rotation/pose math, enough for tracking. Conventions: right-handed, x right, y up, −z
//! forward (OpenXR). Quaternions are Hamilton, `w` first, and `a * b` applies `b` first.

use std::ops::{Mul, Neg};

pub type Vec3 = [f32; 3];

/// Unit quaternion, `w` first (the order used on the PS VR2 wire too).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Quat {
    pub w: f32,
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Default for Quat {
    fn default() -> Quat {
        Quat::IDENTITY
    }
}

impl Quat {
    pub const IDENTITY: Quat = Quat {
        w: 1.0,
        x: 0.0,
        y: 0.0,
        z: 0.0,
    };

    pub fn dot(self, o: Quat) -> f32 {
        self.w * o.w + self.x * o.x + self.y * o.y + self.z * o.z
    }

    /// From `self` towards `o` by `t` (0..1), the short way: for small turns (a straight blend,
    /// made a unit quaternion again).
    pub fn nlerp(self, o: Quat, t: f32) -> Quat {
        let s = if self.dot(o) < 0.0 { -t } else { t };
        Quat {
            w: self.w * (1.0 - t) + o.w * s,
            x: self.x * (1.0 - t) + o.x * s,
            y: self.y * (1.0 - t) + o.y * s,
            z: self.z * (1.0 - t) + o.z * s,
        }
        .normalized()
    }

    pub fn conjugate(self) -> Quat {
        Quat {
            w: self.w,
            x: -self.x,
            y: -self.y,
            z: -self.z,
        }
    }

    pub fn normalized(self) -> Quat {
        let n = self.dot(self).sqrt();
        if n < 1e-12 {
            return Quat::IDENTITY;
        }
        Quat {
            w: self.w / n,
            x: self.x / n,
            y: self.y / n,
            z: self.z / n,
        }
    }

    /// Rotation of `angle` radians about the unit `axis`.
    pub fn from_axis_angle(axis: Vec3, angle: f32) -> Quat {
        let (s, c) = (angle * 0.5).sin_cos();
        Quat {
            w: c,
            x: axis[0] * s,
            y: axis[1] * s,
            z: axis[2] * s,
        }
    }

    /// Rotation by the rotation vector `v` (axis × angle in radians): the quaternion exponential.
    /// `from_rotation_vector(gyro * dt)` is the rotation a body spinning at `gyro` makes in `dt`.
    pub fn from_rotation_vector(v: Vec3) -> Quat {
        let h = [v[0] * 0.5, v[1] * 0.5, v[2] * 0.5];
        let angle = (h[0] * h[0] + h[1] * h[1] + h[2] * h[2]).sqrt();
        if angle < 1e-9 {
            return Quat {
                w: 1.0,
                x: h[0],
                y: h[1],
                z: h[2],
            }
            .normalized();
        }
        let s = angle.sin() / angle;
        Quat {
            w: angle.cos(),
            x: h[0] * s,
            y: h[1] * s,
            z: h[2] * s,
        }
    }

    /// Rotates a vector.
    pub fn rotate(self, v: Vec3) -> Vec3 {
        // v' = v + 2w(u × v) + 2u × (u × v), u = (x, y, z)
        let u = [self.x, self.y, self.z];
        let t = scale(cross(u, v), 2.0);
        add(add(v, scale(t, self.w)), cross(u, t))
    }

    /// Heading about +y: the angle of the rotated forward (−z) vector in the horizontal plane,
    /// positive when turned left (counter-clockwise seen from above).
    pub fn yaw(self) -> f32 {
        let f = self.rotate([0.0, 0.0, -1.0]);
        (-f[0]).atan2(-f[2])
    }

    /// Angle in radians between two orientations.
    pub fn angle_to(self, o: Quat) -> f32 {
        2.0 * self.dot(o).abs().min(1.0).acos()
    }
}

impl Mul for Quat {
    type Output = Quat;

    /// Hamilton product: `(a * b).rotate(v) == a.rotate(b.rotate(v))`.
    fn mul(self, b: Quat) -> Quat {
        let a = self;
        Quat {
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        }
    }
}

impl Neg for Quat {
    type Output = Quat;

    /// The same rotation with all components negated (q and −q represent one rotation).
    fn neg(self) -> Quat {
        Quat {
            w: -self.w,
            x: -self.x,
            y: -self.y,
            z: -self.z,
        }
    }
}

/// Rigid transform: rotate, then translate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pose {
    pub position: Vec3,
    pub orientation: Quat,
}

impl Pose {
    pub const IDENTITY: Pose = Pose {
        position: [0.0; 3],
        orientation: Quat::IDENTITY,
    };

    /// `self ∘ inner`: `inner` expressed in `self`'s frame.
    pub fn compose(self, inner: Pose) -> Pose {
        Pose {
            position: add(self.position, self.orientation.rotate(inner.position)),
            orientation: (self.orientation * inner.orientation).normalized(),
        }
    }

    pub fn inverse(self) -> Pose {
        let q = self.orientation.conjugate();
        Pose {
            position: scale(q.rotate(self.position), -1.0),
            orientation: q,
        }
    }
}

pub fn add(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

pub fn sub(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

pub fn scale(a: Vec3, s: f32) -> Vec3 {
    [a[0] * s, a[1] * s, a[2] * s]
}

pub fn cross(a: Vec3, b: Vec3) -> Vec3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

pub fn length(a: Vec3) -> f32 {
    (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).sqrt()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::f32::consts::FRAC_PI_2;

    pub fn assert_vec(a: Vec3, b: Vec3, eps: f32) {
        assert!(length(sub(a, b)) < eps, "{a:?} != {b:?}");
    }

    pub fn assert_quat(a: Quat, b: Quat, eps: f32) {
        assert!(
            a.angle_to(b) < eps,
            "{a:?} != {b:?} (angle {})",
            a.angle_to(b)
        );
    }

    #[test]
    fn rotate_about_axes() {
        let yaw_left = Quat::from_axis_angle([0.0, 1.0, 0.0], FRAC_PI_2);
        assert_vec(yaw_left.rotate([0.0, 0.0, -1.0]), [-1.0, 0.0, 0.0], 1e-6);
        let roll = Quat::from_axis_angle([0.0, 0.0, 1.0], FRAC_PI_2);
        assert_vec(roll.rotate([1.0, 0.0, 0.0]), [0.0, 1.0, 0.0], 1e-6);
    }

    #[test]
    fn product_applies_right_operand_first() {
        let a = Quat::from_axis_angle([0.0, 1.0, 0.0], 0.7);
        let b = Quat::from_axis_angle([1.0, 0.0, 0.0], -0.3);
        let v = [0.2, -0.5, 0.9];
        assert_vec((a * b).rotate(v), a.rotate(b.rotate(v)), 1e-5);
    }

    #[test]
    fn rotation_vector_matches_axis_angle() {
        let q = Quat::from_rotation_vector([0.0, 0.0, 1.2]);
        assert_quat(q, Quat::from_axis_angle([0.0, 0.0, 1.0], 1.2), 1e-6);
        assert_quat(Quat::from_rotation_vector([0.0; 3]), Quat::IDENTITY, 1e-7);
        // Many small steps add up to one big rotation.
        let mut acc = Quat::IDENTITY;
        for _ in 0..1000 {
            acc = acc * Quat::from_rotation_vector([0.0, 0.001, 0.0]);
        }
        assert_quat(acc, Quat::from_axis_angle([0.0, 1.0, 0.0], 1.0), 1e-4);
    }

    #[test]
    fn yaw_sign_and_range() {
        for deg in [-170.0f32, -45.0, 0.0, 30.0, 120.0] {
            let q = Quat::from_axis_angle([0.0, 1.0, 0.0], deg.to_radians());
            assert!((q.yaw() - deg.to_radians()).abs() < 1e-5, "{deg}");
        }
        // Pitch alone does not change yaw.
        let pitch = Quat::from_axis_angle([1.0, 0.0, 0.0], 0.5);
        assert!(pitch.yaw().abs() < 1e-6);
    }

    #[test]
    fn pose_compose_and_inverse() {
        let p = Pose {
            position: [1.0, 2.0, 3.0],
            orientation: Quat::from_axis_angle([0.0, 1.0, 0.0], FRAC_PI_2),
        };
        let offset = Pose {
            position: [0.0, 0.0, -1.0],
            orientation: Quat::IDENTITY,
        };
        // One meter "forward" in a frame turned 90 degrees left is one meter toward -x.
        assert_vec(p.compose(offset).position, [0.0, 2.0, 3.0], 1e-6);
        let id = p.compose(p.inverse());
        assert_vec(id.position, [0.0; 3], 1e-6);
        assert_quat(id.orientation, Quat::IDENTITY, 1e-6);
    }
}
