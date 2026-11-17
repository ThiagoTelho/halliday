//! Bright spots in a camera picture: the controllers' LEDs, before anything knows which is which.
//!
//! A spot is a group of touching pixels at or above a threshold. Each comes back with its
//! brightness-weighted middle (finer than a pixel), its size and its peak, which is what telling
//! LEDs from lamps and reflections needs. Plain flood fill: the pictures are small (half a
//! megapixel) and mostly dark.

/// One bright spot.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Blob {
    /// The middle, in pixels from the picture's top-left corner, weighted by brightness.
    pub x: f32,
    pub y: f32,
    /// Pixels at or above the threshold.
    pub area: u32,
    /// The brightest pixel.
    pub peak: u8,
    /// The box around it, in pixels (inclusive).
    pub min_x: u16,
    pub min_y: u16,
    pub max_x: u16,
    pub max_y: u16,
}

impl Blob {
    pub fn width(&self) -> u32 {
        u32::from(self.max_x - self.min_x) + 1
    }
    pub fn height(&self) -> u32 {
        u32::from(self.max_y - self.min_y) + 1
    }
    /// How much of its box the spot fills: near 0.8 for a round dot, low for a streak or a ring.
    pub fn fill(&self) -> f32 {
        self.area as f32 / (self.width() * self.height()) as f32
    }
}

/// Which spots to keep.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BlobOptions {
    /// A pixel belongs to a spot at or above this.
    pub threshold: u8,
    pub min_area: u32,
    /// Larger than this is a lamp or a window, not an LED.
    pub max_area: u32,
}

impl Default for BlobOptions {
    fn default() -> Self {
        BlobOptions {
            threshold: 200,
            min_area: 3,
            max_area: 600,
        }
    }
}

/// The spots of an 8-bit picture, `width` across, in the rectangle `x0..x1` × `y0..y1`
/// (a frame holds several cameras' pictures; a spot never joins across two). Brightest first.
pub fn find(
    pixels: &[u8],
    width: usize,
    (x0, y0, x1, y1): (usize, usize, usize, usize),
    options: BlobOptions,
) -> Vec<Blob> {
    let height = pixels.len() / width.max(1);
    let (x1, y1) = (x1.min(width), y1.min(height));
    if x0 >= x1 || y0 >= y1 {
        return Vec::new();
    }
    let (w, h) = (x1 - x0, y1 - y0);
    let mut seen = vec![false; w * h];
    let mut stack: Vec<(usize, usize)> = Vec::new();
    let mut blobs = Vec::new();
    for sy in y0..y1 {
        for sx in x0..x1 {
            if pixels[sy * width + sx] < options.threshold || seen[(sy - y0) * w + (sx - x0)] {
                continue;
            }
            seen[(sy - y0) * w + (sx - x0)] = true;
            stack.push((sx, sy));
            let (mut area, mut peak) = (0u32, 0u8);
            let (mut sum, mut sum_x, mut sum_y) = (0f64, 0f64, 0f64);
            let (mut min_x, mut min_y, mut max_x, mut max_y) = (sx, sy, sx, sy);
            while let Some((x, y)) = stack.pop() {
                let p = pixels[y * width + x];
                area += 1;
                peak = peak.max(p);
                let weight = f64::from(p);
                sum += weight;
                sum_x += weight * x as f64;
                sum_y += weight * y as f64;
                min_x = min_x.min(x);
                min_y = min_y.min(y);
                max_x = max_x.max(x);
                max_y = max_y.max(y);
                for ny in y.saturating_sub(1).max(y0)..=(y + 1).min(y1 - 1) {
                    for nx in x.saturating_sub(1).max(x0)..=(x + 1).min(x1 - 1) {
                        let at = (ny - y0) * w + (nx - x0);
                        if !seen[at] && pixels[ny * width + nx] >= options.threshold {
                            seen[at] = true;
                            stack.push((nx, ny));
                        }
                    }
                }
            }
            if area >= options.min_area && area <= options.max_area {
                blobs.push(Blob {
                    // Relative to the rectangle: each camera's picture has its own corner.
                    x: (sum_x / sum) as f32 - x0 as f32,
                    y: (sum_y / sum) as f32 - y0 as f32,
                    area,
                    peak,
                    min_x: (min_x - x0) as u16,
                    min_y: (min_y - y0) as u16,
                    max_x: (max_x - x0) as u16,
                    max_y: (max_y - y0) as u16,
                });
            }
        }
    }
    blobs.sort_by_key(|b| std::cmp::Reverse((b.peak, b.area)));
    blobs
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: usize = 64;
    const H: usize = 48;

    /// A dark picture with soft round dots at the given centres (radius about 2.5 pixels).
    fn picture(dots: &[(f32, f32)]) -> Vec<u8> {
        let mut p = vec![6u8; W * H];
        for &(cx, cy) in dots {
            for y in 0..H {
                for x in 0..W {
                    let d = ((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt();
                    let v = (255.0 * (1.0 - (d / 3.5).powi(2)).max(0.0)) as u8;
                    p[y * W + x] = p[y * W + x].max(v);
                }
            }
        }
        p
    }

    #[test]
    fn dots_are_found_finer_than_a_pixel() {
        let dots = [(10.3, 12.7), (40.0, 30.5), (55.6, 8.2)];
        let found = find(&picture(&dots), W, (0, 0, W, H), BlobOptions::default());
        assert_eq!(found.len(), 3);
        for (cx, cy) in dots {
            let b = found
                .iter()
                .find(|b| (b.x - cx).abs() < 0.2 && (b.y - cy).abs() < 0.2)
                .unwrap_or_else(|| panic!("no spot at {cx}, {cy}: {found:?}"));
            assert!(b.area >= 5 && b.fill() > 0.5 && b.peak > 240);
        }
    }

    #[test]
    fn a_lamp_and_a_speck_are_left_out() {
        let mut p = picture(&[(20.0, 20.0)]);
        // A lamp: a big bright bar. A speck: one hot pixel.
        for y in 2..30 {
            for x in 40..62 {
                p[y * W + x] = 255;
            }
        }
        p[45 * W + 5] = 255;
        let found = find(&p, W, (0, 0, W, H), BlobOptions::default());
        assert_eq!(found.len(), 1, "{found:?}");
        assert!((found[0].x - 20.0).abs() < 0.2);
    }

    #[test]
    fn each_camera_s_picture_is_searched_alone() {
        // One dot across the line between two pictures side by side: half in each.
        let p = picture(&[(32.0, 10.0), (50.0, 40.0)]);
        let left = find(&p, W, (0, 0, 32, H), BlobOptions::default());
        let right = find(&p, W, (32, 0, W, H), BlobOptions::default());
        assert_eq!(left.len(), 1);
        assert_eq!(right.len(), 2);
        // Positions are from each picture's own corner.
        assert!(
            right
                .iter()
                .any(|b| (b.x - 18.0).abs() < 0.2 && (b.y - 40.0).abs() < 0.2)
        );
        assert!(find(&p, W, (10, 10, 10, 20), BlobOptions::default()).is_empty());
    }
}
