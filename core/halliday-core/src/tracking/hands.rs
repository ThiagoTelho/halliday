//! Where a Sense controller is, from the bright spots the bottom cameras see.
//!
//! The controller's IMU already says how it is turned, except for its heading, which drifts.
//! So its LEDs form a known shape in space, and only where that shape sits (three numbers) and
//! the heading (one) are left to find. No LED has to be told from another first:
//!
//! 1. spots at the same height in both pictures are taken as one point in space each
//!    ([`StereoPair::triangulate`]), wrong pairs included;
//! 2. every (point, LED) couple proposes a place for the controller, and the place most
//!    couples agree on wins (`vote`);
//! 3. from there the LEDs that face the cameras are drawn into both pictures, each takes the
//!    nearest spot, and the place is refined on those until it settles (`assign`,
//!    `solve_position`), the heading with it.
//!
//! A controller that was found a moment ago skips the vote and starts from its last place.
//! One that has been lost for half a second tries every heading.
//!
//! [`calibrate`] is the fit that gave [`super::stereo::PSVR2_BOTTOM`]: the same sightings,
//! with the cameras' numbers as the unknowns.
//!
//! [`camera_place`] found where the cameras sit on the headset
//! ([`super::stereo::PSVR2_BOTTOM_PLACE`]), which takes a place from the camera's frame to the
//! head's and so to the room.
//!
//! Not here yet: the LEDs' pulses in step with the exposure (under half the frames show them)
//! and the fusion with the IMU between pictures.

use super::leds::{LED_COUNT, Led, sense_leds};
use super::stereo::{
    Camera, M3, StereoPair, V3, apply, from_quat, from_rotation_vector, mul, transpose, turn_y,
};
use crate::math::Quat;
use crate::sense::Hand;

#[path = "hand_pair.rs"]
mod pair;
pub use pair::{PairDiagnostics, PairedHandTracker};

/// A bright spot of one picture: its middle in pixels and its size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Spot {
    pub x: f32,
    pub y: f32,
    pub area: u32,
}

/// A controller found in one exposure.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fix {
    /// The IMU's place in the camera's frame (left camera, x right, y down, z forward), meters.
    pub position: [f32; 3],
    /// What has to be added to the IMU's heading (a turn about up) for the LEDs to fit, radians.
    pub heading: f32,
    /// What "up" is off by between the controller's IMU and the head's tracking, as seen by the
    /// cameras: small turns about the tracking space's x and z, radians. Found only with four
    /// LEDs or more in both pictures, kept from the last time otherwise.
    pub tilt: [f32; 2],
    /// LEDs matched to spots, counting each picture.
    pub sightings: u32,
    /// How far the matched spots are from where the LEDs should appear, pixels (root mean square).
    pub rms: f32,
}

impl Fix {
    /// The whole turn the cameras put on the IMU's orientation, in the tracking space: the lean,
    /// then the heading (`correction * imu` is how the controller is really turned). With the
    /// heading alone, the pointer's pitch and roll were the IMU's, whose "up" a hand in motion
    /// puts off by up to 20°.
    pub fn correction(&self) -> Quat {
        let lean = Quat::from_rotation_vector([self.tilt[0], 0.0, self.tilt[1]]);
        (lean * Quat::from_axis_angle([0.0, 1.0, 0.0], self.heading)).normalized()
    }
}

/// Spots this small or this large are left out of the pairing (noise; lamps and merged LEDs).
const PAIR_AREA: std::ops::RangeInclusive<u32> = 4..=450;
/// Two spots are one point when their heights differ by less than this, pixels.
const PAIR_ROWS: f32 = 1.5;
/// … and when they are this far apart sideways (20 cm to 1.8 m away).
const PAIR_DISPARITY: std::ops::Range<f64> = 15.0..320.0;
/// The points kept for the vote (brightest first, as the spots come).
const MAX_POINTS: usize = 24;
/// Proposals within this of each other agree, meters.
const VOTE_REACH: f64 = 0.012;
/// An LED counts as facing a camera from this cosine on: up to edge-on, as Monado has it (90°).
/// (0.1 found a fifth fewer controllers on the first capture.)
const FACING: f64 = 0.0;
/// How near a spot must be to an LED's expected place, pixels, tightening as the fit settles.
const RADII_SEARCH: [f64; 4] = [14.0, 9.0, 6.0, 4.0];
const RADII_FOLLOW: [f64; 3] = [10.0, 6.0, 4.0];
/// A fix needs this many sightings and a spread under this, pixels.
const MIN_SIGHTINGS: usize = 5;
const MAX_RMS: f64 = 2.0;
/// A fix found by trying every heading needs more, and a closer fit: in the capture the
/// cameras were fitted on, a wrong heading 6° off passed with 8 sightings at 1.97 px.
const SCAN_SIGHTINGS: usize = 8;
const SCAN_RMS: f64 = 1.2;
/// The lean is looked for from this many sightings on, and never taken beyond this, radians
/// (20°). The captures at rest differ by 1.5° on where "up" is for the cameras, but a hand in
/// fast motion puts its IMU's "up" off by much more: on a fast capture, 4° found
/// the controllers in 1 960 and 2 345 exposures, 20° (with the hold and the search below) in
/// 2 279 and 3 002, with fewer jumps.
const TILT_SIGHTINGS: usize = 8;
const MAX_TILT: f64 = 0.35;
/// How strongly a fix's lean is held to the one in use (in the fit's own units, px² per rad²:
/// a tenth of one exposure's sightings or so), except when every heading is tried: enough to
/// keep four LEDs from passing a step aside for a lean, little enough to follow a hand's.
const TILT_HOLD: f64 = 1e4;
/// A heading correction is the IMU's drift: a few degrees a minute (12 at most, measured). A fix
/// that moves it farther than this from the one in use is a lock on the LED ring turned the wrong
/// way (four LEDs in each picture fit the ring at several headings, and closely: on a fast
/// capture one fitted at 0.53 px, 123° off, and was followed for a second), unless
/// this many LEDs agree.
const HEADING_JUMP: f64 = 25.0 * std::f64::consts::PI / 180.0;
const JUMP_SIGHTINGS: usize = 12;
/// While lost, the headings tried are those within this many 6° steps of the one in use, until
/// the controller has been lost this long: then all of them (it may have been put down, slept,
/// and woken with a new heading of its own).
const SCAN_NEAR_STEPS: i32 = 5;
const RESCAN_AFTER: u32 = 180;
/// Frames a last place stays worth starting from, and frames lost before every heading is tried.
const FOLLOW_FRAMES: u32 = 6;
const SCAN_AFTER: u32 = 4;
/// While lost, every heading is tried at every other exposure: 60 fits, a millisecond or two
/// when many spots are in sight (and this still runs on the app's main thread).
const SCAN_EVERY: u32 = 2;
/// Farther than this from the cameras is not a hand, meters.
const MAX_REACH: f64 = 1.0;
/// While lost, each camera alone is tried at every other exposure (a millisecond or so).
const ALONE_EVERY: u32 = 2;
const ALONE_SIGHTINGS: usize = 6;
/// Cold monocular acquisition has no stereo points to seed the yaw scan. Spread the scan
/// across exposures instead of testing all 60 headings on the compositor's main thread.
const MONOCULAR_HEADINGS_PER_SCAN: u32 = 2;
const MONOCULAR_CONFIRM_FRAMES: u32 = 12;
/// Exposures after a fix during which the last place is still tried as a start.
const NEAR_LAST_FRAMES: u32 = 60;

#[derive(Debug, Clone, Copy)]
struct Sighting {
    view: usize,
    /// Identity of the actual source blob within this view/exposure, retained
    /// even when another controller's observations are masked before refitting.
    spot: usize,
    led: usize,
    at: [f64; 2],
}

#[derive(Debug, Clone)]
struct Solution {
    position: V3,
    heading: f64,
    tilt: [f64; 2],
    sightings: Vec<Sighting>,
    rms: f64,
}

#[derive(Debug, Clone, Copy)]
struct MonocularTrial {
    position: V3,
    heading: f64,
    view: usize,
    exposure: u32,
}

impl Solution {
    fn is_good(&self) -> bool {
        self.sightings.len() >= MIN_SIGHTINGS && self.rms < MAX_RMS
    }

    /// High-observability stereo support, using the existing large-heading
    /// support count and cold-acquisition unique-LED count. Only the paired
    /// tracker may use this branch: it also corroborates independent exposures.
    fn strong_stereo(&self) -> bool {
        self.rms < MAX_RMS
            && self.sightings.len() >= JUMP_SIGHTINGS
            && self
                .sightings
                .iter()
                .map(|s| (s.view, s.spot))
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                == self.sightings.len()
            && [0, 1].iter().all(|view| {
                self.sightings.iter().filter(|s| s.view == *view).count() >= JUMP_SIGHTINGS / 2
            })
            && self
                .sightings
                .iter()
                .map(|s| s.led)
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                >= SCAN_SIGHTINGS
    }
}

/// One exposure's spots: the bottom pair's two pictures (views 0 and 1) with the points they
/// agree on, and any other camera's picture after them.
struct Seen<'a> {
    cameras: Vec<Camera>,
    spots: Vec<&'a [Spot]>,
    spot_ids: Vec<Vec<usize>>,
    points: Vec<V3>,
}

impl<'a> Seen<'a> {
    /// `bottom`: the bottom pair's pictures are the raw fisheyes' (camera mode 0x10), not the
    /// rectified pair's: their spots are put where the rectified pair would see them for pairing
    /// (the same rows), and fitted in the fisheyes' own pictures.
    fn new(
        pair: &StereoPair,
        left: &'a [Spot],
        right: &'a [Spot],
        others: &[(Camera, &'a [Spot])],
        bottom: Option<&[Camera; 2]>,
    ) -> Seen<'a> {
        let rectified = |view: usize, spots: &[Spot]| -> Vec<Spot> {
            let Some(bottom) = bottom else {
                return spots.to_vec();
            };
            let (camera, cx) = (&bottom[view], [pair.cx_left, pair.cx_right][view]);
            spots
                .iter()
                .filter_map(|s| {
                    let own = camera.ray(f64::from(s.x), f64::from(s.y));
                    let m = &camera.rotation;
                    let d: V3 = std::array::from_fn(|j| (0..3).map(|k| m[k][j] * own[k]).sum());
                    // Beyond 75° off the pair's forward a row means little.
                    (d[2] > 0.26).then(|| Spot {
                        x: (cx + pair.focal * d[0] / d[2]) as f32,
                        y: (pair.cy + pair.focal * d[1] / d[2]) as f32,
                        area: s.area,
                    })
                })
                .collect()
        };
        let (left_rows, right_rows) = (rectified(0, left), rectified(1, right));
        let mut points = Vec::new();
        'pairs: for l in left_rows.iter().filter(|s| PAIR_AREA.contains(&s.area)) {
            for r in right_rows.iter().filter(|s| PAIR_AREA.contains(&s.area)) {
                let apart = f64::from(l.x - r.x) - (pair.cx_left - pair.cx_right);
                let ratio = l.area as f32 / r.area as f32;
                if (l.y - r.y).abs() < PAIR_ROWS
                    && PAIR_DISPARITY.contains(&apart)
                    && (0.33..3.0).contains(&ratio)
                {
                    points.push(pair.triangulate(
                        f64::from(l.x),
                        f64::from(r.x),
                        f64::from(l.y + r.y) * 0.5,
                    ));
                    if points.len() == MAX_POINTS {
                        break 'pairs;
                    }
                }
            }
        }
        let mut cameras = bottom.copied().unwrap_or_else(|| pair.cameras()).to_vec();
        let mut spots = vec![left, right];
        for (camera, seen) in others {
            cameras.push(*camera);
            spots.push(seen);
        }
        Seen {
            cameras,
            spot_ids: spots.iter().map(|view| (0..view.len()).collect()).collect(),
            spots,
            points,
        }
    }
}

