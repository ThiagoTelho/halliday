# Ordinary native Alyx frame bridge

This is the MIT VeRantyx v0.3.2 bridge source, with its shared-memory wire
layout isolated from the guest OpenVR implementation. The frame reader uses
Halliday's coherent copied-slot check. Its original data members, pose/input
handling, loading renderer, upload, and optional rotation warp are retained.
No benchmark instrumentation is included.

The copied source is from the [armax9/VeRantyx fork](https://github.com/armax9/VeRantyx),
release [v0.3.2-native-moltenvr](https://github.com/armax9/VeRantyx/releases/tag/v0.3.2-native-moltenvr)
(6 November 2026), commit `df680b6a8bedf8284d9a2c637274d67aeb658fe0`:
[bridge source directory](https://github.com/armax9/VeRantyx/tree/df680b6a8bedf8284d9a2c637274d67aeb658fe0/MoltenVRBridge)
and [wire layout source](https://github.com/armax9/VeRantyx/blob/df680b6a8bedf8284d9a2c637274d67aeb658fe0/NativeARM/vrruntime/vr_runtime.h).
The original project is [Ag3497120/VeRantyx](https://github.com/Ag3497120/VeRantyx),
copyright 2026 Ag3497120, under the
[MIT license](https://github.com/armax9/VeRantyx/blob/df680b6a8bedf8284d9a2c637274d67aeb658fe0/LICENSE).
All seven copied bridge/header files and the wire header match the recorded
commit before the local adaptations listed in `SOURCE.json`.

The source-built executable requires an explicit absolute
`HALLIDAY_NATIVE_OPENXR_RUNTIME`; without it, it fails clearly before opening
any runtime. There is no installed-provider fallback. The ordinary launcher
supplies Halliday's source-built runtime, with its selected-only colour helper.
It also resolves the selected port's Vulkan loader;
the executable links only `@rpath/libMoltenVK.dylib`. The supported guest ABI is
the one recorded in `SOURCE.json`; an unknown port keeps its original bridge.

Build from this repository with public Vulkan SDK headers and an explicit
MoltenVK library:

```sh
native-alyx/build-frame-bridge.sh \
  --vulkan-include "$VULKAN_SDK/include" \
  --moltenvk-library /path/to/libMoltenVK.dylib
```

The script writes `build/native-alyx/bin/halliday-native-frame-bridge` and its
MIT/OpenVR notices. It does not launch a runtime or alter the installed app,
game, or its settings. The build targets macOS 14, arm64, matching the native
VeRantyx port. It has no dependency on an external source checkout.

`SOURCE.json` records the original source hashes. The copied source is covered
by `Native-Alyx-Bridge-MIT.txt`; the Khronos negotiation header retains its
MIT/Apache SPDX notice. `OpenVR-BSD.txt` preserves the upstream attribution.

## Native Touch controller-frame boundary

The verified guest advertises Oculus Touch and binds its hand action poses to
OpenVR `/pose/raw`. The intermediate adapter receives OpenXR `/input/grip/pose`.
These frames differ: the Touch model puts its OpenXR grip at local X rotation
+20.6 degrees and a mirrored model origin relative to raw. The adapter therefore
composes the inverse component before publishing the guest raw pose. World
angular velocity is unchanged; known linear velocity moves to the new origin
with the angular-velocity lever arm. Without known angular motion, the old
raw-origin finite-difference fallback remains responsible for linear velocity.

This clean-room math uses numeric frame metadata, not OpenComposite code. See
[the pinned primary profile](https://github.com/GameNative/opencomposite/blob/35c2ce526ed1c9460924b1c2880def198f63a7b7/OpenOVR/Misc/Input/OculusInteractionProfile.cpp#L85).
The guest's existing Touch wrist skeleton already uses the standard OpenHand
root and does not cancel this missing basis conversion.

Only the exact currently verified independent runtime identity, `Halliday`
version `0.0.1`, enables this boundary. The launcher supplies
`HALLIDAY_ALYX_TOUCH_RAW_POSE=1`, preserving an explicit `0` rollback. An ordinary
launch without the flag uses the same negotiated runtime properties. A legacy/unknown runtime or version preserves
its prior adapter behavior, including with a stale inherited opt-in. An explicit
direct value other than `1` disables the conversion. No game launcher or game settings are
modified, and common Sense mounting, OpenXR poses and Windows consumers stay
unchanged.

The reported visual estimate of about 7 degrees is not used as a calibration.
The demonstrated raw/grip basis difference is 20.6 degrees. The full raw origin
moves about 102 mm as required by the Touch model; the existing guest wrist bone
then composes from raw. The host currently preserves its natural controller
origin when declaring Sense API axes, so actual wrist position and orientation
still require a native headset check. CPU frame-contract success alone does not
establish anatomical hand alignment.
