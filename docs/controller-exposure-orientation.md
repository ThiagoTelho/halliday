# Controller orientation at camera exposure

The optical worker previously received each controller's newest quaternion,
although the camera spots belonged to an earlier exposure. It checked that the
controller had settled, but carried no sample age or timestamp. A connected
controller that stopped reporting could therefore keep proposing an optical fit
with an old orientation. This is separate from cross-hand blob ownership.

The core now retains raw fused orientations with their existing unwrapped Sense
device time. A cached lookup maps the camera's host timestamp to that device
timeline using the **current** minimum-transport offset. Updating that offset
therefore rebases the complete history consistently. Mapped host timestamps are
not frozen separately beside individual samples.

Both clocks already have the same host domain: Sense `feed_place` estimates its
device offset from `host_time_ns()`, and camera exposure mapping uses the
headset's VTS offset estimated from that same function. On macOS it is
`CLOCK_UPTIME_RAW`, the Mach/display-link host clock. Independent transport-offset
estimates still have measurement uncertainty; this does not claim perfect
hardware clock synchronization or introduce a guessed delay correction.

The lookup reuses saved-camera replay's shortest-quaternion-hemisphere
interpolation and existing50ms support on each bracket side. Exact samples are
usable; unsupported, unbracketed or stale times return no orientation. There is
no latest-pose fallback, forward extrapolation, added wait or frame queue. Clock
gaps/resets, reconnect, calibration changes and controller recenter retire old
history. Duplicate device timestamps retain the existing clock and cannot
replace cached samples; a normal hardware-counter wrap remains one unwrapped
timeline. Current-state game poses, IMU fusion, optical geometry, grip/aim mount,
and LED behavior are unchanged. The current controller heading is applied only
after sampling raw orientation, matching the established frame convention.

The app requests a cached quaternion for the camera exposure and includes only
supported hands in the paired optical solve. The new C-ABI getter is additive;
existing state structs and APIs retain their layout and behavior.

CPU tests cover device/host offset steps, reset and reconnect epochs, quaternion
signs, interpolation, gaps and unbracketed times. Paired association and
saved-profile regressions cover their combined behavior. Physical acceptance
remains separate.