/// The LEDs turned into the camera's frame: places (from the IMU) and facings.
struct Shape {
    places: [V3; LED_COUNT],
    facings: [V3; LED_COUNT],
}

impl Shape {
    fn new(leds: &[Led; LED_COUNT], rotation: &M3) -> Shape {
        Shape {
            places: std::array::from_fn(|i| apply(rotation, leds[i].position)),
            facings: std::array::from_fn(|i| apply(rotation, leds[i].normal)),
        }
    }

    /// Whether LED `i` faces a camera sitting at `camera`, with the controller at `p`.
    fn faces(&self, i: usize, p: V3, camera: V3) -> bool {
        let to = sub(camera, add(self.places[i], p));
        dot(self.facings[i], to) / dot(to, to).sqrt() > FACING
    }
}

fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn dot(a: V3, b: V3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// The controller's place from one camera's picture alone, for where the pair has nothing to
/// vote on (a controller only a top camera sees, or only one of the bottom two). With the
/// orientation known, two spots taken for two LEDs settle a place: the one nearest to both
/// spots' lines of sight. Every such couple is tried (spots of an LED's size, LEDs that face
/// the camera along that line), and the place that puts the most other LEDs on spots wins, when
/// at least four are.
fn vote_alone(camera: &Camera, spots: &[Spot], shape: &Shape) -> Option<V3> {
    const MAX_SPOTS: usize = 12;
    const NEAR: f64 = 6.0;
    // Each spot's line of sight, in the pair's frame.
    let sights: Vec<([f64; 2], V3)> = spots
        .iter()
        .filter(|s| PAIR_AREA.contains(&s.area))
        .take(MAX_SPOTS)
        .map(|s| {
            let (x, y) = (f64::from(s.x), f64::from(s.y));
            let own = camera.ray(x, y);
            // The rotation's rows are the camera's axes: its transpose takes a line out.
            let m = &camera.rotation;
            let line: V3 = std::array::from_fn(|j| (0..3).map(|k| m[k][j] * own[k]).sum());
            ([x, y], line)
        })
        .collect();
    if sights.len() < 4 {
        return None;
    }
    // (spot, LED) couples worth trying: the LED turned towards the camera along that line.
    let couples: Vec<(usize, usize)> = (0..sights.len())
        .flat_map(|a| (0..LED_COUNT).map(move |i| (a, i)))
        .filter(|&(a, i)| dot(shape.facings[i], sights[a].1) < -0.15)
        .collect();
    let mut best: (usize, Option<V3>) = (3, None);
    for (n, &(a, i)) in couples.iter().enumerate() {
        for &(b, j) in &couples[n + 1..] {
            if a == b || i == j {
                continue;
            }
            // The point nearest to both lines: each line asks that (place + LED − camera) have
            // nothing across it.
            let mut ata = [[0.0; 3]; 3];
            let mut atb = [0.0; 3];
            for (line, led) in [(sights[a].1, i), (sights[b].1, j)] {
                let from = sub(camera.place, shape.places[led]);
                for r in 0..3 {
                    for c in 0..3 {
                        let across = if r == c { 1.0 } else { 0.0 } - line[r] * line[c];
                        ata[r][c] += across;
                        atb[r] += across * from[c];
                    }
                }
            }
            let Some(x) = solve_linear(ata.iter().map(|r| r.to_vec()).collect(), atb.to_vec())
            else {
                continue;
            };
            let place = [x[0], x[1], x[2]];
            // In front of this camera, within an arm's reach, the two LEDs where their spots are.
            let seen_i = camera.see(add(shape.places[i], place));
            if !(0.12..MAX_REACH).contains(&seen_i[2]) {
                continue;
            }
            let on = |led: usize, at: [f64; 2]| {
                camera
                    .project(add(shape.places[led], place))
                    .is_some_and(|p| (p[0] - at[0]).hypot(p[1] - at[1]) < NEAR)
            };
            if !on(i, sights[a].0) || !on(j, sights[b].0) {
                continue;
            }
            let count = (0..LED_COUNT)
                .filter(|&led| shape.faces(led, place, camera.place))
                .filter(|&led| sights.iter().any(|(at, _)| on(led, *at)))
                .count();
            if count > best.0 {
                best = (count, Some(place));
            }
        }
    }
    best.1
}

/// The controller's place most (point, LED) couples agree on, when at least three do.
fn vote(points: &[V3], shape: &Shape) -> Option<V3> {
    let proposals: Vec<V3> = points
        .iter()
        .flat_map(|x| shape.places.iter().map(move |m| sub(*x, *m)))
        .collect();
    let near = |a: V3, b: V3| {
        let d = sub(a, b);
        dot(d, d) < VOTE_REACH * VOTE_REACH
    };
    let (mut best, mut count) = (0, 0);
    for (i, a) in proposals.iter().enumerate() {
        let n = proposals.iter().filter(|b| near(*a, **b)).count();
        if n > count {
            (best, count) = (i, n);
        }
    }
    if count < 3 {
        return None;
    }
    let mut sum = [0.0; 3];
    for b in proposals.iter().filter(|b| near(proposals[best], **b)) {
        sum = add(sum, *b);
    }
    Some(sum.map(|v| v / count as f64))
}

/// Each LED facing a camera takes the spot nearest to where it should appear in that camera's
/// picture, when that spot is within `radius` and has no nearer LED.
fn assign(seen: &Seen, shape: &Shape, p: V3, radius: f64) -> Vec<Sighting> {
    let mut out = Vec::new();
    for (view, (camera, spots)) in seen.cameras.iter().zip(&seen.spots).enumerate() {
        if spots.is_empty() {
            continue;
        }
        let expected: Vec<(usize, [f64; 2])> = (0..LED_COUNT)
            .filter(|&i| shape.faces(i, p, camera.place))
            .filter_map(|i| Some((i, camera.project(add(shape.places[i], p))?)))
            .filter(|(_, at)| {
                (-radius..camera.size[0] + radius).contains(&at[0])
                    && (-radius..camera.size[1] + radius).contains(&at[1])
            })
            .collect();
        let apart = |at: [f64; 2], s: &Spot| {
            let (dx, dy) = (at[0] - f64::from(s.x), at[1] - f64::from(s.y));
            dx * dx + dy * dy
        };
        for (led, at) in &expected {
            let Some((j, d)) = spots
                .iter()
                .enumerate()
                .map(|(j, s)| (j, apart(*at, s)))
                .min_by(|a, b| a.1.total_cmp(&b.1))
            else {
                break;
            };
            let nearer = expected
                .iter()
                .any(|(other, o)| other != led && apart(*o, &spots[j]) < d);
            if d < radius * radius && !nearer {
                out.push(Sighting {
                    view,
                    spot: seen.spot_ids[view][j],
                    led: *led,
                    at: [f64::from(spots[j].x), f64::from(spots[j].y)],
                });
            }
        }
    }
    out
}

/// The place that best puts the sighted LEDs on their spots (Gauss-Newton on three numbers),
/// and what is left over, x then y for each sighting, in pixels. `cameras` are the pictures'
/// cameras, by view.
fn solve_position(
    cameras: &[Camera],
    shape: &Shape,
    sightings: &[Sighting],
    mut p: V3,
    iterations: usize,
) -> (V3, Vec<f64>) {
    let mut left_over = vec![0.0; sightings.len() * 2];
    for round in 0..=iterations {
        let mut jtj = vec![vec![0.0; 3]; 3];
        let mut jtr = vec![0.0; 3];
        for (n, s) in sightings.iter().enumerate() {
            let camera = &cameras[s.view];
            let c = camera.see(add(shape.places[s.led], p));
            // (A step that takes an LED behind its camera is held at the camera's face.)
            let (f, x, y, z) = (camera.focal, c[0], c[1], c[2].max(0.02));
            let (r, own) = if camera.fisheye.is_some() {
                // A fisheye: the lens's own projection, and its slope taken numerically.
                let at = |c: V3| camera.project_ray(c).unwrap_or([camera.cx, camera.cy]);
                let here = at(c);
                let h = 1e-6 * dot(c, c).sqrt().max(1e-3);
                let moved: [[f64; 2]; 3] = std::array::from_fn(|k| {
                    let mut d = c;
                    d[k] += h;
                    at(d)
                });
                (
                    [here[0] - s.at[0], here[1] - s.at[1]],
                    [
                        std::array::from_fn(|k| (moved[k][0] - here[0]) / h),
                        std::array::from_fn(|k| (moved[k][1] - here[1]) / h),
                    ],
                )
            } else {
                (
                    [
                        camera.cx + f * x / z - s.at[0],
                        camera.cy + f * y / z - s.at[1],
                    ],
                    // How the spot moves with the point in the camera's own frame.
                    [[f / z, 0.0, -f * x / z / z], [0.0, f / z, -f * y / z / z]],
                )
            };
            left_over[n * 2] = r[0];
            left_over[n * 2 + 1] = r[1];
            // Then with the place.
            let m = &camera.rotation;
            let rows: [[f64; 3]; 2] = std::array::from_fn(|a| {
                std::array::from_fn(|j| (0..3).map(|k| own[a][k] * m[k][j]).sum())
            });
            for (row, r) in rows.iter().zip(r) {
                for i in 0..3 {
                    jtr[i] += row[i] * r;
                    for j in 0..3 {
                        jtj[i][j] += row[i] * row[j];
                    }
                }
            }
        }
        if round == iterations {
            break;
        }
        for (i, row) in jtj.iter_mut().enumerate() {
            row[i] += 1e-9;
        }
        let Some(step) = solve_linear(jtj, jtr) else {
            break;
        };
        p = sub(p, [step[0], step[1], step[2]]);
    }
    (p, left_over)
}

fn rms(left_over: &[f64]) -> f64 {
    (left_over.iter().map(|r| r * r).sum::<f64>() / (left_over.len() / 2).max(1) as f64).sqrt()
}

/// Solves `a · x = b` (Gaussian elimination with pivoting); `None` when `a` is singular.
fn solve_linear(mut a: Vec<Vec<f64>>, mut b: Vec<f64>) -> Option<Vec<f64>> {
    let n = b.len();
    for col in 0..n {
        let pivot = (col..n).max_by(|&i, &j| a[i][col].abs().total_cmp(&a[j][col].abs()))?;
        if a[pivot][col].abs() < 1e-300 {
            return None;
        }
        a.swap(col, pivot);
        b.swap(col, pivot);
        for row in col + 1..n {
            let k = a[row][col] / a[col][col];
            if k != 0.0 {
                let (above, below) = a.split_at_mut(row);
                for (x, pivot) in below[0][col..].iter_mut().zip(&above[col][col..]) {
                    *x -= k * pivot;
                }
                b[row] -= k * b[col];
            }
        }
    }
    let mut x = vec![0.0; n];
    for row in (0..n).rev() {
        let rest: f64 = (row + 1..n).map(|j| a[row][j] * x[j]).sum();
        x[row] = (b[row] - rest) / a[row][row];
    }
    Some(x)
}

/// How one fit goes about it: from a known place or from the vote, how near a spot must be at
/// each pass, and how strongly the lean is held to the one in use.
struct Search<'a> {
    start: Option<V3>,
    radii: &'a [f64],
    hold: f64,
}

