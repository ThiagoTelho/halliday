# Controller orientation frames

Halliday's existing Sense game orientation is AIM-derived. Both OpenXR action
bindings previously returned it, so `/input/grip/pose` and `/input/aim/pose` had
the same axes. This change declares the source orientation per physical hand
and resolves the requested API frame at each binding. Its coordinate contract is covered by both-hand API and replay regressions;
physical anatomical alignment is a separate headset acceptance check.

The canonical host orientation stays `qIMU * Rx(49.8703°)`. Explicit Sense AIM
declarations receive `Rx(+60°)` by **right** multiplication only for OpenXR GRIP;
OpenXR AIM, the dashboard pointer, OpenVR clients, mouse hands and old hosts
retain their previous orientations. No position, tracking model, IMU fusion,
world linear/angular velocity or anatomical wrist offset changes. This is an
orientation conversion, not Monado's full grip/aim origin translation.

The source constants come from Monado revision
`2069b76b3a66fb5916e3cedae84d9524c1ebab4a`:
[Sense model, AIM and GRIP transforms](https://gitlab.freedesktop.org/monado/monado/-/blob/2069b76b3a66fb5916e3cedae84d9524c1ebab4a/src/xrt/drivers/pssense/pssense_driver.c#L1571).
Its AIM chain in the unchanged IMU basis is `Rx(50.2703+39-39.4°)`; GRIP is
`Rx(50.2703+39+20.6°)`. The difference is +60°, independent of hand and room
rotation. The [OpenXR standard pose identifiers](https://registry.khronos.org/OpenXR/specs/1.1-khr/html/xrspec.html#semantic-paths-standard-pose-identifiers)
define GRIP by the physical hand and AIM by platform pointing conventions;
using Touch-compatible input names does not make those two frames identical.

Basis audit: the actual compiled production `sense_leds()` output was compared
with the pinned Monado model, emission corrections and inverse LED-to-IMU
transform: all 17 LED positions/normals per hand and three noncollinear basis
directions agree within double precision. HID fusion uses unchanged calibrated
sensor axes; optical heading and lean corrections act in room space. No hidden
LED/model/root mount was found in the source quaternion. This establishes a
coordinate convention; it does not measure the user's anatomical alignment.

HLCF v1 occupies 32 reserved bytes at offset 65480, immediately after HLFT,
without changing v6 fields or existing ABI. It contains magic/version/size/hand
count, a seqlock, the exact outer state sequence and two orientation kinds:
`0=legacy`, `1=Sense AIM`. The host commits metadata before publishing the even
state sequence. Readers reject odd, stale, unknown or malformed declarations
and keep legacy behavior. Old publish APIs explicitly clear kinds. Physical
Sense and emulated mouse hands may coexist or switch independently.

Native and Windows OpenXR retain each declaration with its complete historical
input sample. Action offsets and their velocity lever arms use the selected API
axes; measured velocity at the unchanged controller origin is preserved. GRIP
and AIM remain distinct entities for relative-space calculations.

CPU validation covers old/new host and reader combinations, sequence wrap,
mixed physical/mouse hands, unknown metadata, arbitrary local/world rotations,
unchanged origin/motion, C ABI publication, and actual native action bindings
through `xrLocateSpace`, including relative GRIP/AIM, offsets, velocity and old
display-time samples. Windows production cross-compiles and its portable
protocol/state-reader tests pass; no Windows graphics or headset execution is
claimed. The existing alignment, pointer, focus and input-rearm guards remain.

Validation uses the common native action-space fixtures and Windows protocol
fixtures described above. No game-specific adapter or wrist-origin translation
is part of this contract.
