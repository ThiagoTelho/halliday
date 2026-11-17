//! Where the tracking LEDs sit on a PS VR2 Sense controller.
//!
//! The numbers are Monado's (`pssense_led_model.h`, BSL-1.0; see THIRD-PARTY.md): the LEDs'
//! places and the way each faces, which Monado's authors read out of Sony's PC driver, the
//! correction they found for the plastic over each LED, and the IMU's place among them. Monado
//! lists both hands; the left one is the right one mirrored, so only the right is kept here.
//!
//! [`sense_leds`] gives them in the IMU's frame (x right, y up, z back as the controller is
//! held), the frame of the orientation `sense.rs` keeps: 14 LEDs around the ring and 3 on the
//! far side of the handle.

use crate::sense::Hand;

pub const LED_COUNT: usize = 17;

/// One LED, in the IMU's frame.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Led {
    /// Where its light leaves the plastic, in meters from the IMU.
    pub position: [f64; 3],
    /// The way it faces (unit length).
    pub normal: [f64; 3],
}

/// The right controller's LEDs in the model's own frame.
const POSITIONS: [[f64; 3]; LED_COUNT] = [
    [0.012054, -0.055213, 0.038152],
    [0.033088, -0.055236, 0.020190],
    [0.053695, -0.031009, 0.028350],
    [0.066986, -0.010505, 0.008679],
    [0.063505, 0.024601, 0.004185],
    [0.047803, 0.044966, 0.018502],
    [-0.045472, -0.027042, 0.043022],
    [-0.059535, -0.013977, 0.028536],
    [-0.061060, 0.014608, 0.024725],
    [-0.050994, 0.027255, 0.036184],
    [-0.048475, 0.043025, 0.018776],
    [-0.030569, 0.053446, 0.029350],
    [-0.018498, 0.063913, 0.011230],
    [0.002748, 0.064260, 0.022718],
    [0.029078, 0.013435, -0.060735],
    [-0.001067, 0.013435, -0.067327],
    [-0.031783, 0.013435, -0.059270],
];

const NORMALS: [[f64; 3]; LED_COUNT] = [
    [0.176485, -0.811967, 0.556384],
    [0.426232, -0.891845, -0.151455],
    [0.788493, -0.456350, 0.412339],
    [0.980055, -0.153898, 0.125726],
    [0.930796, 0.360502, 0.060482],
    [0.701817, 0.660177, 0.267618],
    [-0.667492, -0.396842, 0.630056],
    [-0.961512, -0.273488, -0.026435],
    [-0.984435, 0.154641, -0.083507],
    [-0.748123, 0.399672, 0.529693],
    [-0.795992, 0.580182, -0.172584],
    [-0.448555, 0.783814, 0.429458],
    [-0.346695, 0.893406, -0.285708],
    [0.040150, 0.942362, 0.332178],
    [0.417589, 0.258817, -0.870996],
    [-0.014114, 0.258800, -0.965828],
    [-0.458628, 0.258803, -0.850106],
];

/// From each LED's listed place to where its light leaves the plastic (Monado's correction,
/// from a bundle adjustment of their own tracking data), right controller.
const EMISSION: [[f64; 3]; LED_COUNT] = [
    [0.000262, -0.001698, 0.000803],
    [0.000599, -0.001296, -0.000481],
    [0.001550, -0.001087, 0.000603],
    [0.001588, -0.000457, -0.000046],
    [0.001498, 0.000488, -0.000025],
    [0.001238, 0.000888, 0.000272],
    [-0.000983, -0.000921, 0.001300],
    [-0.001169, -0.000671, -0.000025],
    [-0.001315, -0.000090, -0.000021],
    [-0.001246, 0.000856, 0.000855],
    [-0.001071, 0.000414, -0.000405],
    [-0.000537, 0.001162, 0.000544],
    [-0.000372, 0.000718, -0.000602],
    [0.000399, 0.001257, 0.000289],
    [0.000331, 0.000033, -0.001030],
    [-0.000125, 0.000117, -0.001062],
    [-0.000648, 0.000286, -0.000970],
];

/// The IMU's place in the model's frame. The IMU sits on the same side in both controllers, so
/// this is not mirrored.
const IMU_LEFT: [f64; 3] = [0.0093727, -0.0122481, -0.0060039];
const IMU_RIGHT: [f64; 3] = [-0.0200727, -0.0122481, -0.0060039];
/// The IMU's frame is the model's turned about x by this.
const IMU_ANGLE_DEG: f64 = -50.2703;

/// A controller's LEDs in its IMU's frame.
pub fn sense_leds(hand: Hand) -> [Led; LED_COUNT] {
    let (mirror, imu) = match hand {
        Hand::Left => (-1.0, IMU_LEFT),
        Hand::Right => (1.0, IMU_RIGHT),
    };
    let (s, c) = IMU_ANGLE_DEG.to_radians().sin_cos();
    // The inverse of the turn about x: a vector of the model's frame, seen from the IMU's.
    let turn = |v: [f64; 3]| [v[0], c * v[1] + s * v[2], -s * v[1] + c * v[2]];
    std::array::from_fn(|i| {
        let (p, e, n) = (POSITIONS[i], EMISSION[i], NORMALS[i]);
        Led {
            position: turn([
                mirror * (p[0] + e[0]) - imu[0],
                p[1] + e[1] - imu[1],
                p[2] + e[2] - imu[2],
            ]),
            normal: turn([mirror * n[0], n[1], n[2]]),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn distance(a: [f64; 3], b: [f64; 3]) -> f64 {
        ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
    }

    #[test]
    fn the_layout_is_a_controller_sized_ring() {
        for hand in [Hand::Left, Hand::Right] {
            let leds = sense_leds(hand);
            let mut widest: f64 = 0.0;
            for a in &leds {
                let n = a.normal;
                assert!(((n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt() - 1.0).abs() < 1e-3);
                let nearest = leds
                    .iter()
                    .filter(|b| *b != a)
                    .map(|b| distance(a.position, b.position))
                    .fold(f64::MAX, f64::min);
                assert!((0.015..0.04).contains(&nearest), "{nearest}");
                for b in &leds {
                    widest = widest.max(distance(a.position, b.position));
                }
            }
            assert!((0.13..0.16).contains(&widest), "{widest}");
        }
    }

    #[test]
    fn the_hands_are_mirror_images_about_different_imu_places() {
        let (left, right) = (sense_leds(Hand::Left), sense_leds(Hand::Right));
        for (l, r) in left.iter().zip(&right) {
            // Mirrored in x, then each moved by its own IMU's place (x only differs).
            let shift = l.position[0] + r.position[0];
            assert!((shift - (-IMU_LEFT[0] - IMU_RIGHT[0])).abs() < 1e-9);
            assert!((l.position[1] - r.position[1]).abs() < 1e-9);
            assert!((l.position[2] - r.position[2]).abs() < 1e-9);
            assert!((l.normal[0] + r.normal[0]).abs() < 1e-9);
        }
        // Monado's left LED 0, by hand: (-0.012054 - 0.000262 - 0.0093727, …) before the turn.
        assert!((left[0].position[0] - (-0.0216887)).abs() < 1e-6);
    }
}