/// Follows one controller from exposure to exposure.
#[derive(Debug, Clone)]
pub struct HandTracker {
    hand: Hand,
    leds: [Led; LED_COUNT],
    heading: f64,
    /// The lean in use: turns about the tracking space's x and z, radians.
    tilt: [f64; 2],
    /// Whether the lean is looked for (the cameras' fit leaves it to the cameras' own tilt).
    leans: bool,
    last: Option<V3>,
    /// How far the controller moved per exposure between its last two fixes, in the camera's
    /// frame: a hand in motion is looked for where it was going, not where it was.
    step: V3,
    /// Exposures since the last fix.
    lost: u32,
    /// The bottom cameras as fisheyes (camera mode 0x10's raw pictures), or `None`: the
    /// rectified pair of modes 1 and 3.
    bottom: Option<[Camera; 2]>,
    /// This headset's measured right-camera alignment, in that raw camera's local axes.
    /// The generic camera model remains the default; this is not a controller pose offset.
    bottom_alignment: V3,
    /// Whether the heading has ever been settled by a fix with enough LEDs. Until then a fix
    /// on few LEDs is not taken: with the heading unknown, five sightings fitted a controller
    /// 36° off its real heading.
    settled: bool,
    /// Enables the expanded stereo gate only for the paired temporal owner.
    paired_confirmation: bool,
    /// Per-exposure paired identity support; legacy callers keep MIN_SIGHTINGS.
    required_sightings: usize,
    /// A cold monocular hypothesis must fit a later exposure before it establishes yaw.
    monocular_trial: Option<MonocularTrial>,
}

impl HandTracker {
    pub fn new(hand: Hand) -> HandTracker {
        HandTracker {
            hand,
            leds: sense_leds(hand),
            heading: 0.0,
            tilt: [0.0; 2],
            leans: true,
            last: None,
            step: [0.0; 3],
            lost: SCAN_AFTER,
            bottom: None,
            bottom_alignment: [0.0; 3],
            settled: false,
            paired_confirmation: false,
            required_sightings: MIN_SIGHTINGS,
            monocular_trial: None,
        }
    }

    /// The bottom pair's spots are from the raw fisheyes (camera mode 0x10, about 170° across
    /// together) instead of the rectified pair (modes 1 and 3, 82°): `PSVR2_BOTTOM_FISHEYE`.
    pub fn set_bottom_fisheyes(&mut self, on: bool) {
        self.bottom = on.then(|| self.aligned_bottom_cameras());
    }

    fn aligned_bottom_cameras(&self) -> [Camera; 2] {
        let mut cameras = super::stereo::PSVR2_BOTTOM_FISHEYE;
        cameras[1].rotation = mul(
            &from_rotation_vector(self.bottom_alignment),
            &cameras[1].rotation,
        );
        cameras
    }

    /// Applies a measured, per-headset relative alignment to the raw bottom pair.
    /// `rotation` is a rotation vector in radians, in the right raw camera's axes
    /// (x right, y down, z forward). The same cameras are used for stereo seeding
    /// and final raw-pixel reprojection; adjusting only the seed gate cannot fix
    /// inconsistent camera geometry. Zero selects the unchanged generic model.
    ///
    /// Rejects nonfinite values or corrections beyond five degrees without
    /// changing the tracker. A changed calibration retires old pose hypotheses.
    pub fn set_bottom_fisheye_alignment(&mut self, rotation: V3) -> bool {
        if !rotation.iter().all(|v| v.is_finite())
            || dot(rotation, rotation) > 5f64.to_radians().powi(2)
        {
            return false;
        }
        if self.bottom_alignment == rotation {
            return true;
        }
        let raw = self.bottom.is_some();
        let paired = self.paired_confirmation;
        *self = Self::new(self.hand);
        self.paired_confirmation = paired;
        self.bottom_alignment = rotation;
        self.set_bottom_fisheyes(raw);
        true
    }

    pub fn hand(&self) -> Hand {
        self.hand
    }

    /// The correction to the IMU's heading in use, radians.
    pub fn heading(&self) -> f32 {
        self.heading as f32
    }

    /// Starts from a known heading correction (a fix found earlier).
    pub fn set_heading(&mut self, heading: f32) {
        self.heading = f64::from(heading);
    }

    /// One exposure. `camera_from_world` is the tracking space seen from the camera's frame at
    /// that moment ([`StereoPair::camera_from_world`]), `orientation` the controller's own
    /// (its IMU's frame in the tracking space, heading as its gyro has it), `left` and `right`
    /// the two pictures' spots, brightest first.
    pub fn update(
        &mut self,
        pair: &StereoPair,
        camera_from_world: &M3,
        orientation: Quat,
        left: &[Spot],
        right: &[Spot],
    ) -> Option<Fix> {
        self.update_with(pair, &[], camera_from_world, orientation, left, right)
    }

    /// [`HandTracker::update`] with other cameras' pictures of the same exposure besides the
    /// bottom pair's (the top cameras, [`super::stereo::PSVR2_TOP`]): a controller found by
    /// the pair is followed into their sight and out of the pair's, and one that is lost can be
    /// found again by any one camera alone.
    pub fn update_with(
        &mut self,
        pair: &StereoPair,
        others: &[(Camera, &[Spot])],
        camera_from_world: &M3,
        orientation: Quat,
        left: &[Spot],
        right: &[Spot],
    ) -> Option<Fix> {
        let seen = Seen::new(pair, left, right, others, self.bottom.as_ref());
        self.locate(&seen, camera_from_world, &from_quat(orientation))
            .map(|s| Fix {
                position: s.position.map(|v| v as f32),
                heading: s.heading as f32,
                tilt: s.tilt.map(|v| v as f32),
                sightings: s.sightings.len() as u32,
                rms: s.rms as f32,
            })
    }

