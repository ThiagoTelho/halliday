# Native OpenXR and VeRantyx helpers

This contribution extends Halliday's independent native OpenXR runtime; it adds
no installed-game changes or automatic launcher integration. The later host PR
connects the app UI, runtime selection and managed game lifecycle.

The native runtime supports Metal and Vulkan 1/2 on the public v6 bridge. It
retains coherent source poses, eye geometry, colour tags and ordered quad
composition. Native readback batches both eyes and quads on the application's
queue, then publishes only completed work. This remains GPU-to-CPU transport,
not zero copy. See [runtime contract and limitations](../core/halliday-openxr/README.md).

The public `native-alyx` helpers provide:

- A bounded native Steam readiness gate, which checks a global Steam user without
  launching Steam, creating a user, or requiring online status.
- Selected-process runtime redirection and a narrowly identified legacy encoded
  SDR boundary. Other applications and ordinary sRGB images keep their original
  dispatch/transfer interpretation.
- An optional MIT VeRantyx **0.3.2** frame reader. It accepts a stable copied slot
  even if another complete slot becomes newer; actual overwrite triggers one
  bounded retry. Pixels, pose and FOV remain one publication. The wrapper selects
  it only for the verified original bridge SHA-256; unknown versions retain their
  original reader. No installed executable is overwritten.

The optional reader is source-built against public Vulkan headers and an
explicit MoltenVK library. Its
[source provenance, ABI and MIT/BSD notices](../native-alyx/frame-bridge/README.md)
are retained. No closed OpenXR runtime or third-party binary is included.

## Build and CPU checks

```sh
cargo test --manifest-path core/Cargo.toml -p halliday-openxr -j 2
cargo build --manifest-path core/Cargo.toml -p halliday-openxr -j 2
tools/test-native-openxr-dispatch.sh
tools/test-native-coherent-frame-reader.sh
python3 tools/test-native-alyx-wrapper.py
python3 native-alyx/build.py
python3 tools/test-native-alyx-redirect.py
python3 tools/test-native-alyx-colour.py
python3 tools/test-steam-readiness.py
```

The Rust audits use isolated mappings and fake graphics objects to cover action
state, grip/aim offsets, velocities, swapchain ordering, projection geometry,
focus, recenter, session teardown, haptics and loader dispatch. The helper tests
use inert scripts/libraries; they do not load Steam, a game or a graphics driver.
These checks do not establish actual rendered pixel correctness, game FPS,
headset comfort or physical acceptance. GPU and game validation are separate.

For a relocatable universal runtime, use
`tools/build-independent-native-openxr.sh [OUTPUT_DIRECTORY]`. It respects the
caller's Rust/Xcode environment; dependencies may be fetched normally. Set
`HALLIDAY_CARGO_OFFLINE=1` only when already cached. Both macOS Rust targets and
public Vulkan headers (`$VULKAN_SDK/include` or `/opt/homebrew/include`) are
required. Runtime builds do not need an installed game.

Optional GPU acceptance fixtures are included but require explicit execution:

```sh
python3 tools/test-native-independent-metal.py --runtime PATH_TO_RUNTIME
python3 tools/test-native-independent-vulkan.py --runtime PATH_TO_RUNTIME --driver PATH_TO_DRIVER
```

They verify real stereo pixels/geometry/colour and batching against isolated
public host mappings. They are separate from CPU validation and must not run
during game performance measurements.
