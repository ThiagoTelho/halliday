# Automatic game cadence

Mac: **Sound and display → Game image → Half frame rate**.
Headset: **Settings → Game image → Half frame rate**.

| Mode | Game cadence | Display / tracking |
| --- | --- | --- |
| Off | Full rate | Full rate |
| Half | 60 FPS at 120 Hz; 45 FPS at 90 Hz | Full rate |
| Auto | Full rate when sustainable; half rate when overloaded | Full rate |

Spacewarp is independent: when enabled it generates intermediate images only
while half rate is active. Selecting Off explicitly keeps real full-rate frames.
Enabling Spacewarp from Off selects Half for the previous one-click behavior;
Auto is never changed to Half by enabling Spacewarp. Existing preferences retain
their previous effective cadence, without writing a migration at startup.

## Policy and evidence

[Meta's PC ASW documentation](https://developers.meta.com/vr/documentation/native/pc/asynchronous-spacewarp/)
describes Auto engaging when an application cannot maintain native display rate.
Its [performance HUD documentation](https://developers.meta.com/vr/documentation/native/pc/dg-hud/)
confirms that the application then runs at half rate. Neither source publishes
an exact entry FPS, recovery FPS, timing window, or hysteresis. This implementation
uses that principle, with Halliday-specific thresholds; it does not reproduce
Meta's undisclosed controller. Quest Application Spacewarp is a different,
application-integrated motion/depth API.

Auto measures successful stereo publications by the current producer. It does
not use compositor FPS, predicted display timestamps, optical latency, or claim
to measure native GPU render time. The same host policy covers Halliday's native
OpenXR, Windows OpenXR and Windows OpenVR paths, independently of graphics API.
An application's own fixed cap can also cause Auto to select half rate.

- Entry: two consecutive 0.5-second windows below **97% of physical refresh**,
  after 0.25 seconds of settling. Sustained 110 FPS at 120 Hz engages; isolated
  hitches do not immediately change mode.
- Hold: at least **5 seconds** at half rate before testing recovery.
- Recovery: a bounded full-rate probe, with 0.25 seconds of settling and
  **1 second** of observation. Recovery requires at least 99% of native rate,
  allowing one publication of counter-boundary uncertainty.
- Failed probes return to half rate; retries back off to **8 / 16 / 30 seconds**.
  A capped 60-FPS stream cannot prove that 120 FPS is possible. The brief probe
  is necessary because the current producer interfaces expose no independent
  workload measurement excluding their pacing waits. A failed probe may briefly
  expose the application's original uneven cadence.
- Paused/dashboard/loading intervals and producer, clock, or refresh changes
  discard stale observations. Off and Half override Auto immediately.

Changing cadence retains the XR session, image size, mapping and controller pose
publication. The normal Spacewarp algorithm and scene-cut fallback are unchanged.
Auto is available on Halliday's source-built native OpenXR, Windows OpenXR
and Windows OpenVR paths. No per-game executable lists are used.

The policy tests are synthetic delivery traces. They do not constitute a game
FPS benchmark or an optical-latency measurement.

`tools/test-game-auto-frame-rate.sh` runs the fake-clock producer policy and
actual cadence actuator scenarios, then checks host wiring. The settings and
Spacewarp preference fixtures additionally cover read-only migration, explicit
command-line overrides and independent frame-generation selection. No test in
these suites starts a game, changes a display mode or opens a headset.
