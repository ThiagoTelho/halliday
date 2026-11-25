# Portable production-path validation

These fixtures exercise public source and synthetic data. They include no room
captures, device identity, private runtime or historical benchmark harness.
Production rendering and routing are unchanged; the app gains only an explicit
hidden-environment snapshot oracle.

## CPU and compile checks

Build `halliday-core --release` before the C ABI fixture. The linked scripts also
accept `HALLIDAY_CORE_LIBRARY_DIR` pointing to an already-built static library.

```sh
tools/test-bridge-colour-protocol.sh
tools/test-vulkan-readback-failures.sh
python3 tools/tests/IsolatedAppFixtureTests.py
python3 tools/tests/ValidationRunnerGuardsTests.py
cargo build --manifest-path core/Cargo.toml -p halliday-probe --example openxr-panel-producer --release -j 2
tools/test-game-bridge-lease-metal.sh --compile-only
python3 tools/test-native-runtime-behavior.py --output build/validation/native-lifecycle-compile
```

The colour fixture traverses real C++ producer → mapped v6 bridge → Rust/C ABI →
Swift tags, ownership and legacy fallback. Vulkan fault injection calls the
production readback code with fake device callbacks: rejected batches, allocation
rollback and pending-work protection cause no GPU work or forced driver errors.
The lifecycle probe compiles by default; `--run` explicitly opens a Metal device.

## Explicit GPU acceptance

```sh
python3 tools/test-game-image-preview.py --run --app build/Halliday.app --output build/validation/image-oracle --unseen-surroundings
python3 tools/test-openxr-panel-bridge.py --run --app build/Halliday.app --output build/validation/panel-oracle
tools/test-game-bridge-lease-metal.sh --run
```

Snapshot runners copy the source app into a newly generated test identity,
disable updates and clean only their UUID's support/log/defaults paths. They
refuse a source app missing the requested snapshot entry point and require a
new output below repository `build/validation`. The producer accepts only the
canonical UUID-named acceptance bridge. The source app remains unchanged.

The hidden-environment oracle proves zero unseen environment baking/geometry,
unchanged game pixels and resumed environment work on return home. It continues
to process new game images. No frozen-scene/SceneHold path or latency tracing is
included. Panel cases cover coherent projection/quad composition, geometry,
colour, torn metadata, input, live cadence and lifecycle. The GPU lease fixture
checks that pending copies retain the old mapping through completion.

## Optional Windows loader/graphics execution

`tools/build-openxr-loader-smoke.sh --sdk PATH_TO_OPENXR_SDK_1.1.65 --jobs 2`
cross-builds against official public SDK sources with LLVM-MinGW. It downloads
nothing, modifies no SDK source and starts no Wine process.

The loader, paired-transfer and Vulkan runners execute only with `--run` and an
explicit disposable project bottle. The bottle must be inside ignored project
test directories, contain `cxbottle.conf`, and carry a regular file named
`.halliday-disposable-openxr-test` containing `halliday-openxr-disposable-v1`
followed by a newline. Create that marker only for a bottle made for these tests.
The loader journals/restores its registry value and refuses unrelated changes;
the graphics runners use copied source-built artifacts and unique bridge paths.
They never launch a game or register anything in a normal user bottle.

The Vulkan compatibility CLI delegates to the guarded runner and expects the
current 48 verified image records. Paired-transfer checks use the fixture's
internal assertions instead of a removed diagnostic log line.

## Deliberate exclusions and limits

The historical upstream OpenVR wrapper is not exported: it requests a
`game-host --quit-after` option absent from the retained public probe. The
preserved OpenVR implementation still has its existing Rust/math/protocol tests;
exporting an unsupported quit/pixel wrapper would create a misleading test.
SceneHold, LatencyTrace, private comparisons, raw captures and ad-hoc game-control
scripts remain outside this contribution.

CPU/compile checks establish no actual GPU pixel result, physical comfort,
every-game compatibility or FPS/latency gain. GPU, Wine, loader execution and
headset/game acceptance must be reported separately.
