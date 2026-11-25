//! Halliday core: PS VR2 headset and Sense controller drivers, tracking and timing.
//!
//! Everything here is free of Apple UI frameworks so it can be tested by replaying recorded
//! data, without a headset. The Swift app calls it through the C ABI in [`ffi`], declared in
//! `include/halliday_core.h`.

pub mod apk;
pub mod bridge_haptics;
pub mod ffi;
pub mod game_bridge;
pub mod game_haptics;
mod hand_pair_ffi;
pub mod math;
pub mod psvr2;
pub mod recording;
pub mod sense;
mod sense_orientation_history;
pub mod sense_output;
mod sense_output_ffi;
pub mod session;
pub mod summary;
pub mod synthetic;
pub mod time;
pub mod tracking;
pub mod video;

/// Crate version, as set in `Cargo.toml`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
