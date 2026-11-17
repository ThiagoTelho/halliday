//! Pictures the game side copies into the bridge from a game's textures: overlays and the skybox
//! (OpenVR's `IVROverlay::SetOverlayTexture`, `IVRCompositor::SetSkyboxOverride`).
//!
//! Every picture in the bridge is RGBA8, rows top-down, alpha premultiplied, whatever the game's
//! texture was (BGRA, OpenGL's bottom-up rows). A texture larger than the bridge's area is scaled
//! down by a whole factor, averaging each block of texels. A skybox given as a cube's six faces
//! becomes one equirectangular picture (longitude across, the forward direction, -z, in the
//! middle; latitude down from straight up), as Halliday shows 360° pictures.

use crate::math;
use core::f32::consts::PI;

/// A game texture's pixels, mapped for reading.
#[derive(Clone, Copy, Debug)]
pub struct Source {
    pub ptr: *const u8,
    /// Bytes from one row to the next in memory.
    pub pitch: usize,
    pub width: u32,
    pub height: u32,
    /// B, G, R, A in memory (Direct3D's BGRA formats); else R, G, B, A.
    pub bgra: bool,
    /// The first row in memory is the bottom one (OpenGL).
    pub bottom_up: bool,
    /// The alpha channel means nothing (an X8 format, a skybox): treated as 255.
    pub opaque: bool,
    /// Alpha is already premultiplied.
    pub premultiplied: bool,
}

impl Source {
    /// The texel at (`x`, `y`), `y` counted from the top, as premultiplied RGBA.
    ///
    /// # Safety
    /// `ptr` holds `height` rows of `pitch` bytes, each at least `width * 4`.
    #[inline]
    unsafe fn texel(&self, x: u32, y: u32) -> [u32; 4] {
        let row = if self.bottom_up {
            self.height - 1 - y
        } else {
            y
        };
        // SAFETY: inside the mapped rows (caller).
        let p = unsafe { self.ptr.add(row as usize * self.pitch + x as usize * 4) };
        // SAFETY: four bytes of the texel.
        let b = unsafe { [*p, *p.add(1), *p.add(2), *p.add(3)] };
        let (r, g, bl) = if self.bgra {
            (b[2], b[1], b[0])
        } else {
            (b[0], b[1], b[2])
        };
        let a = if self.opaque { 255 } else { b[3] as u32 };
        if self.premultiplied || a == 255 {
            [r as u32, g as u32, bl as u32, a]
        } else {
            [
                (r as u32 * a + 127) / 255,
                (g as u32 * a + 127) / 255,
                (bl as u32 * a + 127) / 255,
                a,
            ]
        }
    }
}

/// The size `width` × `height` becomes in an area of at most `max_w` × `max_h`: divided by the
/// smallest whole factor that fits, and that factor.
pub fn scaled_size(width: u32, height: u32, max_w: u32, max_h: u32) -> (u32, u32, u32) {
    let k = width
        .div_ceil(max_w.max(1))
        .max(height.div_ceil(max_h.max(1)))
        .max(1);
    ((width / k).max(1), (height / k).max(1), k)
}

/// Copies `src` into `dst` (RGBA, top-down, premultiplied), scaled down to fit `max_w` × `max_h`.
/// Returns the size written.
///
/// # Safety
/// `src` is readable as described; `dst` holds `max_w * max_h * 4` bytes.
pub unsafe fn copy_scaled(src: &Source, dst: *mut u8, max_w: u32, max_h: u32) -> (u32, u32) {
    let (w, h, k) = scaled_size(src.width, src.height, max_w, max_h);
    let n = k * k;
    for y in 0..h {
        for x in 0..w {
            let mut sum = [0u32; 4];
            for dy in 0..k {
                for dx in 0..k {
                    // SAFETY: inside the source (x*k+dx < width, y*k+dy < height).
                    let t = unsafe { src.texel(x * k + dx, y * k + dy) };
                    for c in 0..4 {
                        sum[c] += t[c];
                    }
                }
            }
            // SAFETY: inside `dst` (w <= max_w, h <= max_h).
            unsafe {
                let d = dst.add(((y * w + x) * 4) as usize);
                for (c, s) in sum.iter().enumerate() {
                    *d.add(c) = ((s + n / 2) / n) as u8;
                }
            }
        }
    }
    (w, h)
}

/// Copies `src` into `dst`, an exact `w` × `h` (nearest texel): an equirectangular skybox of any
/// size into the bridge's.
///
/// # Safety
/// `src` is readable as described; `dst` holds `w * h * 4` bytes.
pub unsafe fn resample(src: &Source, dst: *mut u8, w: u32, h: u32) {
    for y in 0..h {
        let sy = ((y as u64 * 2 + 1) * src.height as u64 / (h as u64 * 2)) as u32;
        for x in 0..w {
            let sx = ((x as u64 * 2 + 1) * src.width as u64 / (w as u64 * 2)) as u32;
            // SAFETY: inside both.
            unsafe {
                let t = src.texel(sx.min(src.width - 1), sy.min(src.height - 1));
                let d = dst.add(((y * w + x) * 4) as usize);
                for (c, v) in t.iter().enumerate() {
                    *d.add(c) = *v as u8;
                }
            }
        }
    }
}

