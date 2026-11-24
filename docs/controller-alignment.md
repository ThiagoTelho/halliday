# Sense game-hand orientation

The game bridge previously published the menu pointer's mounting rotation as its
shared controller pose. The default was a comfortable 42° local-X tilt; an
intentional pointer calibration could also replace it. Both OpenVR and OpenXR
consumed that same pose.

The game path now replaces that pointer mounting term with the source-derived
Sense **aim** mounting rotation, 49.8703°. Relative to the former default, this
lifts the shared game-hand frame by 7.8703° around its own X axis. Both hands use
the same sensor axes. Camera geometry, position, fusion, world-space angular
velocity and menu pointing are unaffected. There is no user angle slider.

Reference: Monado revision `2069b76b3a66fb5916e3cedae84d9524c1ebab4a`:

- [Sense model and aim transforms](https://gitlab.freedesktop.org/monado/monado/-/blob/2069b76b3a66fb5916e3cedae84d9524c1ebab4a/src/xrt/drivers/pssense/pssense_driver.c#L1571).
- [IMU-to-model mounting transform](https://gitlab.freedesktop.org/monado/monado/-/blob/2069b76b3a66fb5916e3cedae84d9524c1ebab4a/src/xrt/drivers/pssense/pssense_led_model.h#L27).

In Halliday's unchanged sensor axes the resolved AIM chain is
`qIMU × Rx(50.2703°) × Rx(39°) × Rx(-39.4°)`.

This defines Halliday's existing **aim-derived** shared orientation. The optional
controller-frame contract now lets OpenXR resolve its distinct grip orientation
at the action binding, without changing the host, pointer or OpenVR orientation.
It copies no reference translations and establishes no measured anatomical wrist
angle. See [controller orientation frames](controller-pose-frames.md). Physical
acceptance in a game remains separate from source-chain and rotation regressions.

Validation: `tools/test-game-controller-alignment.sh` compares the complete
reference chain across yaw/pitch/roll and previous pointer calibrations. It also
checks the upward sign and unchanged room-space angular velocity. Recorded
optical tracking and per-headset camera calibration are not altered.
