# Sense tracking and game poses

This contribution changes controller acquisition, camera geometry and the final
shared game-hand frame without depending on Windows OpenXR, CrossOver routing or
image-processing modules.

- Retry factory IMU feature reads after transient Bluetooth wake failures. Reads
  run off the input loop and display actor; generation checks reject old-device
  work after disconnect/reconnect.
- Serialize controller output per connection. LED latch/timing is retained when
  vibration packets are sent; independent counters and retained device lifetimes
  prevent haptic traffic from disabling optical tracking.
- Move optical solving to a serial worker with one replaceable pending exposure.
  Results keep the exposure's head pose/time. Reset, disconnect and geometry
  changes invalidate queued results without waiting on the display actor.
- Improve cold acquisition, including confirmed one-camera hypotheses. Keep the
  existing fit/reach/heading acceptance gates and rejection of unlit controls.
- Optionally load measured bottom-camera alignment for one exact connected
  headset. Generic camera geometry remains the default; both hands receive the
  same validated calibration. No hardware identity is logged.
- Replace the menu pointer's 42° mounting term with the source-derived 49.8703°
  game AIM term. This is rotation only, with no added wrist translation or
  per-game offsets. Measured gyro/linear motion is published in game axes using
  the existing bridge fields; expired samples publish zero motion.
- PS/menu taps no longer recalibrate tilt. PS hold still recenters, and a PS tap
  during a game toggles the dashboard. Digital trigger contact stays separate
  from analog travel.

[Camera profile format and recorded-data validation](camera-tracking-calibration.md)
and [AIM transform derivation](controller-alignment.md) describe the boundaries.
The shared game frame is aim-derived; it does not implement a distinct anatomical
grip origin. Physical angle/position acceptance across games remains separate
from the transform and recorded-data regressions.

## CPU validation

Use Swift 6 with a matching macOS SDK and Rust. No headset, HID device, game or
GPU workload is used by these fixtures:

```sh
cargo test --manifest-path core/Cargo.toml -p halliday-core --lib
cargo test --manifest-path core/Cargo.toml -p halliday-core --test monocular_acquisition
cargo build --manifest-path core/Cargo.toml -p halliday-core
export HALLIDAY_CORE_LIBRARY_DIR="$PWD/core/target/debug"
tools/test-sense-calibration.sh
tools/test-sense-haptics.sh
tools/test-sense-led-programming.sh
tools/test-hand-tracking-worker.sh
tools/test-camera-tracking-profiles.sh
tools/test-game-controller-alignment.sh
tools/test-game-controller-motion.sh
tools/test-sense-aim-defaults.sh
```

The worker fixture compares asynchronous output with synchronous C-ABI results.
The recorded-camera regression verifies both illuminated hands and a deliberately
unlit negative phase. Test data contains scalar spot/IMU samples rather than raw
room images or real hardware identifiers. Passing these tests does not establish
full game compatibility or physical tracking throughout the headset's view.
