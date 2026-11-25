# Native OpenXR runtime

Halliday's source-built MIT runtime supports native macOS applications through
`XR_KHR_metal_enable`, `XR_KHR_vulkan_enable` and `XR_KHR_vulkan_enable2`.
It uses the public v6 game bridge. No installed game, closed runtime, guest-specific
adapter, gaze extension or eye-calibration feature is required or included.

The runtime implements the instance/session lifecycle, tracked spaces, action
sets, controller grip/aim frames, swapchain ordering, projection views and ordered
quad layers. Images carry the corresponding head pose, per-eye FOV, colour transfer
and source timing. Standard UNORM and sRGB formats retain their API interpretation.

Metal and Vulkan batch both eyes and quads on the application's queue before
publishing completed work. The transport includes GPU-to-CPU readback; it is not
zero-copy. Ownership, heartbeat and session-generation checks prevent a retired
producer from releasing a replacement's resources. See the [runtime contract and
limitations](../core/halliday-openxr/README.md).

## Build and validation

```sh
cargo test --manifest-path core/Cargo.toml -p halliday-bridge -p halliday-openxr -j 2
cargo build --manifest-path core/Cargo.toml -p halliday-openxr -j 2
tools/test-native-openxr-dispatch.sh
```

These device-free tests cover loader dispatch, instance/session ownership, actions,
relative spaces, both-hand grip/aim transforms and velocities, projection/FOV,
focus, recentering, swapchain validation, teardown and ordinary haptic commands.
They do not establish game compatibility, photon latency or physical hand alignment.

Build a relocatable universal runtime using
`tools/build-independent-native-openxr.sh [OUTPUT_DIRECTORY]`. Both macOS Rust
targets and public Vulkan headers are required. The script respects the caller's
Rust/Xcode environment; `HALLIDAY_CARGO_OFFLINE=1` uses cached dependencies only.

Optional GPU fixtures require explicit execution and a separately supplied runtime:

```sh
python3 tools/test-native-independent-metal.py --runtime PATH_TO_RUNTIME
python3 tools/test-native-independent-vulkan.py --runtime PATH_TO_RUNTIME --driver PATH_TO_DRIVER
```

These fixtures use isolated mappings to check real pixels, geometry, colour and
batching. They neither launch games nor replace headset acceptance.