/// Turns RGBA rows read straight into the bridge (OpenGL's, bottom-up, straight alpha) into a
/// picture: top-down, premultiplied.
///
/// # Safety
/// `px` holds `w * h * 4` bytes.
pub unsafe fn finish_in_place(px: *mut u8, w: u32, h: u32, bottom_up: bool) {
    let row = w as usize * 4;
    if bottom_up {
        for y in 0..(h / 2) as usize {
            // SAFETY: two distinct rows inside `px`.
            unsafe {
                core::ptr::swap_nonoverlapping(
                    px.add(y * row),
                    px.add((h as usize - 1 - y) * row),
                    row,
                )
            };
        }
    }
    for i in 0..(w * h) as usize {
        // SAFETY: inside `px`.
        unsafe {
            let p = px.add(i * 4);
            let a = *p.add(3) as u32;
            if a != 255 {
                for c in 0..3 {
                    *p.add(c) = ((*p.add(c) as u32 * a + 127) / 255) as u8;
                }
            }
        }
    }
}

/// The cube's faces, in OpenVR's order (`EVRSkyboxFaces`).
pub const FRONT: usize = 0;
pub const BACK: usize = 1;
pub const LEFT: usize = 2;
pub const RIGHT: usize = 3;
pub const TOP: usize = 4;
pub const BOTTOM: usize = 5;

/// The face a direction meets and where on it (u right, v down, 0..1), each face seen from the
/// center: the side faces upright; the top with the back (+z) at its top edge, the bottom with
/// the front (-z) at its top edge (as Unity's SteamVR plugin renders them).
pub fn cube_face(d: [f32; 3]) -> (usize, f32, f32) {
    let (ax, ay, az) = (d[0].abs(), d[1].abs(), d[2].abs());
    let (face, right, up, m) = if az >= ax && az >= ay {
        if d[2] < 0.0 {
            (FRONT, d[0], d[1], az)
        } else {
            (BACK, -d[0], d[1], az)
        }
    } else if ax >= ay {
        if d[0] < 0.0 {
            (LEFT, -d[2], d[1], ax)
        } else {
            (RIGHT, d[2], d[1], ax)
        }
    } else if d[1] > 0.0 {
        (TOP, d[0], d[2], ay)
    } else {
        (BOTTOM, d[0], -d[2], ay)
    };
    (face, (right / m + 1.0) * 0.5, (1.0 - up / m) * 0.5)
}

/// The direction of equirectangular pixel (`x`, `y`) of `w` × `h`.
pub fn equirect_direction(x: u32, y: u32, w: u32, h: u32) -> [f32; 3] {
    let lon = ((x as f32 + 0.5) / w as f32) * 2.0 * PI - PI;
    let lat = PI * 0.5 - ((y as f32 + 0.5) / h as f32) * PI;
    let (cl, sl) = (math::cos(lat), math::sin(lat));
    [cl * math::sin(lon), sl, -cl * math::cos(lon)]
}

