# Sense pose and optical-exposure time

The host previously used two independent times for a controller: optical/inertial position at the compositor's `frameTarget`, and sensor orientation carried forward by Bluetooth callback age plus a separate lookahead setting. A changed display target or transport delay could therefore rotate the hand at a different instant from its position. Motion used the newest unpredicted sensor orientation as well.

`halliday_sense_state_timed` now returns the unchanged `HallidaySenseState` plus the sensor sample's existing device-to-host clock mapping under one controller mutex. A separate getter after reading the state would race the HID callback. The old C function delegates to the new snapshot with a null optional timestamp output; the state structure and all offsets remain unchanged.

The Swift host resolves a single signed target before any fixed pointer/game mount. A valid compositor target takes precedence over generic lookahead. A past target uses the exact bracketed sensor history; a new connection without that bracket uses the measured sample time for both components. Future prediction respects the common support of position and orientation: the existing position filter allows 60 ms beyond the newest sample, below the former orientation-only 80 ms limit. Position, orientation, motion calibration and lean decay use that returned target. No prediction is added inside the optical solver.

The LED model already locates the controller's IMU origin. No Sony driver/root/IMU translations or new mounting angles are imported. A local lever, where a pose contract supplies one, is rotated with the **predicted sensor orientation**, then the fixed local orientation is applied. The zero-translation existing game contract remains unchanged.

## Delayed Bluetooth brackets

Camera and left/right Bluetooth arrivals are independent. The former host consumed each camera counter once even when one connected controller did not yet have a bracketed orientation at that exposure. If the other hand was ready, the exposure permanently reached the solver without the late hand. New Bluetooth data could not repair it.

`HandExposureStaging` retains at most four immutable camera snapshots. It retries the missing exact-exposure orientation without blocking a thread or replacing it with a latest-state guess. The newest complete snapshot wins; after 50 ms (the existing bracket-support domain) the newest expired partial snapshot can keep the visible peer progressing. A stalled link does not cause repeated 50 ms output pauses: after one bounded pipeline warm-up, peer outputs continue at camera cadence. Stale or unsettled controllers are not expected. Camera geometry, controller connection and head-generation changes retire the pending work.

One-line timing counters distinguish late/recovered/expired brackets from an optical-fit rejection in subsequent ordinary logs. These counters make no claim that every left-controller loss is caused by Bluetooth timing. In particular, this patch does not change LED programming, camera geometry, pose model, joint association scoring or reacquisition thresholds.

## Validation

`tools/test-sense-pose-timeline.sh` checks signed targets, transport mapping, history fallback, common extrapolation limits, quaternion normalization, and predict-before-lever order. It replays 126 both-hand SO(3) segments derived from the already saved movement endpoints, without claiming independently measured raw gyro accuracy. A separate saved 64-exposure replay adds 24 ms of asymmetric left Bluetooth delivery delay: all 64 exposures retain both original hand orientations. Stalled-link, disconnected/unsettled, bounded-capacity and generation-change cases are covered. The C probe compares every state-field offset, size and alignment to build101's DTO.

The existing recorded normal/left-only/normal, wrong-identity, crossing, loss/reacquisition and camera-alignment Rust regressions remain required. Physical tracking acceptance in the headset remains a separate check.

Reference reviewed (MIT), without copying device offsets: [PSVR2Toolkit driver-host proxy, revision 2ab97b51](https://github.com/BnuuySolutions/PSVR2Toolkit/blob/2ab97b51d78332ad20c363de63f70c11a86b0dab/projects/psvr2_openvr_driver_ex/driver_host_proxy.cpp#L79). Its `GetPose` factors the already rotated driver-root translation into a consistent sensor/root transform. It does not implement the host's presentation-time predictor in that file.
