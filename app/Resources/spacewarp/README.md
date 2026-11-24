# Colour-only Spacewarp composition

`composition.metal` is independent MIT composition code. Motion estimation is
the separately attributed AMD FidelityFX Optical Flow implementation in
`../amd-optical-flow`; no OFXR/GPL composition code is included.

The wrapper copies two **real** SBS frames into canonical unflipped,
display-encoded RGBA8. It aligns the previous real frame into the current real
camera using rotation and the submitted per-eye FOV. The renderer uses no
invented translation depth for this pre-alignment. AMD estimates the remaining
image/object motion. Left and right eyes retain separate
geometry, motion fields and GPU scene-cut flags.

The same alignment pass also compares the original canonical real images,
before camera compensation, using per-eye flags and 16x16-pixel change maps.
Changes of at most two encoded levels do not enable displacement. An unchanged eye retains its
exact current pixels even when the tracked camera moves. This prevents
head-locked menus from acquiring false motion solely from compensation. A small
animated indicator no longer enables motion across the rest of an unchanged
eye: displacement needs change at the target or its current source location.
All masks stay on the GPU; no CPU readback or wait is added.

On a repeated source frame, forward vectors indexed in current-image blocks
extrapolate colour by `alpha × previous→current displacement`, with alpha at
most 0.5. The current real render pose/FOV remains the output pose/FOV; ordinary
latest-head reprojection follows synthesis. Synthetic images never feed back
into history, and no future frame is required.

The motion field is bilinearly interpolated and each output pulls one current
colour sample. There is no fastest-neighbour ranking or distant background
painting. Tagged sRGB colours are filtered in linear light. Scene cuts and
invalid bounds retain current colour. There is **no per-pixel depth**: occlusion ordering, thin geometry,
transparency and newly revealed content remain limitations of colour-only
extrapolation. This is experimental, not an equivalent of depth/motion-vector
application spacewarp.

All production work is GPU-only. The renderer submits the real scene first and
prepares analysis in a separate subsequent command buffer, keeping full optical
flow outside that real scene's lens-completion barrier. Callers must
encode and commit in FIFO order on one command queue, consume output after
synthesis, and reset history at discontinuities. Different queues are rejected.
The production loader must explicitly supply genuine AMD Optical Flow; a nil
provider primes history but never synthesizes.

`tools/test-game-spacewarp-metal.sh` checks real Metal composition using known
motion fixtures, plus authentic AMD integration and bounded GPU-stage timings.
`tools/test-game-spacewarp-static-metal.sh` checks the complete genuine AMD path
on flat, textured and menu images, including 2016x2048 per eye and +/-0.05-degree
camera jitter over unchanged head-locked pixels, both with and without a small
animated indicator. Static background checks exclude a documented 96x96-pixel
corner around the 8x8 indicator in each eye; they do not assert its changing
pixels are stationary.
Readback/waits exist only in that test executable. Its timings exclude the game,
headset scanout, Halliday scene compositor and end-to-end latency.

## Discontinuous source pairs

`discontinuity.metal` reuses low-resolution analysis to check source pairs for broad replacements, snap changes and newly introduced menu regions, including changes not visible in the camera metadata. It adds no CPU readback wait or extra frame. Evidence from either eye rejects the prediction for both eyes, retaining the exact current real stereo pair instead of mixing temporal phases or painting local fallback tiles. The current real source then primes the next continuous pair.

The renderer retains an exact-sequence GPU result ticket. Only after that scene's GPU completion may the presenter classify it as real or predicted; classification never blocks the real-time path. Colour-only analysis can miss ambiguous content changes and cannot supply depth or application motion vectors. This is image-based extrapolation, not FSR3 frame generation or depth-aware application spacewarp.

Metal fixtures compile without execution by default. Use `tools/test-game-spacewarp-metal.sh --run` and `tools/test-game-spacewarp-static-metal.sh --run` to explicitly run the bounded headless GPU checks.