    fn locate(&mut self, seen: &Seen, camera_from_world: &M3, imu: &M3) -> Option<Solution> {
        let mut found = None;
        if let Some(last) = self.last
            && self.lost <= FOLLOW_FRAMES
        {
            found = self.fit(
                seen,
                camera_from_world,
                imu,
                self.heading,
                Search {
                    start: Some(add(last, self.step.map(|v| v * f64::from(self.lost + 1)))),
                    radii: &RADII_FOLLOW,
                    hold: TILT_HOLD,
                },
            );
        }
        if !found.as_ref().is_some_and(|s| self.usable(s)) {
            found = self.fit(
                seen,
                camera_from_world,
                imu,
                self.heading,
                Search {
                    start: None,
                    radii: &RADII_SEARCH,
                    hold: TILT_HOLD,
                },
            );
        }
        // Out of the pair's sight there is nothing to vote on: for a second after a fix, the
        // controller is also looked for around where it was last, in whatever camera sees it.
        if !found.as_ref().is_some_and(|s| self.usable(s))
            && self.lost > FOLLOW_FRAMES
            && self.lost <= NEAR_LAST_FRAMES
            && let Some(last) = self.last
        {
            found = self.fit(
                seen,
                camera_from_world,
                imu,
                self.heading,
                Search {
                    start: Some(last),
                    radii: &RADII_SEARCH,
                    hold: TILT_HOLD,
                },
            );
        }
        // And by each camera alone, with the heading as it was last known.
        if !found.as_ref().is_some_and(|s| self.usable(s)) && self.lost % ALONE_EVERY == 0 {
            let rotation = mul(
                &mul(
                    &mul(
                        camera_from_world,
                        &from_rotation_vector([self.tilt[0], 0.0, self.tilt[1]]),
                    ),
                    &turn_y(self.heading),
                ),
                imu,
            );
            let shape = Shape::new(&self.leds, &rotation);
            for (camera, spots) in seen.cameras.iter().zip(&seen.spots) {
                let Some(start) = vote_alone(camera, spots, &shape) else {
                    continue;
                };
                let tried = self.fit(
                    seen,
                    camera_from_world,
                    imu,
                    self.heading,
                    Search {
                        start: Some(start),
                        radii: &RADII_FOLLOW,
                        hold: TILT_HOLD,
                    },
                );
                // One picture can't tell far from near as two can: more LEDs are asked for, and a
                // closer fit.
                if tried
                    .as_ref()
                    .is_some_and(|s| s.sightings.len() >= ALONE_SIGHTINGS && s.rms < SCAN_RMS)
                {
                    found = tried;
                    break;
                }
            }
        }
        if !found.as_ref().is_some_and(|s| self.usable(s))
            && self.lost >= SCAN_AFTER
            && (self.lost - SCAN_AFTER) % SCAN_EVERY == 0
            && (seen.points.len() >= 5
                || self.paired_confirmation && self.last.is_some() && self.lost <= NEAR_LAST_FRAMES)
        {
            let steps = if self.settled && self.lost < RESCAN_AFTER {
                -SCAN_NEAR_STEPS..=SCAN_NEAR_STEPS
            } else {
                0..=59
            };
            found = steps
                .filter_map(|step| {
                    let heading = self.heading + f64::from(step) * 6f64.to_radians();
                    let voted = self.fit(
                        seen,
                        camera_from_world,
                        imu,
                        heading,
                        Search {
                            start: None,
                            radii: &RADII_SEARCH,
                            hold: 0.0,
                        },
                    );
                    let prior = if self.paired_confirmation && self.lost <= NEAR_LAST_FRAMES {
                        self.last
                            .and_then(|last| {
                                self.fit(
                                    seen,
                                    camera_from_world,
                                    imu,
                                    heading,
                                    Search {
                                        start: Some(last),
                                        radii: &RADII_SEARCH,
                                        hold: 0.0,
                                    },
                                )
                            })
                            .filter(Solution::strong_stereo)
                    } else {
                        None
                    };
                    [voted, prior]
                        .into_iter()
                        .flatten()
                        .filter(|s| self.scan_usable(s))
                        .max_by(|a, b| {
                            (a.sightings.len(), -a.rms)
                                .partial_cmp(&(b.sightings.len(), -b.rms))
                                .unwrap_or(std::cmp::Ordering::Equal)
                        })
                })
                .filter(|s| self.scan_usable(s))
                .max_by(|a, b| {
                    (a.sightings.len(), -a.rms)
                        .partial_cmp(&(b.sightings.len(), -b.rms))
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
        }
        // Stereo cannot propose a place when only one camera sees a newly woken controller.
        // Its initial yaw is arbitrary: retrying only yaw zero can never acquire it. Keep
        // the IMU's tilt/roll, scan a bounded number of yaws, and require eight unique LEDs
        // in one picture, the normal scan's tight RMS, and a confirming later exposure.
        if (!self.settled || self.paired_confirmation && self.lost >= SCAN_AFTER)
            && !found.as_ref().is_some_and(|s| self.usable(s))
        {
            if let Some(trial) = self.monocular_trial
                && self.lost > trial.exposure
                && self.lost - trial.exposure <= MONOCULAR_CONFIRM_FRAMES
            {
                let confirmed = self.fit(
                    seen,
                    camera_from_world,
                    imu,
                    trial.heading,
                    Search {
                        start: Some(trial.position),
                        radii: &RADII_FOLLOW,
                        hold: TILT_HOLD,
                    },
                );
                if confirmed.as_ref().is_some_and(|s| {
                    let shift = sub(s.position, trial.position);
                    let turn = (s.heading - trial.heading + std::f64::consts::PI)
                        .rem_euclid(std::f64::consts::TAU)
                        - std::f64::consts::PI;
                    s.sightings.iter().filter(|v| v.view == trial.view).count() >= SCAN_SIGHTINGS
                        && s.rms < SCAN_RMS
                        && dot(shift, shift) < 0.08 * 0.08
                        && turn.abs() < 15f64.to_radians()
                        && self.usable(s)
                }) {
                    found = confirmed;
                }
            }
            if !found.as_ref().is_some_and(|s| self.usable(s))
                && self.lost >= SCAN_AFTER
                && (self.lost - SCAN_AFTER) % SCAN_EVERY == 0
            {
                let step = (self.lost - SCAN_AFTER) / SCAN_EVERY * MONOCULAR_HEADINGS_PER_SCAN;
                let mut best: Option<(usize, usize, Solution)> = None;
                let mut strong_best: Option<Solution> = None;
                for offset in 0..MONOCULAR_HEADINGS_PER_SCAN {
                    let heading = f64::from((step + offset) % 60) * 6f64.to_radians();
                    let rotation = mul(
                        &mul(
                            &mul(
                                camera_from_world,
                                &from_rotation_vector([self.tilt[0], 0.0, self.tilt[1]]),
                            ),
                            &turn_y(heading),
                        ),
                        imu,
                    );
                    let shape = Shape::new(&self.leds, &rotation);
                    for (view, (camera, spots)) in seen.cameras.iter().zip(&seen.spots).enumerate()
                    {
                        if spots.iter().filter(|s| PAIR_AREA.contains(&s.area)).count()
                            < SCAN_SIGHTINGS
                        {
                            continue;
                        }
                        let Some(start) = vote_alone(camera, spots, &shape) else {
                            continue;
                        };
                        let Some(tried) = self.fit(
                            seen,
                            camera_from_world,
                            imu,
                            heading,
                            Search {
                                start: Some(start),
                                radii: &RADII_SEARCH,
                                hold: TILT_HOLD,
                            },
                        ) else {
                            continue;
                        };
                        let count = tried.sightings.iter().filter(|v| v.view == view).count();
                        if self.paired_confirmation && tried.strong_stereo() && self.usable(&tried)
                        {
                            // A single-camera seed is only a proposal. Both raw
                            // cameras validate it, and the paired owner requires
                            // an independent exposure before publishing this pose.
                            if strong_best.as_ref().is_none_or(|old| {
                                (tried.sightings.len(), -tried.rms)
                                    > (old.sightings.len(), -old.rms)
                            }) {
                                strong_best = Some(tried);
                            }
                            continue;
                        }
                        if count < SCAN_SIGHTINGS || tried.rms >= SCAN_RMS || !self.usable(&tried) {
                            continue;
                        }
                        if best
                            .as_ref()
                            .is_none_or(|(_, n, b)| (count, -tried.rms) > (*n, -b.rms))
                        {
                            best = Some((view, count, tried));
                        }
                    }
                }
                if let Some(strong) = strong_best {
                    found = Some(strong);
                }
                if let Some((view, _, tried)) = best {
                    self.monocular_trial = Some(MonocularTrial {
                        position: tried.position,
                        heading: tried.heading,
                        view,
                        exposure: self.lost,
                    });
                }
            }
        }
        // Nothing a hand holds is farther from the cameras than an arm is long: what is found
        // beyond is a reflection or a lamp (both trackers once locked onto the same thing 1.1 m
        // away, and the user saw a hand jump away).
        match found.filter(|s| self.usable(s)) {
            Some(mut s) => {
                self.settled = true;
                self.monocular_trial = None;
                // Keep the heading within a turn.
                s.heading = (s.heading + std::f64::consts::PI).rem_euclid(std::f64::consts::TAU)
                    - std::f64::consts::PI;
                self.heading = s.heading;
                self.tilt = s.tilt;
                self.step = match self.last {
                    Some(last) if self.lost <= FOLLOW_FRAMES => {
                        sub(s.position, last).map(|v| v / f64::from(self.lost + 1))
                    }
                    _ => [0.0; 3],
                };
                self.last = Some(s.position);
                self.lost = 0;
                Some(s)
            }
            None => {
                self.lost = self.lost.saturating_add(1);
                None
            }
        }
    }

    /// Use the same acceptance gate during search and at publication. A weak cold-start fit
    /// must not suppress yaw acquisition only to be rejected at the end of every exposure.
    fn usable(&self, s: &Solution) -> bool {
        let jump = (s.heading - self.heading + std::f64::consts::PI)
            .rem_euclid(std::f64::consts::TAU)
            - std::f64::consts::PI;
        s.is_good()
            && s.sightings.len() >= self.required_sightings
            && dot(s.position, s.position).sqrt() < MAX_REACH
            && (self.settled || s.sightings.len() >= SCAN_SIGHTINGS)
            && !(self.settled
                && jump.abs() > HEADING_JUMP
                && !(s.sightings.len() >= JUMP_SIGHTINGS && s.rms < SCAN_RMS
                    || self.paired_confirmation && s.strong_stereo()))
    }

    fn scan_usable(&self, s: &Solution) -> bool {
        s.sightings.len() >= SCAN_SIGHTINGS && s.rms < SCAN_RMS
            || self.paired_confirmation && s.strong_stereo()
    }

    /// The place, heading and lean that fit the spots, starting from `start` or, without one, from
    /// the vote. `None` when too little matches to go on.
    fn fit(
        &self,
        seen: &Seen,
        camera_from_world: &M3,
        imu: &M3,
        heading: f64,
        how: Search,
    ) -> Option<Solution> {
        let Search { start, radii, hold } = how;
        // The unknowns of the orientation: the heading, then the lean about the tracking
        // space's x and z.
        let mut turn = [heading, self.tilt[0], self.tilt[1]];
        let shape = |turn: [f64; 3]| {
            let lean = from_rotation_vector([turn[1], 0.0, turn[2]]);
            Shape::new(
                &self.leds,
                &mul(&mul(&mul(camera_from_world, &lean), &turn_y(turn[0])), imu),
            )
        };
        let mut p = match start {
            Some(p) => p,
            None => vote(&seen.points, &shape(turn))?,
        };
        let mut sightings = Vec::new();
        let mut left_over = Vec::new();
        for radius in radii {
            sightings = assign(seen, &shape(turn), p, *radius);
            if sightings.len() < 4 {
                return None;
            }
            // Each only with enough to hold it: the heading with three LEDs in both pictures,
            // the lean with four.
            let unknowns = match sightings.len() {
                n if n >= TILT_SIGHTINGS && self.leans => 3,
                n if n >= 6 => 1,
                _ => 0,
            };
            for _ in 0..if unknowns > 0 { 3 } else { 0 } {
                let (at, r) = solve_position(&seen.cameras, &shape(turn), &sightings, p, 3);
                const STEP: f64 = 1e-3;
                let slopes: Vec<Vec<f64>> = (0..unknowns)
                    .map(|k| {
                        let mut moved = turn;
                        moved[k] += STEP;
                        let (_, turned) =
                            solve_position(&seen.cameras, &shape(moved), &sightings, at, 3);
                        turned.iter().zip(&r).map(|(t, r)| (t - r) / STEP).collect()
                    })
                    .collect();
                let dot = |a: &[f64], b: &[f64]| a.iter().zip(b).map(|(a, b)| a * b).sum::<f64>();
                let jtj: Vec<Vec<f64>> = (0..unknowns)
                    .map(|i| {
                        (0..unknowns)
                            .map(|j| {
                                // The lean is held near the one in use: one exposure with four
                                // LEDs can't tell a lean from a step aside.
                                let held = if i == j && i > 0 { hold } else { 0.0 };
                                dot(&slopes[i], &slopes[j]) + if i == j { 1e-6 } else { 0.0 } + held
                            })
                            .collect()
                    })
                    .collect();
                let jtr: Vec<f64> = slopes
                    .iter()
                    .enumerate()
                    .map(|(k, g)| {
                        let pull = if k > 0 {
                            hold * (turn[k] - self.tilt[k - 1])
                        } else {
                            0.0
                        };
                        dot(g, &r) + pull
                    })
                    .collect();
                if let Some(step) = solve_linear(jtj, jtr) {
                    for (k, step) in step.iter().enumerate() {
                        turn[k] -= step.clamp(-0.05, 0.05);
                    }
                    turn[1] = turn[1].clamp(-MAX_TILT, MAX_TILT);
                    turn[2] = turn[2].clamp(-MAX_TILT, MAX_TILT);
                }
                p = at;
            }
            (p, left_over) = solve_position(&seen.cameras, &shape(turn), &sightings, p, 6);
        }
        Some(Solution {
            position: p,
            heading: turn[0],
            tilt: [turn[1], turn[2]],
            rms: rms(&left_over),
            sightings,
        })
    }
}

/// One exposure of a `--camera-dump` file: both bottom pictures' spots, and what Halliday knew
/// of the controllers and the head when it wrote them.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    /// The cameras' frame counter.
    pub counter: u64,
    /// The exposure's time on the host's clock, ns.
    pub t_ns: u64,
    pub left: Vec<Spot>,
    pub right: Vec<Spot>,
    /// The top cameras' spots, left then right (views 2 and 3 of camera mode 3); empty when
    /// the capture has none, or when that exposure's top picture was missed.
    pub top: [Vec<Spot>; 2],
    /// Each controller's orientation, left then right: as written, its newest report's.
    pub hands: [Option<Quat>; 2],
    /// When that report arrived, on the host's clock, ns (in captures that carry it).
    pub hands_at: [Option<u64>; 2],
    /// The head's orientation and place in the tracking space.
    pub head: Option<Quat>,
    pub head_position: Option<[f32; 3]>,
}

/// Puts each controller's orientation at its exposure's time. A dump holds the newest report's
/// orientation, which is some 20 ms newer than the exposure it is written with; this looks up,
/// among all the reports of the capture, the orientation that arrived `lag_ns` after each
/// exposure (a report arrives a little after the motion it tells of), between the two nearest.
/// Exposures with no report within 50 ms on both sides keep what they had.
pub fn at_exposure(frames: &mut [Frame], lag_ns: i64) {
    for hand in 0..2 {
        let mut reports: Vec<(u64, Quat)> = frames
            .iter()
            .filter_map(|f| Some((f.hands_at[hand]?, f.hands[hand]?)))
            .collect();
        reports.dedup_by_key(|r| r.0);
        for frame in frames.iter_mut() {
            let wanted = frame.t_ns.saturating_add_signed(lag_ns);
            let after = reports.partition_point(|r| r.0 < wanted);
            if after == 0 || after == reports.len() {
                continue;
            }
            let ((t0, q0), (t1, q1)) = (reports[after - 1], reports[after]);
            let (Ok(t0), Ok(t1), Ok(wanted_time)) =
                (i64::try_from(t0), i64::try_from(t1), i64::try_from(wanted))
            else {
                continue;
            };
            let Some(q) =
                crate::sense_orientation_history::between((t0, q0), (t1, q1), wanted_time)
            else {
                continue;
            };
            frame.hands[hand] = Some(q);
            frame.hands_at[hand] = Some(wanted);
        }
    }
}

/// Reads the text Halliday writes with `--camera-dump FILE`: a line per picture,
/// `frame N view V t NS size W H spots x,y,area,peak … left x,y,z,w left-at NS right x,y,z,w
/// right-at NS head px,py,pz,x,y,z,w` (other fields are passed over). Exposures missing one of the two bottom pictures (views 0 and 1)
/// are left out.
pub fn parse_dump(text: &str) -> Vec<Frame> {
    fn quat(v: &[f32]) -> Option<Quat> {
        let [x, y, z, w] = *v else { return None };
        Some(Quat { w, x, y, z }.normalized())
    }
    let mut frames: Vec<(Frame, [bool; 2])> = Vec::new();
    for line in text.lines() {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        let field = |name: &str| {
            let i = tokens.iter().position(|t| *t == name)?;
            tokens.get(i + 1).copied()
        };
        let numbers =
            |s: &str| -> Vec<f32> { s.split(',').filter_map(|v| v.parse().ok()).collect() };
        let (Some(counter), Some(view), Some(t_ns), Some(first)) = (
            field("frame").and_then(|v| v.parse::<u64>().ok()),
            field("view").and_then(|v| v.parse::<usize>().ok()),
            field("t").and_then(|v| v.parse::<u64>().ok()),
            tokens.iter().position(|t| *t == "spots"),
        ) else {
            continue;
        };
        if view > 3 {
            continue;
        }
        let spots: Vec<Spot> = tokens[first + 1..]
            .iter()
            .take_while(|t| t.contains(','))
            .filter_map(|t| match numbers(t)[..] {
                [x, y, area, _peak] => Some(Spot {
                    x,
                    y,
                    area: area as u32,
                }),
                _ => None,
            })
            .collect();
        // An exposure's pictures may be written a few lines apart (the top cameras' after the
        // next exposure's bottom ones): look for it among the last few.
        let known = frames
            .iter()
            .rev()
            .take(4)
            .position(|(f, _)| f.counter == counter)
            .map(|back| frames.len() - 1 - back);
        if known.is_none() {
            frames.push((
                Frame {
                    counter,
                    t_ns,
                    left: Vec::new(),
                    right: Vec::new(),
                    top: [Vec::new(), Vec::new()],
                    hands: [
                        field("left").and_then(|s| quat(&numbers(s))),
                        field("right").and_then(|s| quat(&numbers(s))),
                    ],
                    hands_at: [
                        field("left-at").and_then(|s| s.parse().ok()),
                        field("right-at").and_then(|s| s.parse().ok()),
                    ],
                    head: field("head").and_then(|s| quat(numbers(s).get(3..)?)),
                    head_position: field("head")
                        .and_then(|s| <[f32; 3]>::try_from(numbers(s).get(..3)?).ok()),
                },
                [false; 2],
            ));
        }
        let index = known.unwrap_or(frames.len() - 1);
        if let Some((frame, has)) = frames.get_mut(index) {
            match view {
                0 => frame.left = spots,
                1 => frame.right = spots,
                _ => frame.top[view - 2] = spots,
            }
            if view < 2 {
                has[view] = true;
            }
        }
    }
    frames
        .into_iter()
        .filter(|(_, has)| has[0] && has[1])
        .map(|(f, _)| f)
        .collect()
}

/// Where the left camera sits in the head's frame, from fixes of a controller that lay still
/// while the head moved and turned: each fix is the head's orientation and place in the tracking
/// space and the controller's place in the camera's frame. One point of the room has to explain
/// them all, and that settles the camera's place (the head must turn, not only move: a head
/// that only moves says nothing of it). Returns the camera's place in the head's frame (x
/// right, y up, z back, meters), the controller's place in the room, and how far the fixes are
/// from agreeing, meters (root mean square), over the fixes kept (those far off are dropped
/// once). `None` with fewer than 20 fixes.
pub fn camera_place(
    pair: &StereoPair,
    fixes: &[(Quat, [f32; 3], [f32; 3])],
) -> Option<([f64; 3], [f64; 3], f64, usize)> {
    let head_from_camera = transpose(&pair.camera_from_head());
    // head position + R·(o + C'·p) = X, for each fix: R·o − X = −(head position + R·C'·p).
    let rows: Vec<(M3, V3)> = fixes
        .iter()
        .map(|(head, at, p)| {
            let r = from_quat(*head);
            let seen = apply(&r, apply(&head_from_camera, p.map(f64::from)));
            (r, [0, 1, 2].map(|k| -(f64::from(at[k]) + seen[k])))
        })
        .collect();
    let solve = |keep: &[bool]| -> Option<(Vec<f64>, Vec<f64>)> {
        let mut ata = vec![vec![0.0; 6]; 6];
        let mut atb = vec![0.0; 6];
        for ((r, b), _) in rows.iter().zip(keep).filter(|(_, keep)| **keep) {
            for k in 0..3 {
                let mut a = [0.0; 6];
                a[..3].copy_from_slice(&r[k]);
                a[3 + k] = -1.0;
                for i in 0..6 {
                    atb[i] += a[i] * b[k];
                    for j in 0..6 {
                        ata[i][j] += a[i] * a[j];
                    }
                }
            }
        }
        let x = solve_linear(ata, atb)?;
        let off = rows
            .iter()
            .map(|(r, b)| {
                let ro = apply(r, [x[0], x[1], x[2]]);
                let d: V3 = std::array::from_fn(|k| ro[k] - x[3 + k] - b[k]);
                dot(d, d).sqrt()
            })
            .collect();
        Some((x, off))
    };
    if rows.len() < 20 {
        return None;
    }
    let (_, off) = solve(&vec![true; rows.len()])?;
    let mut sorted = off.clone();
    sorted.sort_by(f64::total_cmp);
    let limit = sorted[sorted.len() / 2] * 3.0;
    let keep: Vec<bool> = off.iter().map(|d| *d <= limit).collect();
    let (x, off) = solve(&keep)?;
    let kept = keep.iter().filter(|k| **k).count();
    let squares: f64 = off
        .iter()
        .zip(&keep)
        .filter(|(_, k)| **k)
        .map(|(d, _)| d * d)
        .sum();
    Some((
        [x[0], x[1], x[2]],
        [x[3], x[4], x[5]],
        (squares / kept as f64).sqrt(),
        kept,
    ))
}

/// What [`calibrate`] found.
#[derive(Debug, Clone, PartialEq)]
pub struct Calibration {
    /// The pair's numbers; its `pitch` is the mean of the two controllers'.
    pub pair: StereoPair,
    /// For each controller (left, right) that was seen: how far below the head's forward the
    /// pair looks and how far it is rolled, radians, as that controller's "up" has it. The two
    /// are separate measurements of the same thing: how well they agree says how far to trust
    /// them.
    pub tilt: [Option<[f64; 2]>; 2],
    /// Exposures used, per controller, and LED sightings in all.
    pub fixes: [usize; 2],
    pub sightings: usize,
    /// What is left over, pixels (root mean square over the sightings).
    pub rms: f64,
    /// The same by distance from the pictures' centre, in rings 80 px wide (the last takes the
    /// corners): what a lens that isn't a plain pinhole would show.
    pub rings: [Ring; 5],
}

/// The sightings of one ring of the picture.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Ring {
    pub sightings: usize,
    /// Root mean square of what is left over, pixels.
    pub rms: f64,
    /// The mean of what is left over along the line from the centre, pixels: positive when LEDs
    /// are expected farther out than their spots are.
    pub outward: f64,
}

