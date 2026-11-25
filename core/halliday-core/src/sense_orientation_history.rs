//! Bounded controller orientations in their device-clock domain. Host mapping
//! is applied at lookup, so a minimum-transport offset update rebases the whole
//! history consistently rather than mixing several host-time mappings.
use crate::math::Quat;
use std::collections::VecDeque;

/// The existing offline `hands::at_exposure` support domain, per bracket side.
pub const MAX_BRACKET_DISTANCE_NS: i64 = 50_000_000;
/// Existing camera-output lifetime250ms plus one supported50ms bracket.
const KEEP_NS: i64 = 250_000_000 + MAX_BRACKET_DISTANCE_NS;
const MAX_SAMPLES: usize = 1024;

/// Same shortest-hemisphere normalized interpolation used by saved camera
/// replay. Unsupported or unbracketed times never become a latest-pose guess.
pub fn between(before: (i64, Quat), after: (i64, Quat), target: i64) -> Option<Quat> {
    let span = after.0.checked_sub(before.0)?;
    let from = target.checked_sub(before.0)?;
    let to = after.0.checked_sub(target)?;
    if span <= 0
        || from < 0
        || to < 0
        || from > MAX_BRACKET_DISTANCE_NS
        || to > MAX_BRACKET_DISTANCE_NS
    {
        return None;
    }
    let k = from as f32 / span as f32;
    let q1 = if before.1.dot(after.1) < 0. {
        -after.1
    } else {
        after.1
    };
    Some(
        Quat {
            x: before.1.x + (q1.x - before.1.x) * k,
            y: before.1.y + (q1.y - before.1.y) * k,
            z: before.1.z + (q1.z - before.1.z) * k,
            w: before.1.w + (q1.w - before.1.w) * k,
        }
        .normalized(),
    )
}

#[derive(Clone, Debug, Default)]
pub struct OrientationHistory {
    samples: VecDeque<(i64, Quat)>,
}
impl OrientationHistory {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn reset(&mut self) {
        self.samples.clear();
    }

    /// Raw unwrapped device time. A backward device clock starts a new epoch;
    /// duplicate timestamps and malformed orientations cannot replace a sample.
    pub fn push_device_time(&mut self, device_ns: i64, orientation: Quat) -> bool {
        let q = orientation;
        let norm = q.dot(q);
        if ![q.x, q.y, q.z, q.w, norm].iter().all(|v| v.is_finite()) || norm < 1e-8 {
            return false;
        }
        if self.samples.back().is_some_and(|s| device_ns == s.0) {
            return false;
        }
        if self.samples.back().is_some_and(|s| device_ns < s.0) {
            self.reset();
        }
        self.samples.push_back((device_ns, q));
        while self.samples.len() > MAX_SAMPLES
            || self
                .samples
                .front()
                .is_some_and(|s| device_ns.saturating_sub(s.0) > KEEP_NS)
        {
            self.samples.pop_front();
        }
        true
    }

    /// Both arguments are in nanoseconds. `current_offset_ns` is the existing
    /// host-minus-device estimate, not an offset captured beside each sample.
    pub fn sample_host_time(&self, exposure_host_ns: i64, current_offset_ns: i64) -> Option<Quat> {
        let target = exposure_host_ns.checked_sub(current_offset_ns)?;
        let at = self.samples.iter().position(|s| s.0 >= target)?;
        if self.samples[at].0 == target {
            return Some(self.samples[at].1);
        }
        if at == 0 {
            return None;
        }
        between(self.samples[at - 1], self.samples[at], target)
    }
}