/// Paints the pixels of the `w` × `h` equirectangular `dst` that look at cube face `face`, from
/// `src`. Called once per face (each mapped in turn).
///
/// # Safety
/// `src` is readable as described; `dst` holds `w * h * 4` bytes.
pub unsafe fn cube_face_to_equirect(face: usize, src: &Source, dst: *mut u8, w: u32, h: u32) {
    for y in 0..h {
        for x in 0..w {
            let (f, u, v) = cube_face(equirect_direction(x, y, w, h));
            if f != face {
                continue;
            }
            let sx = ((u * src.width as f32) as u32).min(src.width - 1);
            let sy = ((v * src.height as f32) as u32).min(src.height - 1);
            // SAFETY: inside both.
            unsafe {
                let t = src.texel(sx, sy);
                let d = dst.add(((y * w + x) * 4) as usize);
                for (c, val) in t.iter().enumerate() {
                    *d.add(c) = *val as u8;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(px: &[u8], w: u32, h: u32) -> Source {
        Source {
            ptr: px.as_ptr(),
            pitch: w as usize * 4,
            width: w,
            height: h,
            bgra: false,
            bottom_up: false,
            opaque: false,
            premultiplied: false,
        }
    }

    #[test]
    fn bgra_bottom_up_becomes_rgba_top_down_premultiplied() {
        // Two rows: bottom (first in memory) blue half-transparent, top opaque red, as BGRA.
        let px = [255, 0, 0, 128, 0, 0, 255, 255];
        let mut s = source(&px, 1, 2);
        s.bgra = true;
        s.bottom_up = true;
        let mut out = [0u8; 8];
        let size = unsafe { copy_scaled(&s, out.as_mut_ptr(), 4, 4) };
        assert_eq!(size, (1, 2));
        assert_eq!(out, [255, 0, 0, 255, 0, 0, 128, 128]);
    }

    #[test]
    fn too_large_is_averaged_down_by_a_whole_factor() {
        assert_eq!(scaled_size(4096, 1024, 2048, 2048), (2048, 512, 2));
        assert_eq!(scaled_size(3000, 100, 2048, 2048), (1500, 50, 2));
        assert_eq!(scaled_size(5000, 10, 2048, 2048), (1666, 3, 3));
        let px = [
            0, 0, 0, 255, 200, 100, 50, 255, //
            0, 0, 0, 255, 200, 100, 50, 255,
        ];
        let mut out = [0u8; 4];
        let size = unsafe { copy_scaled(&source(&px, 2, 2), out.as_mut_ptr(), 1, 1) };
        assert_eq!(size, (1, 1));
        assert_eq!(out, [100, 50, 25, 255]);
    }

    #[test]
    fn opengl_rows_are_turned_and_premultiplied_in_place() {
        let mut px = [1, 2, 3, 255, 200, 100, 50, 0, 10, 20, 30, 255];
        unsafe { finish_in_place(px.as_mut_ptr(), 1, 3, true) };
        assert_eq!(px, [10, 20, 30, 255, 0, 0, 0, 0, 1, 2, 3, 255]);
    }

    #[test]
    fn opaque_ignores_alpha() {
        let px = [10, 20, 30, 0];
        let mut s = source(&px, 1, 1);
        s.opaque = true;
        let mut out = [0u8; 4];
        unsafe { copy_scaled(&s, out.as_mut_ptr(), 1, 1) };
        assert_eq!(out, [10, 20, 30, 255]);
    }

    #[test]
    fn cube_faces_are_where_the_viewer_looks() {
        let near = |a: f32, b: f32| (a - b).abs() < 1e-4;
        let (f, u, v) = cube_face([0.0, 0.0, -1.0]);
        assert!(f == FRONT && near(u, 0.5) && near(v, 0.5));
        // A bit to the right and up on the front face: right of center, above it.
        let (f, u, v) = cube_face([0.5, 0.5, -1.0]);
        assert!(f == FRONT && near(u, 0.75) && near(v, 0.25));
        assert_eq!(cube_face([0.0, 0.0, 1.0]).0, BACK);
        assert_eq!(cube_face([-1.0, 0.0, 0.0]).0, LEFT);
        // Looking left, the front (-z) is on the viewer's right.
        let (_, u, _) = cube_face([-1.0, 0.0, -0.5]);
        assert!(near(u, 0.75));
        assert_eq!(cube_face([1.0, 0.0, 0.0]).0, RIGHT);
        // Up: the back is at the top edge of the top face.
        let (f, _, v) = cube_face([0.0, 1.0, 0.5]);
        assert!(f == TOP && near(v, 0.25));
        // Down: the front is at the top edge of the bottom face.
        let (f, _, v) = cube_face([0.0, -1.0, -0.5]);
        assert!(f == BOTTOM && near(v, 0.25));
    }

    #[test]
    fn equirect_middle_looks_forward_and_top_looks_up() {
        let d = equirect_direction(512, 256, 1024, 512);
        assert!(d[2] < -0.99, "{d:?}");
        let d = equirect_direction(0, 0, 1024, 512);
        assert!(d[1] > 0.99, "{d:?}");
        // A quarter across: left (lon -90°).
        let d = equirect_direction(256, 256, 1024, 512);
        assert!(d[0] < -0.99, "{d:?}");
    }

    #[test]
    fn a_cube_of_six_colors_fills_the_equirect() {
        let colors: [[u8; 4]; 6] = [
            [255, 0, 0, 255],
            [0, 255, 0, 255],
            [0, 0, 255, 255],
            [255, 255, 0, 255],
            [255, 0, 255, 255],
            [0, 255, 255, 255],
        ];
        let (w, h) = (64u32, 32u32);
        let mut out = [0u8; 64 * 32 * 4];
        for (face, c) in colors.iter().enumerate() {
            let px = [*c; 4].concat();
            unsafe { cube_face_to_equirect(face, &source(&px, 2, 2), out.as_mut_ptr(), w, h) };
        }
        let at = |x: u32, y: u32| &out[((y * w + x) * 4) as usize..((y * w + x) * 4 + 4) as usize];
        assert_eq!(at(32, 16), &colors[FRONT]);
        assert_eq!(at(0, 16), &colors[BACK]);
        assert_eq!(at(16, 16), &colors[LEFT]);
        assert_eq!(at(48, 16), &colors[RIGHT]);
        assert_eq!(at(32, 0), &colors[TOP]);
        assert_eq!(at(32, 31), &colors[BOTTOM]);
        assert!(out.chunks(4).all(|p| p[3] == 255), "every pixel painted");
    }
}
