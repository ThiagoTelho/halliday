# Coherent head tracking discontinuities

`halliday_session_predict_tracked` returns the existing complete motion DTO and a
nonzero tracking generation under **one** Session tracker lock. It does not read a
generation before or after a separate prediction. The previous 56-byte pose and
72-byte motion structs and their getters keep their ABI and behavior. The new
tracked DTO is 80 bytes, with its `uint64_t` generation at offset 72.

A completed scene keeps the generation of the exact head sample used to render
it. A late lens update can therefore distinguish a normal turn from tracker
discontinuity. Matching nonzero generations permit ordinary large rotations;
different generations retire the old scene. Unknown/legacy zero remains subject
to the previous conservative rotation guard. The presenter owns that policy;
this core change does not alter projection, optical meshes, game/controller
poses, prediction settings, smoothing or frame generation.

The process allocates a unique generation for each new tracker, including a
Session's internal USB reconnect and replay-loop replacement. Explicit yaw/full
recenter and clearing recenter advance it too. A discontinuous SLAM timestamp
gap, or a correction that the tracker's existing 0.035-radian/3-centimeter
continuity test takes immediately, advances the token. The rotation test compares
the new pose against the **gyro-carried** previous pose, rather than the absolute
angular change: an ordinary integrated 15-degree head turn does not advance it.
The correction check also runs when smoothing was explicitly disabled, without
changing the legacy unsmoothed prediction result.

This is a conservative image-invalidating discontinuity token. It does not claim
every large SLAM correction changes the global coordinate basis. It does not
provide an exact physical tracking-loss timestamp or fix existing transport-clock
uncertainty. A failed prediction leaves the C output untouched.

CPU coverage checks legacy motion equality, normal large IMU motion, small versus
large correction, timestamp gaps, recenter/reset, tracker replacement, legacy C
layout and failure behavior, and concurrent replacement/prediction coherence.
No headset, display, HID or GPU is needed.
