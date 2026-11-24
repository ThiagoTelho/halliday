# Experimental colour-only Spacewarp

**Game image → Spacewarp 2×** is a live switch on the Mac and in the headset.
It is off by default. Enabling it selects Half frame rate, targeting a 60 game-frame/s budget
at 120 Hz or 45 at 90 Hz, with a bounded forecast on intervening refreshes.
Actual game FPS can be lower.
Disabling Spacewarp retains the chosen half-rate cadence; that switch can then
be disabled separately. FSR 1 and RCAS remain independent live controls.

The shared compositor path is:

`real stereo image → optical-flow forecast → optional EASU/RCAS → latest-head reprojection → lens correction`

This path accepts the native and CrossOver OpenVR/OpenXR producers supported by
the preceding runtime/host changes. Only opaque full-frame game projections with
valid half-rate metadata are eligible. Quads, transparent/partial projections,
interface panels, WebXR and videos retain ordinary sampling. No game shader,
depth buffer, motion-vector integration or graphics-API-specific mod is needed.

## Implementation

- The separately attributed **AMD Optical Flow 1.1.2, FidelityFX SDK v1.1.4**
  estimates motion for each eye. Its original MIT shaders are translated through
  SPIR-V to Metal 3.2. The feature requires macOS 15; preparation failure keeps
  real images and ordinary head reprojection without blocking the display actor.
- Two real images retain their exact source pose, FOV, eye geometry, UV direction
  and colour interpretation. Previous colour is camera-aligned using the existing
  compositor's constant-depth model; optical flow estimates residual image motion.
- The independent MIT synthesis pass forecasts at most half a real-frame interval.
  No future frame is queued, no extra head prediction is added, and generated
  images never enter real-image history. Latest-head reprojection still runs for
  every physical refresh. There is no CPU readback/wait in production encoding.
- Source-identical eyes retain exact current pixels before camera compensation
  can manufacture false motion in a head-locked menu. Scene cuts and unsupported
  regions conservatively retain current colour. Histories reset on source/geometry,
  cadence, clock, pose, session and effect-state discontinuities.
- Once a bounded forecast has been displayed, a missed source retains that exact
  phase instead of reverting to older real pixels. It never starts or advances a
  first forecast from stale motion. See [cadence rationale](spacewarp-cadence.md).

This is image-only prediction, **not AMD FSR Frame Generation or application
spacewarp with depth/motion vectors**. It does not increase game simulation FPS.
Thin geometry, transparency, disocclusion and depth ordering can ghost or break.
Physical retesting is pending: synthetic regressions below do not establish
comfortable gameplay or resolve every previous headset report of judder/artifacts.

## Validation

CPU: `tools/test-game-spacewarp-cadence.sh`,
`tools/test-game-spacewarp-settings.sh` and the offline shader hash/notice check
`tools/test-amd-optical-flow-provenance.py` (`make spacewarp-check`).

Opt-in GPU: `tools/test-game-optical-flow-metal.sh`,
`tools/test-game-spacewarp-metal.sh`, and
`tools/test-game-spacewarp-static-metal.sh`. The bounded compositor fixture is
`tools/test-game-spacewarp-preview.py --app <built-app> --output <new-build/validation-folder>`.
These fixtures use generated images and do not start games, a headset or AppDelegate.

The saved [GPU pixel comparison](validation/spacewarp-static-pixels.json) records
unchanged stereo colour with ±0.05° camera jitter at 2016×2048 per eye: maximum
pixels differing by more than one 8-bit level fell from **155,277 to 0**, and
maximum RGB error from **206 to 0**. Ordinary unchanged flat/textured/menu inputs
also remained bit exact. The [CPU replay](validation/spacewarp-cadence.json)
records one backward marker step before the cadence guard and none after, at
both 45→90 and 60→120 Hz. These are correctness comparisons; no game-performance,
optical-latency or headset comfort improvement is claimed from them.

AMD's pinned revision, source/output hashes and reproduction script are in
[Optical Flow provenance](../app/Resources/amd-optical-flow/SOURCE.md).
The [composition contract](../app/Resources/spacewarp/README.md) documents queue
ordering, per-eye isolation and image-only limitations. The original AMD MIT
notice ships with the shaders and in the application's collected licences.
