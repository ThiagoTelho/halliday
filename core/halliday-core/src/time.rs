//! Host clock shared by the Rust core and the Swift app.
//!
//! On macOS this is `CLOCK_UPTIME_RAW` in nanoseconds: the same clock as `mach_absolute_time`,
//! `CACurrentMediaTime()` and display-link timestamps (which are in seconds). So a frame's
//! `targetTimestamp * 1e9` can be handed to the tracker directly.

/// Host monotonic time in nanoseconds.
#[cfg(target_os = "macos")]
pub fn host_time_ns() -> i64 {
    const CLOCK_UPTIME_RAW: u32 = 8;
    unsafe extern "C" {
        fn clock_gettime_nsec_np(clock_id: u32) -> u64;
    }
    // SAFETY: plain libc call with a valid clock id; it has no preconditions.
    unsafe { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) as i64 }
}

/// Host monotonic time in nanoseconds (non-macOS fallback, used by CI on other platforms).
#[cfg(not(target_os = "macos"))]
pub fn host_time_ns() -> i64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_nanos() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advances_with_real_time() {
        let a = host_time_ns();
        std::thread::sleep(std::time::Duration::from_millis(20));
        let d = host_time_ns() - a;
        assert!((15_000_000..200_000_000).contains(&d), "{d}");
    }
}
