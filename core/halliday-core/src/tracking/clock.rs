//! Headset clock handling.
//!
//! The PS VR2 stamps IMU samples and SLAM poses with one microsecond counter, the "VTS" timestamp,
//! 32 bits wide (it wraps every ~71.6 minutes). [`VtsUnwrapper`] turns it into a continuous 64-bit
//! timeline and [`ClockOffset`] maps that timeline onto the host's monotonic clock.

/// Unwraps 32-bit microsecond timestamps into a continuous nanosecond timeline.
///
/// Small steps backwards are allowed (streams arrive out of order relative to each other: SLAM
/// poses are ~23 ms old when they arrive), so each step is read as a signed 32-bit difference.
#[derive(Debug, Default, Clone)]
pub struct VtsUnwrapper {
    last_raw: Option<u32>,
    last_us: i64,
}

impl VtsUnwrapper {
    /// Converts a raw VTS value to nanoseconds on the unwrapped timeline. The first value seen
    /// defines the timeline's origin offset (it maps to itself).
    pub fn unwrap_ns(&mut self, raw_us: u32) -> i64 {
        let us = match self.last_raw {
            None => raw_us as i64,
            Some(last) => self.last_us + raw_us.wrapping_sub(last) as i32 as i64,
        };
        // Only move the reference forward, so a late (older) packet does not drag it back.
        if self.last_raw.is_none() || us > self.last_us {
            self.last_raw = Some(raw_us);
            self.last_us = us;
        }
        us * 1000
    }
}

/// Estimates `host_ns - vts_ns`, the offset between the headset's clock and the host's.
///
/// Every packet gives a sample `arrival_time - sample_time`, which is the true offset plus a
/// positive, jittery transport delay. The smallest sample is the best estimate, so the filter
/// snaps down to any lower sample and otherwise creeps up slowly, which lets it follow clock drift
/// and recover from an outlier.
#[derive(Debug, Clone)]
pub struct ClockOffset {
    offset_ns: Option<f64>,
    /// Fraction of the gap closed per sample when a sample is above the estimate.
    creep: f64,
}

impl Default for ClockOffset {
    fn default() -> Self {
        // Status packets arrive at 1 kHz: a gain of 1e-3 gives a ~1 s time constant upward.
        ClockOffset {
            offset_ns: None,
            creep: 1e-3,
        }
    }
}

impl ClockOffset {
    pub fn update(&mut self, vts_ns: i64, host_ns: i64) {
        let sample = (host_ns - vts_ns) as f64;
        self.offset_ns = Some(match self.offset_ns {
            None => sample,
            Some(o) if sample < o => sample,
            Some(o) => o + (sample - o) * self.creep,
        });
    }

    /// `host_ns - vts_ns`, once at least one sample was seen.
    pub fn offset_ns(&self) -> Option<i64> {
        self.offset_ns.map(|o| o.round() as i64)
    }

    pub fn host_to_vts(&self, host_ns: i64) -> Option<i64> {
        self.offset_ns().map(|o| host_ns - o)
    }

    pub fn vts_to_host(&self, vts_ns: i64) -> Option<i64> {
        self.offset_ns().map(|o| vts_ns + o)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwraps_across_the_32_bit_boundary() {
        let mut u = VtsUnwrapper::default();
        let a = u.unwrap_ns(u32::MAX - 1000);
        let b = u.unwrap_ns(500); // wrapped: 1501 us later
        assert_eq!(b - a, 1501 * 1000);
        let c = u.unwrap_ns(2500);
        assert_eq!(c - b, 2000 * 1000);
    }

    #[test]
    fn late_packets_map_backwards_without_moving_the_reference() {
        let mut u = VtsUnwrapper::default();
        let a = u.unwrap_ns(100_000);
        let late = u.unwrap_ns(77_000); // a SLAM pose 23 ms older
        assert_eq!(a - late, 23_000_000);
        let b = u.unwrap_ns(101_000);
        assert_eq!(b - a, 1_000_000);
    }

    #[test]
    fn offset_converges_to_the_minimum_delay() {
        let mut c = ClockOffset::default();
        let true_offset = 5_000_000_000i64;
        // Deterministic pseudo-random delay between 0.2 and 3.2 ms.
        let mut seed = 12345u64;
        for i in 0..5000i64 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let delay = 200_000 + ((seed >> 33) % 3_000_000) as i64;
            let vts = i * 1_000_000;
            c.update(vts, vts + true_offset + delay);
        }
        let err = c.offset_ns().unwrap() - true_offset;
        assert!((0..400_000).contains(&err), "error {err} ns");
        assert_eq!(c.host_to_vts(c.vts_to_host(42).unwrap()), Some(42));
    }

    #[test]
    fn offset_follows_upward_drift() {
        let mut c = ClockOffset::default();
        c.update(0, 1_000_000); // outlier: offset looks like 1 ms
        for i in 1..10_000i64 {
            c.update(i * 1_000_000, i * 1_000_000 + 3_000_000); // real offset 3 ms
        }
        let o = c.offset_ns().unwrap();
        assert!((2_990_000..=3_000_000).contains(&o), "{o}");
    }
}
