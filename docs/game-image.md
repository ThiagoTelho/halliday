# Shared game image: render scale, FSR 1 and RCAS

Mac: **Sound and display → Game image**. Headset: **Settings → Game image**.
The default is **100% render scale, FSR off and RCAS off**.

| Control | Range | Apply |
| --- | --- | --- |
| Game render scale | 50–100%, steps of 5% | Restart game |
| FSR 1 EASU | On/off, independent of render scale | Live |
| RCAS sharpening | On/off and 0–100% strength | Live |

The full image target is **2016×2048 per eye**, replacing the initial
1440×1468 target. Both dimensions are 32-pixel aligned and the stereo width
fits the existing 4096-pixel bridge limit. At 80%, the offered render size is
**1600×1632**. Games may choose another size; the filter follows actual images.
100% therefore means the new full target, not the earlier lower pixel budget.

Render scale changes game workload independently of FSR. With FSR off, smaller
frames use ordinary compositor sampling. With FSR on, EASU reconstructs them to
the full target; it never downscales larger frames. At the full target, EASU-only
is a bypass. RCAS works with or without EASU, and retains its chosen strength
when disabled. FSR 1 is spatial reconstruction, not temporal anti-aliasing.

## Image and lifetime contract

Game projection → optional Spacewarp prediction → display-colour preparation → EASU/RCAS → existing
latest-head reprojection → lens correction → display.

The shared renderer processes opaque, full-frame side-by-side game images.
Transparent projections, partial UV regions, videos, WebXR and ordinary interface
panels bypass the filter. No game shader or game file is changed.

Pose, FOV and vertical orientation remain attached to the source projection.
Repeated display refreshes reuse a processed texture; a fresh source sequence or
changed filter setting invalidates the cache. Work is encoded on the renderer's
existing Metal queue without CPU readback/waits. Metal retains replaced texture
banks while submitted command buffers still reference them.

Explicit linear input is converted to display-encoded RGB before FSR; hardware
sRGB sampling restores the renderer's intended colour interpretation afterward.
Each eye has separate sample bounds. Legacy untagged producers retain their
existing transfer convention. This contribution adds no runtime-side colour
protocol or graphics binding.

Render-size edits are deferred while a client, capture or GPU read is active.
The bridge is recreated between sessions; an active game keeps its negotiated
size. FSR and RCAS settings apply directly without recreating that bridge.

## Source and validation

AMD [FidelityFX FSR 1](https://github.com/GPUOpen-Effects/FidelityFX-FSR)
(v1.20210629), MIT: [Metal translation and local changes](../app/Resources/fsr1/SOURCE.md).
The complete AMD notice ships with the shader assets and packaged licenses.

CPU: `tools/test-game-image-settings.sh` covers persistent defaults, bounds,
five-percent steps, independent toggles and preservation of other preferences.
The complete host can also be checked with Swift 6 typecheck.

GPU checks are explicit and separate:

```sh
tools/test-game-upscaler-metal.sh
tools/test-frame-colour-metal.sh
python3 tools/test-game-image-preview.py --app build/Halliday.app --output build/validation/game-image
```

These exercise actual pixels, eye isolation, colour, identity bypass, texture
reuse and the production compositor. They require a Metal device and must not be
run during a measured game benchmark. CPU/typecheck results do not establish
visual quality, game FPS or physical headset acceptance.

Game cadence and physical refresh controls are described in [game-cadence.md](game-cadence.md).

Experimental image-only frame prediction and its independent live switch are described in [game-spacewarp.md](game-spacewarp.md). It is off by default; FSR and RCAS remain independent.
