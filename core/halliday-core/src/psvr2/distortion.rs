//! PS VR2 lens distortion and chromatic aberration correction.
//!
//! Port of Monado's `psvr2_compute_distortion_asymmetric` (`psvr2_distortion.c`, BSL-1.0; Joel
//! Valenciano, Beyley Cardellio; see THIRD-PARTY.md). The arithmetic follows the C code step by
//! step, including where C promotes to `double`, so results match Monado's to the last bit or two;
//! `tests/psvr2_distortion.rs` checks this against outputs of Monado's own function.
//!
//! Direction: for a position on the panel (per-eye `u, v` in 0..1, origin top-left), returns the
//! position in the rendered eye image to sample, separately for red, green and blue. Values
//! outside 0..1 fall outside the rendered image and should be drawn black.

use super::distortion_lut::LUT;

/// Which eye; the left eye is the left half of the 4000×2040 panel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Eye {
    Left = 0,
    Right = 1,
}

/// Source texture coordinates for one panel position, per color channel.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UvTriplet {
    pub r: [f32; 2],
    pub g: [f32; 2],
    pub b: [f32; 2],
}

/// Distortion for one panel position. `calibration` is the 8-parameter set from
/// [`super::protocol::DistortionCalibration`].
pub fn compute(calibration: &[f32; 8], eye: Eye, u: f32, v: f32) -> UvTriplet {
    let cy: f32 = 0.5;
    let fx: f32 = 0.358_556_4;
    let fy: f32 = 0.376_228_1;
    let (k1, k2, k3, k4, cx) = match eye {
        Eye::Left => (
            calibration[0],
            calibration[1],
            calibration[4],
            calibration[5],
            0.660_378_8f32,
        ),
        Eye::Right => (
            calibration[2],
            calibration[3],
            calibration[6],
            calibration[7],
            0.339_621_3f32,
        ),
    };

    // C: float = float + (double expression)
    let local_x = (k1 as f64 + ((u + u) as f64 - 1.0) * 0.980_392_2 * 0.939_498_7) as f32;
    let local_y = (k2 as f64 + ((v + v) as f64 - 1.0) * 0.939_498_7) as f32;
    let r_scaled = ((local_x * local_x + local_y * local_y) as f64 * 1023.0) as f32;

    let index = r_scaled as i32; // C truncation toward zero
    let scale: [f32; 3] = if index > -1 && index + 1 < 0x400 {
        let frac = r_scaled - index as f32;
        let t = LUT[index as usize + 1];
        let t0 = LUT[index as usize];
        std::array::from_fn(|c| {
            (frac as f64 * t[c] as f64 + (1.0 - frac as f64) * t0[c] as f64) as f32
        })
    } else {
        let over = (r_scaled as f64 - 1023.0) as f32;
        [
            (over as f64 * 0.003_648_639 + 1.592_586) as f32,
            (over as f64 * 0.004_862_547 + 1.692_979) as f32,
            (over as f64 * 0.007_425_308 + 1.841_771) as f32,
        ]
    };

    let channel = |c: usize| -> [f32; 2] {
        let y = if c == 1 {
            (local_y as f64 - 0.000_230_269_3) as f32
        } else {
            local_y
        };
        let a = local_x * scale[c];
        let b = y * scale[c];
        [(k3 * a - k4 * b) * fx + cx, (k4 * a + k3 * b) * fy + cy]
    };
    UvTriplet {
        r: channel(0),
        g: channel(1),
        b: channel(2),
    }
}

/// Field of view of one eye, in radians (OpenXR convention: left and down are negative).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fov {
    pub angle_left: f32,
    pub angle_right: f32,
    pub angle_up: f32,
    pub angle_down: f32,
}

/// Per-eye field of view, from Monado: 53° up and down, 61.5° outward and 43.5° inward.
pub fn fov(eye: Eye) -> Fov {
    let (outer, inner) = (61.5f32.to_radians(), 43.5f32.to_radians());
    let vertical = 53.0f32.to_radians();
    match eye {
        Eye::Left => Fov {
            angle_left: -outer,
            angle_right: inner,
            angle_up: vertical,
            angle_down: -vertical,
        },
        Eye::Right => Fov {
            angle_left: -inner,
            angle_right: outer,
            angle_up: vertical,
            angle_down: -vertical,
        },
    }
}

/// Panel resolution: both eyes side by side.
pub const PANEL_WIDTH: u32 = 4000;
pub const PANEL_HEIGHT: u32 = 2040;
/// Resolution of one eye's half of the panel.
pub const EYE_WIDTH: u32 = PANEL_WIDTH / 2;
pub const EYE_HEIGHT: u32 = PANEL_HEIGHT;

