# Windows OpenXR foundation

A source-built x64 OpenXR runtime for Windows games under Wine/CrossOver,
using Halliday's existing v6 shared game bridge. It implements D3D11, D3D12 and
Vulkan 1/2 graphics bindings without an external proprietary runtime or patched
graphics translation library. This is a compatibility implementation, not an
OpenXR conformance or every-game claim.

This foundation adds runtime/protocol sources and optional test targets. It does
not bundle/register the runtime, change a bottle, replace game files, or wire the
new runtime into AppDelegate/Renderer. Native OpenXR and automatic API/headset
routing are separate changes.

## Build and CPU checks

```sh
make windows-openxr-check VR_JOBS=2  # native CMake protocol/layout/math checks
make windows-bridge-check VR_JOBS=2 # Rust and CPU-only Swift lease/producer checks
make windows-haptic-feed-check VR_JOBS=2 # C++ -> Rust -> Swift CPU mailbox check
make windows-openxr VR_JOBS=2       # optional Windows DLL and fixture executables
```

Native checks need CMake, Python 3 and a C++17 compiler. Bridge checks need Rust
and Apple's Swift 6 toolchain. Windows builds additionally need LLVM-MinGW and
public Vulkan headers; set `HALLIDAY_MINGW_BIN` and `VULKAN_SDK` when they are not
in standard locations. `python3 windows-openxr/build.py native|windows --jobs 2`
is the direct equivalent. Builds do not launch Wine or access a headset.

The Windows DLL, relative JSON manifest and test callers are emitted under
`windows-openxr/build/windows/bin/`. They are not added to the ordinary app by
this change. To exercise a compiled DLL manually, an independently started host
must expose the shared bridge; a later host-integration change provides the app
setup flow.

## Runtime contract

- One live instance/session owns the producer registration. Event polling
  handles lifecycle, focus, quit and host loss independently of frame rendering.
  Late teardown cannot unregister a replacement session.
- D3D11 uses the application's device and reusable staging resources. D3D12
  requires its DIRECT queue and a successful readback capability roundtrip.
  Vulkan 1 accepts app-created objects; Vulkan 2 validates runtime-mediated
  device/queue creation. Swapchains expose real runtime-owned images.
- Opaque stereo uses bounded paired capture for every executable. The current
  GPU pair is queued while the preceding complete pair is consumed; the first
  capture primes the pipeline. There is no game allowlist or alternate slow
  profile. GPU-to-CPU-to-shared-memory transfer remains an explicit copy path.
- Source pose, submitted per-eye cameras/FOV, rectangles, colour and orientation
  travel with their corresponding captured pixels. Focus/reference/layout/session
  changes retire pending work. Ordered quads, alpha and empty submissions use
  coherent composition batches. Invalid required metadata retains the previous
  complete frame.
- Input snapshots use separate locking from video/GPU waits. Pose history,
  connection/tracking/motion validity, action offsets, analog input and per-hand
  bindings are handled independently. Grip/aim action identity is retained;
  this does not claim two physically calibrated anatomical hand origins.
- Haptic output uses bounded per-hand mailboxes with focus, session-epoch,
  expiry and explicit-stop rules. The Swift feed delivers generic callbacks;
  controller/app wiring is separate.

`HALLIDAY_BRIDGE_PATH` supplies a Windows-visible path to an existing host file;
`HALLIDAY_BRIDGE` is a compatibility alias. Without it, lookup is relative to the
staged runtime directory. Clients never create/truncate the host's file. An
unavailable/owned host fails explicitly rather than stealing a producer lease.
Host recovery retires the old inode and atomically publishes a free new bridge;
delayed clients/readers remain isolated on the old mapping.

## Compatibility and limits

The v6 Header/State/Frame layouts and legacy C APIs remain intact. Optional
versioned records use reserved header bytes for haptics, focus, projection,
panels and motion validity. New C accessors expose producer status/session epoch,
claimed-frame metadata and explicit host retirement without widening old DTOs.
The additive head-motion getter reports measured eye-centre velocity while
preserving the previous display-prediction trajectory and legacy gyro semantics.

Supported images are RGBA8/BGRA8 UNORM/sRGB, one sample/mip/face, one or two array
slices, three dynamic images or one static image, up to ten swapchains. Geometry
must fit the shared bridge's capacity. Composition accepts a stereo projection
and up to eight ordered quads, including quad-only/empty frames. OpenGL bindings,
protected content, depth composition and full conformance are outside scope.

## Validation boundaries

The default checks cover cross-language layouts, seqlocks, ownership/retirement,
projection/layer integrity, math, measured motion, haptic expiry, producer changes
and stale-lease timing with synthetic data. They use no Wine, GPU, HID or game.
`tools/test-independent-haptic-feed.sh` additionally links a locally built core
static library and exercises C++ → Rust → Swift mailbox delivery without a
physical controller.

`smoke.py`, `vulkan_smoke.py` and Windows fixture executables are explicit GPU
integration tests for a disposable CrossOver bottle. They are not run by the CPU
check targets. Some tests construct a synthetic host inside the fixture; none
establish real game/headset compatibility. CPU duration inside xrEndFrame,
helper submissions, game FPS and end-to-end latency are different measurements.

## Attribution

The Windows ABI/lifecycle/action-space and initial D3D11 frontend derive from
[BasaltVR](https://github.com/frenchbaguetteman/BasaltVR), revision
`c104bc0b489384745157bc42e357f08d17e41638`, under `LICENSE-BasaltVR`. Its original
network/video transport and graphics-provider patches are not used.

OpenXR 1.1.58 headers retain `LICENSE-Khronos-MIT` and came from Monado revision
`ae43b1893e4544189bb6333c79e19dc3ecfee673`; no Monado runtime source is included.
Public Vulkan headers and LLVM-MinGW runtime notices are recorded in
`LICENSE-Khronos-Vulkan-MIT` and `LICENSE-LLVM-MinGW`.