/// One fix as the fit keeps it: everything but the cameras' numbers.
struct Observation {
    hand: usize,
    /// The tracking space seen from the head, the controller's heading correction applied.
    head_from_world: M3,
    imu: M3,
    position: V3,
    sightings: Vec<Sighting>,
}

/// The unknowns: focal length, the three centre coordinates, the baseline, and a small turn of
/// the cameras for each controller (which takes up the tilt, and whatever of the heading the
/// tracker left).
const UNKNOWNS: usize = 11;

fn pair_of(unknowns: &[f64], pitch: f64) -> StereoPair {
    StereoPair {
        focal: unknowns[0],
        cx_left: unknowns[1],
        cx_right: unknowns[2],
        cy: unknowns[3],
        baseline: unknowns[4],
        pitch,
    }
}

fn mount(unknowns: &[f64], pitch: f64, hand: usize) -> M3 {
    let turn = &unknowns[5 + hand * 3..8 + hand * 3];
    mul(
        &from_rotation_vector([turn[0], turn[1], turn[2]]),
        &pair_of(unknowns, pitch).camera_from_head(),
    )
}

/// Fits the pair's numbers to a capture of the controllers ([`parse_dump`]), starting from
/// `start` (which must be near enough for the controllers to be found at all:
/// [`super::stereo::PSVR2_BOTTOM`] for a PS VR2). The controllers should be turned about while
/// captured: the focal length shows in how the LED shape's depth changes with its orientation.
/// `None` when fewer than 30 exposures show a controller well.
pub fn calibrate(frames: &[Frame], start: &StereoPair) -> Option<Calibration> {
    let leds = [sense_leds(Hand::Left), sense_leds(Hand::Right)];
    let pitch = start.pitch;
    let mut unknowns = vec![
        start.focal,
        start.cx_left,
        start.cx_right,
        start.cy,
        start.baseline,
    ];
    unknowns.resize(UNKNOWNS, 0.0);
    let scale = [
        10.0, 5.0, 5.0, 5.0, 0.002, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01,
    ];

    // What is left over for every sighting, each pulled in beyond 2 px so that a wrong match
    // weighs little (Huber), and the plain sum of squares for reporting.
    let left_over = |unknowns: &[f64], observations: &[Observation]| -> (Vec<f64>, f64) {
        let pair = pair_of(unknowns, pitch);
        let mut all = Vec::new();
        let mut squares = 0.0;
        for o in observations {
            let rotation = mul(
                &mul(&mount(unknowns, pitch, o.hand), &o.head_from_world),
                &o.imu,
            );
            let shape = Shape::new(&leds[o.hand], &rotation);
            let (_, r) = solve_position(&pair.cameras(), &shape, &o.sightings, o.position, 3);
            for xy in r.chunks(2) {
                let e2 = xy[0] * xy[0] + xy[1] * xy[1];
                squares += e2;
                let weight = if e2 > 4.0 {
                    (2.0 / e2.sqrt()).sqrt()
                } else {
                    1.0
                };
                all.extend([xy[0] * weight, xy[1] * weight]);
            }
        }
        (all, squares)
    };

    let mut result = None;
    let mut headings = [0.0f32; 2];
    for _round in 0..4 {
        // The controllers found with the numbers so far.
        let pair = pair_of(&unknowns, pitch);
        let mut observations = Vec::new();
        for hand in 0..2 {
            let mut tracker = HandTracker::new([Hand::Left, Hand::Right][hand]);
            tracker.set_heading(headings[hand]);
            tracker.leans = false;
            let mount = mount(&unknowns, pitch, hand);
            for frame in frames {
                let (Some(orientation), Some(head)) = (frame.hands[hand], frame.head) else {
                    continue;
                };
                let head_from_world = transpose(&from_quat(head));
                let seen = Seen::new(&pair, &frame.left, &frame.right, &[], None);
                let imu = from_quat(orientation);
                if let Some(s) = tracker.locate(&seen, &mul(&mount, &head_from_world), &imu)
                    && s.sightings.len() >= SCAN_SIGHTINGS
                {
                    observations.push(Observation {
                        hand,
                        head_from_world: mul(&head_from_world, &turn_y(s.heading)),
                        imu,
                        position: s.position,
                        sightings: s.sightings,
                    });
                }
            }
            headings[hand] = tracker.heading();
        }
        let fixes = [0, 1].map(|h| observations.iter().filter(|o| o.hand == h).count());
        if fixes[0] + fixes[1] < 30 {
            return result;
        }

        // Levenberg-Marquardt on the unknowns, the slopes taken by small steps.
        let (mut r, mut squares) = left_over(&unknowns, &observations);
        let mut cost: f64 = r.iter().map(|v| v * v).sum();
        let mut damping = 1e-3;
        for _ in 0..40 {
            let mut columns = Vec::with_capacity(UNKNOWNS);
            for k in 0..UNKNOWNS {
                // A controller that was never seen leaves its turn alone.
                if k >= 5 && fixes[(k - 5) / 3] == 0 {
                    columns.push(vec![0.0; r.len()]);
                    continue;
                }
                let step = scale[k] * 1e-4;
                let mut moved = unknowns.clone();
                moved[k] += step;
                let (rk, _) = left_over(&moved, &observations);
                columns.push(rk.iter().zip(&r).map(|(a, b)| (a - b) / step).collect());
            }
            let mut jtj = vec![vec![0.0; UNKNOWNS]; UNKNOWNS];
            let mut jtr = vec![0.0; UNKNOWNS];
            for i in 0..UNKNOWNS {
                jtr[i] = columns[i].iter().zip(&r).map(|(a, b)| a * b).sum();
                for j in 0..UNKNOWNS {
                    jtj[i][j] = columns[i].iter().zip(&columns[j]).map(|(a, b)| a * b).sum();
                }
            }
            let mut improved = false;
            for _ in 0..8 {
                let mut a = jtj.clone();
                for (i, row) in a.iter_mut().enumerate() {
                    row[i] += damping * (row[i] + 1e-12) + 1e-9 / (scale[i] * scale[i]);
                }
                let Some(step) = solve_linear(a, jtr.clone()) else {
                    break;
                };
                let tried: Vec<f64> = unknowns.iter().zip(&step).map(|(u, s)| u - s).collect();
                let (rt, st) = left_over(&tried, &observations);
                let ct: f64 = rt.iter().map(|v| v * v).sum();
                if ct < cost {
                    improved = cost - ct > 1e-9 * cost;
                    (unknowns, r, squares, cost) = (tried, rt, st, ct);
                    damping = (damping * 0.3).max(1e-9);
                    break;
                }
                damping *= 10.0;
            }
            if !improved {
                break;
            }
        }

        let sightings = r.len() / 2;
        let tilt = [0, 1].map(|hand| {
            (fixes[hand] > 0).then(|| {
                let m = mount(&unknowns, pitch, hand);
                // The camera's forward and right, in the head's frame.
                [(-m[2][1]).atan2(-m[2][2]), m[0][1].asin()]
            })
        });
        let seen: Vec<[f64; 2]> = tilt.iter().flatten().copied().collect();
        let fitted = pair_of(&unknowns, pitch);
        let mut rings = [Ring::default(); 5];
        for o in &observations {
            let rotation = mul(
                &mul(&mount(&unknowns, pitch, o.hand), &o.head_from_world),
                &o.imu,
            );
            let shape = Shape::new(&leds[o.hand], &rotation);
            let (_, left) = solve_position(&fitted.cameras(), &shape, &o.sightings, o.position, 3);
            for (s, xy) in o.sightings.iter().zip(left.chunks(2)) {
                let cx = [fitted.cx_left, fitted.cx_right][s.view];
                let out = [s.at[0] - cx, s.at[1] - fitted.cy];
                let radius = (out[0] * out[0] + out[1] * out[1]).sqrt();
                let ring = &mut rings[((radius / 80.0) as usize).min(4)];
                ring.sightings += 1;
                ring.rms += xy[0] * xy[0] + xy[1] * xy[1];
                ring.outward += (xy[0] * out[0] + xy[1] * out[1]) / radius.max(1.0);
            }
        }
        for ring in &mut rings {
            let n = ring.sightings.max(1) as f64;
            ring.rms = (ring.rms / n).sqrt();
            ring.outward /= n;
        }
        result = Some(Calibration {
            pair: pair_of(
                &unknowns,
                seen.iter().map(|t| t[0]).sum::<f64>() / seen.len() as f64,
            ),
            tilt,
            fixes,
            sightings,
            rms: (squares / sightings as f64).sqrt(),
            rings,
        });
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tracking::stereo::PSVR2_BOTTOM;

    // Measured on one headset from fourteen same-LED correspondences in ONE normal
    // exposure. Fifteen correspondences in two different, held-out exposures independently
    // validate this rotation (under 0.61px row error). It must never become a global default.
    const RECORDED_ALIGNMENT: V3 = [
        -0.004112071331861413,
        0.003328861353291489,
        -0.01492005963837453,
    ];

    #[test]
    fn measured_camera_alignment_recovers_both_hands_across_the_recorded_field() {
        let frames = parse_dump(include_str!(
            "../../tests/fixtures/sense_fisheye_alignment.txt"
        ));
        // Complete 60Hz exposures, not the 5Hz RAW-image subset: acquisition/following
        // thresholds count exposures. The left ring is illuminated in every phase;
        // the right is explicitly switched off in the middle phase.
        let phases = [
            1_353_585_370..2_357_257_162,
            2_467_341_662..7_470_531_245,
            7_523_847_620..8_529_437_120,
        ];
        let mut observed = [[[0usize; 2]; 3]; 2];
        let mut exposures = [0usize; 3];
        for (variant, alignment) in [[0.0; 3], RECORDED_ALIGNMENT].into_iter().enumerate() {
            let mut hands = [HandTracker::new(Hand::Left), HandTracker::new(Hand::Right)];
            for hand in &mut hands {
                hand.set_bottom_fisheyes(true);
                assert!(hand.set_bottom_fisheye_alignment(alignment));
            }
            for frame in &frames {
                let phase = phases.iter().position(|p| p.contains(&frame.t_ns));
                if variant == 0
                    && let Some(phase) = phase
                {
                    exposures[phase] += 1;
                }
                let world = PSVR2_BOTTOM.camera_from_world(frame.head.unwrap());
                for (index, tracker) in hands.iter_mut().enumerate() {
                    if let Some(fix) = tracker.update(
                        &PSVR2_BOTTOM,
                        &world,
                        frame.hands[index].unwrap(),
                        &frame.left,
                        &frame.right,
                    ) && let Some(phase) = phase
                    {
                        observed[variant][phase][index] += 1;
                        if variant == 1 {
                            assert!(
                                fix.sightings >= 10 && fix.rms < MAX_RMS as f32,
                                "phase{phase}/hand{index}/frame{}: {fix:?}",
                                frame.counter
                            );
                        }
                    }
                }
            }
        }
        assert_eq!(exposures, [60, 300, 48]);
        assert_eq!(
            observed[0],
            [[0, 60], [0, 0], [0, 0]],
            "generic calibration repro"
        );
        assert_eq!(
            observed[1],
            [[60, 60], [300, 0], [48, 48]],
            "both illuminated hands must remain acquired; the unlit hand must not false-lock"
        );
    }

    #[test]
    fn a_headset_alignment_does_not_change_rectified_or_other_headset_defaults() {
        let frames = parse_dump(include_str!("../../tests/fixtures/sense_spots_1s.txt"));
        for hand in [Hand::Left, Hand::Right] {
            let mut generic = HandTracker::new(hand);
            let mut profile = HandTracker::new(hand);
            assert!(profile.set_bottom_fisheye_alignment(RECORDED_ALIGNMENT));
            for frame in &frames {
                let Some(orientation) = frame.hands[hand as usize] else {
                    continue;
                };
                let world = PSVR2_BOTTOM.camera_from_world(frame.head.unwrap());
                assert_eq!(
                    generic.update(
                        &PSVR2_BOTTOM,
                        &world,
                        orientation,
                        &frame.left,
                        &frame.right
                    ),
                    profile.update(
                        &PSVR2_BOTTOM,
                        &world,
                        orientation,
                        &frame.left,
                        &frame.right
                    )
                );
            }
            let mut other_headset = HandTracker::new(hand);
            other_headset.set_bottom_fisheyes(true);
            assert_eq!(
                other_headset.bottom.unwrap(),
                super::super::stereo::PSVR2_BOTTOM_FISHEYE
            );
        }
    }

    #[test]
    fn camera_alignment_validation_is_transactional_and_changed_geometry_retires_old_fixes() {
        let frame = parse_dump(include_str!(
            "../../tests/fixtures/sense_fisheye_alignment.txt"
        ))
        .into_iter()
        .next()
        .unwrap();
        let mut tracker = HandTracker::new(Hand::Left);
        tracker.set_bottom_fisheyes(true);
        assert!(tracker.set_bottom_fisheye_alignment(RECORDED_ALIGNMENT));
        let cameras = tracker.bottom;
        tracker.set_bottom_fisheyes(false);
        assert!(tracker.bottom.is_none());
        tracker.set_bottom_fisheyes(true);
        assert_eq!(
            tracker.bottom, cameras,
            "raw-mode toggle must retain this headset's alignment"
        );
        let world = PSVR2_BOTTOM.camera_from_world(frame.head.unwrap());
        assert!(
            tracker
                .update(
                    &PSVR2_BOTTOM,
                    &world,
                    frame.hands[0].unwrap(),
                    &frame.left,
                    &frame.right
                )
                .is_some()
        );
        assert!(tracker.settled && tracker.last.is_some());
        let last = tracker.last;
        for invalid in [
            [f64::NAN, 0.0, 0.0],
            [0.0, f64::INFINITY, 0.0],
            [0.0, 0.0, 0.10],
        ] {
            assert!(!tracker.set_bottom_fisheye_alignment(invalid));
            assert_eq!(tracker.bottom, cameras);
            assert_eq!(tracker.last, last);
            assert!(tracker.settled);
        }
        assert!(tracker.set_bottom_fisheye_alignment(RECORDED_ALIGNMENT));
        assert_eq!(
            tracker.last, last,
            "idempotent profile refresh must not reset tracking"
        );
        assert!(tracker.set_bottom_fisheye_alignment([0.0; 3]));
        assert!(!tracker.settled && tracker.last.is_none() && tracker.monocular_trial.is_none());
        assert_eq!(
            tracker.bottom.unwrap(),
            super::super::stereo::PSVR2_BOTTOM_FISHEYE
        );
    }

    /// Numbers in 0..1 that are the same on every run.
    struct Dice(u64);

    impl Dice {
        fn roll(&mut self) -> f64 {
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (self.0 >> 11) as f64 / (1u64 << 53) as f64
        }
        fn between(&mut self, a: f64, b: f64) -> f64 {
            a + (b - a) * self.roll()
        }
    }

    /// What the two cameras see of a controller: the LEDs well turned towards them, moved by
    /// up to `noise` pixels, and two spots that are no LED.
    fn picture(
        pair: &StereoPair,
        hand: Hand,
        rotation: &M3,
        p: V3,
        noise: f64,
        dice: &mut Dice,
    ) -> [Vec<Spot>; 2] {
        let shape = Shape::new(&sense_leds(hand), rotation);
        let mut views = [Vec::new(), Vec::new()];
        for i in 0..LED_COUNT {
            let at = add(shape.places[i], p);
            if -dot(shape.facings[i], at) / dot(at, at).sqrt() < 0.3 {
                continue;
            }
            let seen = pair.project(at);
            for (view, xy) in seen.iter().enumerate() {
                let (x, y) = (
                    xy[0] + dice.between(-noise, noise),
                    xy[1] + dice.between(-noise, noise),
                );
                if (0.0..640.0).contains(&x) && (0.0..640.0).contains(&y) {
                    views[view].push(Spot {
                        x: x as f32,
                        y: y as f32,
                        area: 30,
                    });
                }
            }
        }
        for view in &mut views {
            for _ in 0..2 {
                view.push(Spot {
                    x: dice.between(0.0, 640.0) as f32,
                    y: dice.between(0.0, 640.0) as f32,
                    area: 12,
                });
            }
        }
        views
    }

    fn some_orientation(dice: &mut Dice) -> Quat {
        Quat::from_rotation_vector([
            dice.between(-1.0, 0.2) as f32,
            dice.between(-0.8, 0.8) as f32,
            dice.between(-0.6, 0.6) as f32,
        ])
    }

    #[test]
    fn a_controller_is_found_whatever_its_heading() {
        let pair = PSVR2_BOTTOM;
        let mut dice = Dice(7);
        let world = pair.camera_from_world(Quat::from_axis_angle([0.0, 1.0, 0.0], 0.3));
        for hand in [Hand::Left, Hand::Right] {
            for drift in [0.0, 0.5, -2.0] {
                let p = [0.08, -0.03, 0.42];
                // An orientation that shows six LEDs or more: fewer can't settle a heading
                // nothing is known of.
                let (orientation, [left, right]) = loop {
                    let orientation = some_orientation(&mut dice);
                    // The controller really is turned `drift` further than its IMU believes.
                    let rotation = mul(&mul(&world, &turn_y(drift)), &from_quat(orientation));
                    let views = picture(&pair, hand, &rotation, p, 0.3, &mut dice);
                    if views[0].len() >= 8 && views[1].len() >= 8 {
                        break (orientation, views);
                    }
                };
                let mut tracker = HandTracker::new(hand);
                let fix = tracker.update(&pair, &world, orientation, &left, &right);
                let Some(fix) = fix else {
                    panic!(
                        "{hand:?} {drift}: {} and {} spots, not found",
                        left.len(),
                        right.len()
                    );
                };
                for (found, real) in fix.position.iter().zip(p) {
                    assert!((f64::from(*found) - real).abs() < 0.002, "{fix:?}");
                }
                assert!(
                    (f64::from(fix.heading) - drift).abs() < 0.02,
                    "{drift}: {fix:?}"
                );
                assert!(fix.sightings >= 8 && fix.rms < 1.0, "{fix:?}");
            }
        }
    }

    /// What the two bottom fisheyes see of a controller: the LEDs turned towards each, in its
    /// raw picture.
    fn fisheye_picture(hand: Hand, rotation: &M3, p: V3, dice: &mut Dice) -> [Vec<Spot>; 2] {
        let shape = Shape::new(&sense_leds(hand), rotation);
        std::array::from_fn(|view| {
            let camera = super::super::stereo::PSVR2_BOTTOM_FISHEYE[view];
            (0..LED_COUNT)
                .filter(|&i| {
                    let at = sub(add(shape.places[i], p), camera.place);
                    -dot(shape.facings[i], at) / dot(at, at).sqrt() > 0.3
                })
                .filter_map(|i| camera.project(add(shape.places[i], p)))
                .filter(|xy| (0.0..1000.0).contains(&xy[0]) && (0.0..1016.0).contains(&xy[1]))
                .map(|xy| Spot {
                    x: (xy[0] + dice.between(-0.3, 0.3)) as f32,
                    y: (xy[1] + dice.between(-0.3, 0.3)) as f32,
                    area: 30,
                })
                .collect()
        })
    }

    #[test]
    fn the_fisheyes_find_a_controller_the_rectified_pair_cannot_see() {
        let pair = PSVR2_BOTTOM;
        let mut dice = Dice(3);
        let world = pair.camera_from_world(Quat::IDENTITY);
        // Out to the right, 55° off the pair's forward: past the rectified pictures' 41°.
        let p = [0.42, 0.05, 0.30];
        assert!(pair.project(p)[0][0] > 640.0, "the rectified pair sees it");
        // Turned so that both fisheyes see six of its LEDs or more.
        let (orientation, rotation) = loop {
            let orientation = some_orientation(&mut dice);
            let rotation = mul(&mul(&world, &turn_y(0.1)), &from_quat(orientation));
            let [left, right] = fisheye_picture(Hand::Right, &rotation, p, &mut dice);
            if left.len() >= 6 && right.len() >= 6 {
                break (orientation, rotation);
            }
        };
        let mut tracker = HandTracker::new(Hand::Right);
        tracker.set_bottom_fisheyes(true);
        let mut fix = None;
        for _ in 0..8 {
            let [left, right] = fisheye_picture(Hand::Right, &rotation, p, &mut dice);
            fix = tracker
                .update(&pair, &world, orientation, &left, &right)
                .or(fix);
        }
        let Some(fix) = fix else { panic!("not found") };
        for (found, real) in fix.position.iter().zip(p) {
            assert!((f64::from(*found) - real).abs() < 0.003, "{fix:?}");
        }
        assert!((f64::from(fix.heading) - 0.1).abs() < 0.03, "{fix:?}");
    }

    #[test]
    fn the_correction_is_the_solvers_turn() {
        let fix = Fix {
            position: [0.0; 3],
            heading: 0.7,
            tilt: [0.1, -0.15],
            sightings: 12,
            rms: 1.0,
        };
        let solver = mul(&from_rotation_vector([0.1, 0.0, -0.15]), &turn_y(0.7));
        let q = from_quat(fix.correction());
        for (a, b) in q.iter().flatten().zip(solver.iter().flatten()) {
            assert!((a - b).abs() < 1e-5, "{q:?} against {solver:?}");
        }
    }

    #[test]
    fn a_settled_heading_does_not_jump_on_a_few_leds() {
        let pair = PSVR2_BOTTOM;
        let mut dice = Dice(11);
        let world = pair.camera_from_world(Quat::IDENTITY);
        let orientation = Quat::from_rotation_vector([-0.5, 0.2, 0.1]);
        let p = [-0.1, 0.02, 0.35];
        let mut tracker = HandTracker::new(Hand::Right);
        let rotation = |heading: f64| mul(&mul(&world, &turn_y(heading)), &from_quat(orientation));
        let mut settled = None;
        for _ in 0..5 {
            let [left, right] = picture(&pair, Hand::Right, &rotation(0.2), p, 0.3, &mut dice);
            settled = settled.or(tracker.update(&pair, &world, orientation, &left, &right));
        }
        assert!(
            settled.is_some_and(|f| (f.heading - 0.2).abs() < 0.02),
            "{settled:?}"
        );
        // The controller turned 120° that its IMU didn't see (nothing does that, but a lock on
        // the ring turned wrong looks just like it): on five LEDs a picture, never taken, even
        // once every heading is tried again.
        for frame in 0..200 {
            let [left, right] = picture(&pair, Hand::Right, &rotation(2.3), p, 0.3, &mut dice);
            let (l, r) = (&left[..left.len().min(5)], &right[..right.len().min(5)]);
            let fix = tracker.update(&pair, &world, orientation, l, r);
            assert!(
                fix.is_none_or(|f| (f.heading - 0.2).abs() < 0.45),
                "frame {frame}: {fix:?}"
            );
        }
        // With all its LEDs in sight it is: that many agree.
        let mut taken = None;
        for _ in 0..10 {
            let [left, right] = picture(&pair, Hand::Right, &rotation(2.3), p, 0.3, &mut dice);
            taken = taken.or(tracker.update(&pair, &world, orientation, &left, &right));
        }
        assert!(
            taken.is_some_and(|f| (f64::from(f.heading) - 2.3).abs() < 0.03),
            "{taken:?}"
        );
    }

    #[test]
    fn a_moving_controller_is_followed_through_dark_frames() {
        let pair = PSVR2_BOTTOM;
        let mut dice = Dice(11);
        let world = pair.camera_from_world(Quat::IDENTITY);
        let orientation = Quat::from_rotation_vector([-0.5, 0.2, 0.1]);
        let mut tracker = HandTracker::new(Hand::Right);
        let mut found = 0;
        for frame in 0..60 {
            let t = f64::from(frame) / 60.0;
            // 0.3 m/s across, and a heading that drifts.
            let p = [-0.1 + 0.3 * t, 0.02, 0.35 + 0.1 * t];
            let rotation = mul(
                &mul(&world, &turn_y(0.2 + 0.05 * t)),
                &from_quat(orientation),
            );
            let [left, right] = picture(&pair, Hand::Right, &rotation, p, 0.3, &mut dice);
            // The LEDs show in half the exposures, ten at a time.
            let lit = frame / 10 % 2 == 0;
            let fix = if lit {
                tracker.update(&pair, &world, orientation, &left, &right)
            } else {
                tracker.update(&pair, &world, orientation, &left[..0], &right[..0])
            };
            assert_eq!(fix.is_some(), lit, "frame {frame}");
            if let Some(fix) = fix {
                found += 1;
                for (found, real) in fix.position.iter().zip(p) {
                    assert!((f64::from(*found) - real).abs() < 0.002, "{fix:?}");
                }
            }
        }
        assert_eq!(found, 30);
    }

    #[test]
    fn a_lean_between_the_imu_and_the_head_is_taken_up() {
        // "Up" for the controller's IMU and for the head's tracking 2.3 degrees apart: without
        // the lean, LEDs 7 cm from the IMU would be 3 mm (4 px at 30 cm) from their spots.
        let pair = PSVR2_BOTTOM;
        let mut dice = Dice(5);
        let world = pair.camera_from_world(Quat::IDENTITY);
        let lean = from_rotation_vector([0.03, 0.0, -0.025]);
        let mut tracker = HandTracker::new(Hand::Right);
        let mut last = None;
        for frame in 0..40 {
            let t = f64::from(frame) / 60.0;
            let orientation = Quat::from_rotation_vector([-0.5 + 0.8 * t as f32, 0.3, 0.2]);
            let p = [0.05 + 0.1 * t, -0.02, 0.3];
            let rotation = mul(&mul(&world, &lean), &from_quat(orientation));
            let [left, right] = picture(&pair, Hand::Right, &rotation, p, 0.3, &mut dice);
            if let Some(fix) = tracker.update(&pair, &world, orientation, &left, &right) {
                last = Some((fix, p));
            }
        }
        let (fix, p) = last.expect("found");
        // The lean itself is not asked for: over a few orientations part of it passes for
        // heading. What counts is that the LEDs fit and the place is right.
        assert!(fix.rms < 0.8 && fix.sightings >= 8, "{fix:?}");
        for (found, real) in fix.position.iter().zip(p) {
            assert!((f64::from(*found) - real).abs() < 0.003, "{fix:?}");
        }
    }

    #[test]
    fn the_cameras_place_is_found_from_a_controller_lying_still() {
        let pair = PSVR2_BOTTOM;
        let mut dice = Dice(9);
        let (camera, controller) = ([-0.04, -0.03, -0.07], [0.1, 0.9, -0.5]);
        let camera_from_head = pair.camera_from_head();
        let fixes: Vec<(Quat, [f32; 3], [f32; 3])> = (0..200)
            .map(|_| {
                let head = Quat::from_rotation_vector([
                    dice.between(-0.4, 0.4) as f32,
                    dice.between(-0.5, 0.5) as f32,
                    dice.between(-0.3, 0.3) as f32,
                ]);
                let at = [0.0, 1.2, 0.0].map(|v| v + dice.between(-0.1, 0.1));
                // The controller in the head's frame, then in the camera's, a millimeter off.
                let in_head = apply(&transpose(&from_quat(head)), sub(controller, at));
                let p = apply(&camera_from_head, sub(in_head, camera));
                (
                    head,
                    at.map(|v| v as f32),
                    p.map(|v| (v + dice.between(-0.001, 0.001)) as f32),
                )
            })
            .collect();
        let (found, room, off, kept) = camera_place(&pair, &fixes).expect("enough fixes");
        assert!(kept > 150 && off < 0.002, "{kept} {off}");
        for k in 0..3 {
            assert!((found[k] - camera[k]).abs() < 0.002, "{found:?}");
            assert!((room[k] - controller[k]).abs() < 0.002, "{room:?}");
        }
    }

    #[test]
    fn a_top_camera_alone_finds_a_controller_again() {
        use crate::tracking::stereo::PSVR2_TOP;
        let pair = PSVR2_BOTTOM;
        let mut dice = Dice(21);
        let world = pair.camera_from_world(Quat::IDENTITY);
        let top_right = PSVR2_TOP[1];
        // What one camera sees of the controller: the LEDs turned to it, a third of a pixel off.
        let seen_by = |camera: &Camera, rotation: &M3, p: V3, dice: &mut Dice| -> Vec<Spot> {
            let shape = Shape::new(&sense_leds(Hand::Right), rotation);
            (0..LED_COUNT)
                .filter(|&i| {
                    let to = sub(camera.place, add(shape.places[i], p));
                    dot(shape.facings[i], to) / dot(to, to).sqrt() > 0.3
                })
                .filter_map(|i| camera.project(add(shape.places[i], p)))
                .filter(|at| (0.0..640.0).contains(&at[0]) && (0.0..640.0).contains(&at[1]))
                .map(|at| Spot {
                    x: (at[0] + dice.between(-0.3, 0.3)) as f32,
                    y: (at[1] + dice.between(-0.3, 0.3)) as f32,
                    area: 30,
                })
                .collect()
        };
        // An orientation that shows the ring to a camera on the right, and a place only that
        // camera sees: up and out to the right.
        let away = [0.5, -0.25, 0.3];
        let mut orientation = None;
        for _ in 0..200 {
            let q = some_orientation(&mut dice);
            let rotation = mul(&world, &from_quat(q));
            let up = seen_by(&top_right, &rotation, away, &mut dice).len();
            let front = picture(
                &pair,
                Hand::Right,
                &rotation,
                [0.05, 0.0, 0.4],
                0.3,
                &mut dice,
            );
            if up >= 7 && front[0].len() >= 8 {
                orientation = Some(q);
                break;
            }
        }
        let orientation = orientation.expect("an orientation both see");
        let rotation = mul(&world, &from_quat(orientation));
        assert!(
            pair.cameras()[0]
                .project(away)
                .is_none_or(|at| !(0.0..640.0).contains(&at[0]))
        );
        let mut tracker = HandTracker::new(Hand::Right);
        // Found by the pair first, in front.
        let [left, right] = picture(
            &pair,
            Hand::Right,
            &rotation,
            [0.05, 0.0, 0.4],
            0.3,
            &mut dice,
        );
        assert!(
            tracker
                .update(&pair, &world, orientation, &left, &right)
                .is_some()
        );
        // Out of every camera's sight for two seconds, then in the top right camera's only.
        for _ in 0..120 {
            assert_eq!(
                tracker.update_with(&pair, &[(top_right, &[])], &world, orientation, &[], &[]),
                None
            );
        }
        let mut found = None;
        for _ in 0..4 {
            let spots = seen_by(&top_right, &rotation, away, &mut dice);
            found = found.or(tracker.update_with(
                &pair,
                &[(top_right, &spots)],
                &world,
                orientation,
                &[],
                &[],
            ));
        }
        let fix = found.expect("found by the top camera alone");
        for (found, real) in fix.position.iter().zip(away) {
            assert!((f64::from(*found) - real).abs() < 0.01, "{fix:?}");
        }
    }

    #[test]
    fn spots_without_a_controller_are_not_a_fix() {
        let pair = PSVR2_BOTTOM;
        let mut dice = Dice(3);
        let world = pair.camera_from_world(Quat::IDENTITY);
        let mut tracker = HandTracker::new(Hand::Left);
        for _ in 0..40 {
            let spots: Vec<Spot> = (0..12)
                .map(|_| Spot {
                    x: dice.between(0.0, 640.0) as f32,
                    y: dice.between(0.0, 640.0) as f32,
                    area: 20,
                })
                .collect();
            // The same lamps in both pictures, a little apart.
            let right: Vec<Spot> = spots
                .iter()
                .map(|s| Spot {
                    x: s.x - 40.0,
                    ..*s
                })
                .collect();
            assert_eq!(
                tracker.update(&pair, &world, Quat::IDENTITY, &spots, &right),
                None
            );
        }
    }

    #[test]
    fn a_dump_is_read() {
        let text = "frame 7 view 0 t 1000 size 640 640 spots 217.11,116.68,560,255 271.52,174.00,538,255 left -0.5,0.5,0.5,0.5 right 0,0,0,1 head 0.1,1.2,0.2,0,1,0,0\n\
                    frame 7 view 1 t 1000 size 640 640 spots 176.90,160.22,575,255 left -0.5,0.5,0.5,0.5 right 0,0,0,1 head 0.1,1.2,0.2,0,1,0,0\n\
                    frame 8 view 0 t 2000 size 640 640 spots left 0,0,0,1\n\
                    [cameras] a line of the log\n";
        let frames = parse_dump(text);
        assert_eq!(frames.len(), 1);
        let f = &frames[0];
        assert_eq!((f.counter, f.t_ns), (7, 1000));
        assert_eq!((f.left.len(), f.right.len()), (2, 1));
        assert_eq!(
            f.left[1],
            Spot {
                x: 271.52,
                y: 174.0,
                area: 538
            }
        );
        assert_eq!(f.hands[1], Some(Quat::IDENTITY));
        assert_eq!(f.hands[0].map(|q| (q.x, q.w)), Some((-0.5, 0.5)));
        assert_eq!(f.head.map(|q| (q.y, q.w)), Some((1.0, 0.0)));
        assert_eq!(f.head_position, Some([0.1, 1.2, 0.2]));
        assert_eq!(f.hands_at, [None; 2]);
    }

    #[test]
    fn orientations_are_put_at_the_exposures_time() {
        // A controller turning 1 rad/s about up, its reports arriving 5 ms after the motion and
        // written with exposures 20 ms older than they are.
        let turn = |t_ns: u64| Quat::from_axis_angle([0.0, 1.0, 0.0], t_ns as f32 * 1e-9);
        let mut frames: Vec<Frame> = (0..20u64)
            .map(|n| {
                let exposure = 1_000_000_000 + n * 16_000_000;
                let report = exposure + 20_000_000;
                Frame {
                    counter: n,
                    t_ns: exposure,
                    left: Vec::new(),
                    right: Vec::new(),
                    top: [Vec::new(), Vec::new()],
                    hands: [Some(turn(report)), None],
                    hands_at: [Some(report + 5_000_000), None],
                    head: None,
                    head_position: None,
                }
            })
            .collect();
        at_exposure(&mut frames, 5_000_000);
        // The first exposure is older than every report: left as it was.
        assert!(frames[0].hands[0].unwrap().angle_to(turn(frames[0].t_ns)) > 0.015);
        for f in &frames[3..] {
            assert!(f.hands[0].unwrap().angle_to(turn(f.t_ns)) < 1e-3);
        }
    }

    /// A second of the capture the built-in numbers come from: both controllers
    /// held about 30 cm in front of a headset lying still, their LEDs showing in about half the
    /// exposures. Only spots, orientations and the head's pose: no picture.
    const CAPTURE: &str = include_str!("../../tests/fixtures/sense_spots_1s.txt");

    #[test]
    fn the_users_controllers_are_found_in_a_real_capture() {
        let frames = parse_dump(CAPTURE);
        assert_eq!(frames.len(), 60);
        let pair = PSVR2_BOTTOM;
        // (hand, fixes at least, heading correction in degrees, the hand's place)
        for (h, hand, at_least, heading, place) in [
            (0, Hand::Left, 22, -23.2, [0.155, -0.06, 0.275]),
            (1, Hand::Right, 25, 40.9, [-0.04, 0.03, 0.295]),
        ] {
            let mut tracker = HandTracker::new(hand);
            let mut fixes = Vec::new();
            for frame in &frames {
                let world = pair.camera_from_world(frame.head.unwrap());
                let orientation = frame.hands[h].unwrap();
                if let Some(fix) =
                    tracker.update(&pair, &world, orientation, &frame.left, &frame.right)
                {
                    fixes.push(fix);
                }
            }
            assert!(fixes.len() >= at_least, "{hand:?}: {}", fixes.len());
            for fix in &fixes {
                assert!(fix.rms < 2.0 && fix.sightings >= 5, "{hand:?}: {fix:?}");
                assert!(
                    (fix.heading.to_degrees() - heading).abs() < 7.0,
                    "{hand:?}: {fix:?}"
                );
                for (found, near) in fix.position.iter().zip(place) {
                    assert!((found - near).abs() < 0.05, "{hand:?}: {fix:?}");
                }
            }
            let mean_rms = fixes.iter().map(|f| f.rms).sum::<f32>() / fixes.len() as f32;
            assert!(mean_rms < 1.7, "{hand:?}: {mean_rms}");
        }
    }

    #[test]
    fn the_cameras_numbers_are_found_from_a_capture() {
        // A headset whose pair is not the one built in.
        let truth = StereoPair {
            focal: 341.0,
            cx_left: 322.0,
            cx_right: 320.5,
            cy: 311.0,
            baseline: 0.0825,
            pitch: 0.29,
        };
        let mut dice = Dice(42);
        let head = Quat::from_axis_angle([0.0, 1.0, 0.0], -0.4);
        let world = truth.camera_from_world(head);
        let drift = [0.3, -0.6];
        let mut frames = Vec::new();
        for n in 0..240 {
            let mut frame = Frame {
                counter: n,
                t_ns: n * 16_700_000,
                left: Vec::new(),
                right: Vec::new(),
                top: [Vec::new(), Vec::new()],
                hands: [None; 2],
                hands_at: [None; 2],
                head: Some(head),
                head_position: None,
            };
            for (hand, side) in [(Hand::Left, -1.0), (Hand::Right, 1.0)] {
                let orientation = some_orientation(&mut dice);
                let p = [
                    0.04 + side * dice.between(0.08, 0.2),
                    dice.between(-0.12, 0.1),
                    dice.between(0.25, 0.5),
                ];
                let h = hand as usize;
                let rotation = mul(&mul(&world, &turn_y(drift[h])), &from_quat(orientation));
                let [left, right] = picture(&truth, hand, &rotation, p, 0.4, &mut dice);
                frame.left.extend(left);
                frame.right.extend(right);
                frame.hands[h] = Some(orientation);
            }
            frames.push(frame);
        }
        let found = calibrate(&frames, &PSVR2_BOTTOM).expect("enough fixes");
        assert!(found.fixes[0] > 100 && found.fixes[1] > 100, "{found:?}");
        assert!(found.rms < 0.6, "{found:?}");
        let pair = found.pair;
        assert!((pair.focal - truth.focal).abs() < 2.0, "{pair:?}");
        assert!((pair.baseline - truth.baseline).abs() < 0.0005, "{pair:?}");
        assert!((pair.cy - truth.cy).abs() < 2.0, "{pair:?}");
        let between = (pair.cx_left - pair.cx_right) - (truth.cx_left - truth.cx_right);
        assert!(between.abs() < 0.5, "{pair:?}");
        assert!((pair.pitch - truth.pitch).abs() < 0.01, "{pair:?}");
        for tilt in found.tilt.iter().flatten() {
            assert!(
                (tilt[0] - truth.pitch).abs() < 0.01 && tilt[1].abs() < 0.01,
                "{tilt:?}"
            );
        }
    }
}

#[cfg(test)]
mod strong_stereo_contract_tests {
    use super::*;
    fn strong() -> Solution {
        Solution {
            position: [0., 0., 0.5],
            heading: 0.,
            tilt: [0.; 2],
            rms: 1.7,
            sightings: (0..16)
                .map(|i| Sighting {
                    view: i / 8,
                    spot: i % 8,
                    led: i % 8,
                    at: [0.; 2],
                })
                .collect(),
        }
    }
    #[test]
    fn strong_stereo_requires_unique_leds_unique_blobs_both_views_and_existing_rms_bound() {
        let good = strong();
        assert!(good.strong_stereo());
        let mut weak = good.clone();
        weak.sightings.truncate(8);
        assert!(!weak.strong_stereo());
        let mut one = good.clone();
        for s in &mut one.sightings {
            s.view = 0;
        }
        assert!(!one.strong_stereo());
        let mut repeat = good.clone();
        for s in &mut repeat.sightings {
            s.led %= 4;
        }
        assert!(!repeat.strong_stereo());
        let mut duplicate = good.clone();
        duplicate.sightings[1].spot = duplicate.sightings[0].spot;
        assert!(!duplicate.strong_stereo());
        let mut loose = good.clone();
        loose.rms = MAX_RMS;
        assert!(!loose.strong_stereo());
        let legacy = HandTracker::new(Hand::Left);
        assert!(!legacy.scan_usable(&good));
        let mut paired = legacy;
        paired.paired_confirmation = true;
        assert!(paired.scan_usable(&good));
        let mut weak_tight = good.clone();
        weak_tight.sightings.truncate(8);
        weak_tight.rms = 1.1;
        assert!(paired.scan_usable(&weak_tight));
        assert!(HandTracker::new(Hand::Left).scan_usable(&weak_tight));
    }
}
