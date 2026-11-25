# Recover real controller observations without weakening identity checks

Two separate restrictions kept a real recorded left controller from reacquiring
in some image regions. Continuing optical tracking accepted 16-observation fits
at 1.42–1.44 px RMS, but heading acquisition required less than 1.2 px. Before
that quality test, the stereo seed builder's 1.5 px row gate discarded all or
almost all seven correct LED pairs in those same images. Only 2–10 seed points
remained, so increasing the 24-point limit would not repair these cases.

Keep the existing 1.5 px / 24-point seed fast path and the weak eight-sighting /
1.2 px scan policy. The paired tracker also accepts a high-observability stereo
hypothesis only when all of these hold:

- At least the existing twelve-observation large-heading support count.
- At least six observations in each bottom camera, eight distinct model LEDs,
  and distinct actual `(view, source spot)` observations.
- RMS below the unchanged 2 px continuing-fit limit.
- A second strong, geometrically consistent exposure within the existing 100 ms
  deadline before acquisition or a large correction is committed.

Existing recent-position and bounded two-heading single-camera searches provide
proposals when strict stereo rows cannot seed the fit. A single-camera proposal
must still pass the strong two-camera test. Standalone legacy `HandTracker`
callers retain their previous acceptance policy. No new angle, camera alignment,
optical model, blob cap, vote-point cap or unbounded search was introduced.

A provisional hypothesis remains separate from committed heading, tilt, position
and inertial state. Its world point is transformed into the next camera snapshot
for a new fit, rather than being published or treated as a measurement. It expires
at 100 ms; ambiguous ownership, backward time and geometry changes retire it.
Rust confirmation also requires different frame counters. The existing C ABI
identifies exposures by their supplied exposure timestamp; the production Swift
collector deduplicates the actual camera counters before calling it. No separate
clock lookup or invented physical counter is used.

A missing peer orientation needs an identity guard too. Without it, a weak fit
could consume the other controller's LEDs while that controller could not propose
a competing identity. Require the existing eight-sighting acquisition support in
this unilateral case, during search as well as admission/scoring. A rejected
trial cannot silently commit its mutated heading/last position/tilt. Normal weak
continuation remains available when both orientations are known.

The worker carries the coherent head tracking generation with each snapshot.
Only a change between known nonzero generations retires hypotheses and queued
callbacks. Unknown legacy zero does not erase the last known token or reset state
on every frame. The display actor also rejects old tagged outputs against its
cached current head generation. This leaves the last displayed hand in place
until a new validated fix arrives.

Validation uses existing anonymous stereo/IMU observations and actual solvers:
all three high-residual fields recover after forced loss plus a known yaw offset,
and also acquire cold without a previous pose. The missing-peer wrong-hand case
changes from 17 weak false fits to zero; actual left coverage with missing peer
orientation stays 60 / 300 / 48. Normal recorded coverage, dark-right isolation,
ordinary both-orientation weak continuation, crossings, fast movement, head
movement, static clutter and the previous shared-right-LED reproducer remain
protected. CPU replay timings describe one bounded solver pass, not game FPS or
physical latency. No new image recording or hardware session is needed for these
checks; physical acceptance of the integrated build remains separate.
