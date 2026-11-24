# Physical-rate late reprojection

The physical display clock can present the newest completed stereo scene even when the main thread or scene producer is delayed. Head/controller publication remains on the existing display tick. Scene ingestion and lens presentation have separate bounded ownership.

`CompositorRefreshDriver` receives CVDisplayLink pulses before main-thread coalescing. Each pulse carries its own target, start and identity. `CompositorSceneMailbox` retains the newest successful scene and newest pending request, with one scene writer and one lens GPU reader. A drawable wait owns neither a scene read lease nor a stale FIFO request. After acquisition, the presenter selects the newest eligible scene and takes a fresh coherent head pose.

Three scene texture slots and the existing three drawable pool remain bounded. A GPU completion releases its exact scene lease; an old callback cannot publish into a newer epoch. Producer, display, content, recenter and calibration changes retire unsubmitted work. A failed scene preserves the previous successful image. Already submitted GPU resources remain retained until completion.

The pose is queried for a plausible presentation slot after drawable acquisition. Presented timestamps establish refresh phase; commit-to-present delay is diagnostic rather than an additional phase wait. Known coherent tracking generations permit normal large rotations, while unknown legacy sources retain the conservative guard. Invalid angular velocity suppresses row-scan prediction without discarding a valid orientation.

Image acquisition can be skipped when scene GPU credit is unavailable. Runtime heartbeats, input and haptic processing continue, and captured-window acknowledgements still drain. Desktop, preview and non-latched rendering retain their existing paths. The lens sampler also keeps filtering inside each eye at the stereo boundary while retaining normal interior filtering.

## Validation

Run `make compositor-check` on macOS with Swift 6. The CPU suites cover newest-request selection after a blocked drawable, successful/failed scene ownership, readers surviving retirement, concurrent resets, physical pulses while the main thread is stalled, 90/120 Hz target selection and actual-present telemetry semantics.

The receipt in `validation/independent-compositor-cpu.json` records these CPU checks and full host type checking. CPU results establish ownership and clock-policy behavior; they do not establish panel timing, photon latency, visual comfort or a game FPS gain. No game, display, headset or GPU is accessed by the CPU runner.
