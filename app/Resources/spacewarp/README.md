# Colour-only Spacewarp composition

`composition.metal` is independent MIT composition code. Motion estimation is
the separately attributed AMD FidelityFX Optical Flow implementation in
`../amd-optical-flow`; no OFXR/GPL composition code is included.

The wrapper copies two **real** SBS frames into canonical unflipped,
display-encoded RGBA8. It aligns the previous real frame into the current real
camera using the same head rotation, head translation and assumed radial depth
as Halliday's compositor. AMD therefore estimates residual image/object motion,
instead of counting head motion twice. Left and right eyes retain separate
geometry, motion fields and GPU scene-cut flags.

The same alignment pass also compares the original canonical real images,
before camera compensation, using per-eye flags and 16x16-pixel change maps. An unchanged eye retains its
exact current pixels even when the tracked camera moves. This prevents
head-locked menus from acquiring false motion solely from compensation. A small
animated indicator no longer enables motion across the rest of an unchanged
eye: each candidate needs change at the target or its current source location.
Changes only at an older correspondence cannot launch stationary colours into
unrelated regions. A moving silhouette can still forecast beyond its current
edge. All masks stay on the GPU; no CPU readback or wait is added.

On a repeated source frame, forward vectors indexed in current-image blocks
extrapolate colour by `alpha × previous→current displacement`, with alpha at
most 0.5. The current real render pose/FOV remains the output pose/FOV; ordinary
latest-head reprojection follows synthesis. Synthetic images never feed back
into history, and no future frame is required.

Supported motion candidates require local flow agreement, photometric support,
valid head-aligned history and per-eye bounds. Scene cuts display current
colour, and invalid/unseen regions use conservative current/nearby stationary
colour. There is **no per-pixel depth**: occlusion ordering, thin geometry,
transparency and newly revealed content remain limitations of colour-only
extrapolation. This is experimental, not an equivalent of depth/motion-vector
application spacewarp.

All production work is GPU-only in the supplied command buffer. Callers must
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