/// One vertex of a distortion mesh.
#[derive(Debug, Clone, Copy, PartialEq)]
#[repr(C)]
pub struct MeshVertex {
    /// Panel position of this vertex in the eye's half, 0..1, origin top-left.
    pub position: [f32; 2],
    pub uv_r: [f32; 2],
    pub uv_g: [f32; 2],
    pub uv_b: [f32; 2],
}

/// A grid mesh for one eye: draw its triangles over the eye's half of the panel, interpolate the
/// three UVs, and sample the eye's rendered image once per channel.
#[derive(Debug, Clone, PartialEq)]
pub struct DistortionMesh {
    pub eye: Eye,
    /// Grid cells across and down; vertices are `(cols + 1) × (rows + 1)`, row-major.
    pub cols: u32,
    pub rows: u32,
    pub vertices: Vec<MeshVertex>,
    /// Triangle list, counter-clockwise in panel coordinates with y down.
    pub indices: Vec<u32>,
}

impl DistortionMesh {
    pub fn new(calibration: &[f32; 8], eye: Eye, cols: u32, rows: u32) -> DistortionMesh {
        assert!(cols > 0 && rows > 0);
        let mut vertices = Vec::with_capacity(((cols + 1) * (rows + 1)) as usize);
        for j in 0..=rows {
            for i in 0..=cols {
                let (u, v) = (i as f32 / cols as f32, j as f32 / rows as f32);
                let t = compute(calibration, eye, u, v);
                vertices.push(MeshVertex {
                    position: [u, v],
                    uv_r: t.r,
                    uv_g: t.g,
                    uv_b: t.b,
                });
            }
        }
        let mut indices = Vec::with_capacity((cols * rows * 6) as usize);
        let stride = cols + 1;
        for j in 0..rows {
            for i in 0..cols {
                let tl = j * stride + i;
                let (tr, bl, br) = (tl + 1, tl + stride, tl + stride + 1);
                indices.extend_from_slice(&[tl, bl, tr, tr, bl, br]);
            }
        }
        DistortionMesh {
            eye,
            cols,
            rows,
            vertices,
            indices,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::psvr2::protocol::DistortionCalibration;

    const CAL: [f32; 8] = DistortionCalibration::FALLBACK;

    #[test]
    fn lens_center_maps_to_the_optical_center() {
        // The panel point where local_x = local_y = 0 has no chromatic spread and lands on cx, cy.
        let u = (1.0 + 0.099_192_93 / (0.980_392_2 * 0.939_498_7)) / 2.0;
        let t = compute(&CAL, Eye::Left, u as f32, 0.5);
        assert!(
            (t.r[0] - 0.660_378_8).abs() < 1e-4 && (t.r[1] - 0.5).abs() < 1e-4,
            "{t:?}"
        );
    }

    #[test]
    fn channels_spread_outward_red_least_blue_most() {
        let t = compute(&CAL, Eye::Left, 0.95, 0.5);
        let center = 0.660_378_8;
        let (dr, dg, db) = (t.r[0] - center, t.g[0] - center, t.b[0] - center);
        assert!(dr > 0.0 && dr < dg && dg < db, "{t:?}");
    }

    #[test]
    fn eyes_mirror_each_other_with_the_symmetric_fallback() {
        for (u, v) in [(0.1, 0.2), (0.5, 0.5), (0.8, 0.9)] {
            let l = compute(&CAL, Eye::Left, u, v);
            let r = compute(&CAL, Eye::Right, 1.0 - u, v);
            assert!((l.g[0] - (1.0 - r.g[0])).abs() < 1e-5 && (l.g[1] - r.g[1]).abs() < 1e-6);
        }
    }

    #[test]
    fn fov_is_mirrored() {
        let (l, r) = (fov(Eye::Left), fov(Eye::Right));
        assert_eq!(l.angle_left, -r.angle_right);
        assert_eq!(l.angle_right, -r.angle_left);
        assert!((l.angle_up - 53f32.to_radians()).abs() < 1e-6);
    }

    #[test]
    fn mesh_layout() {
        let m = DistortionMesh::new(&CAL, Eye::Right, 4, 2);
        assert_eq!(m.vertices.len(), 15);
        assert_eq!(m.indices.len(), 48);
        assert_eq!(m.vertices[0].position, [0.0, 0.0]);
        assert_eq!(m.vertices[14].position, [1.0, 1.0]);
        assert_eq!(m.vertices[7].uv_g, compute(&CAL, Eye::Right, 0.5, 0.5).g);
        assert!(m.indices.iter().all(|&i| i < 15));
    }
}
