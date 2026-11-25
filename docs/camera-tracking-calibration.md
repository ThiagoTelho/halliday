# Tracking-camera alignment

Halliday can load a measured **per-headset** relative alignment of the raw bottom
camera pair. This is independent of display lens distortion and controller pose
or mounting offsets. The generic constants remain the default.

The affected headset's raw images contained both controllers' LEDs in both
cameras. The ordinary detector reproduced the saved spots, but generic
rectification left approximately 4px of vertical disparity in real same-LED
pairs. The unchanged 1.5px correspondence gate therefore rejected the left
controller. A small relative camera rotation, fitted to 14 LED pairs from one
exposure, predicts 15 held-out pairs from other exposures to within 0.61px.
Lowering brightness thresholds, changing image stride and loosening unrelated
hand offsets did not address this geometry error.

## Local profile

`~/Library/Application Support/Halliday/camera-tracking-calibration.json`:

```json
{
  "version": 1,
  "headset_id": "EXACT-CACHED-PCB",
  "camera_mode": 16,
  "right_fisheye_rotation_radians": [0.0, 0.0, 0.0]
}
```

The zeros above illustrate identity, not the measured correction. The profile
must contain the connected headset's exact cached PCB identity and a measured
three-component rotation vector. Its exponential rotation left-multiplies the
generic right camera rotation in **raw-camera-local axes**. Both rectification
and final raw reprojection use that same corrected camera. It is not an Euler
angle vector and must not be copied to a different headset as a universal fix.

The file is optional, bounded to 16KiB, regular and not a leaf symlink. Values
must be finite, with rotation magnitude at most 5°. Invalid/missing/mismatched
profiles use the generic calibration. Rectified camera modes are unchanged.
The connected PCB identity comes from firmware information already fetched at
connection time; profile polling sends no new USB command.

Reloading once a second retires old worker generations and optical fusion for
both hands before accepting another geometry. Equal profiles retain history.
Manual mounting/heading choices survive; no new sensor or hand pose offset is
introduced. Removing the file restores generic geometry without reinstalling.

## Validation

- Core regression fixture replays all 440 recorded exposures, including the
  phase-transition intervals. In the 408 explicitly timed stable exposures,
  calibrated left acquisition is 60/60, 300/300 and 48/48; generic is zero.
- The lit right hand remains 60/60 and 48/48. Its deliberately unlit middle
  phase produces zero false fixes.
- Alignment is transactional, per handle and applied to both hands. Existing
  rectified capture behavior is unchanged. Changed geometry resets associations.
- Worker regression compares actual asynchronous results to the C ABI and
  rejects stale queued results after geometry changes, reset and disconnect.

The saved-data result establishes the matching fix on the recorded poses. It
does not substitute for final physical verification across a wider movement
range. Raw room images and real hardware identities stay out of source control.
