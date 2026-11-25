# Corroborate reacquisition across skipped heading scans

The optical hand tracker deliberately runs expensive heading scans every other
lost exposure. Paired association keeps the first discontinuous candidate
provisional until a later independent, strong and consistent observation confirms
it. Previously, the intervening exposure without a solution deleted that pending
observation. A hand requiring renewed heading acquisition could therefore repeat
scan / miss / scan indefinitely, even when both scans found its true LED geometry.

Keep provisional evidence across missing or deliberately unscanned exposures,
only until the existing 100 ms confirmation deadline. A duplicate exposure cannot
confirm it. Backward timestamps, ambiguous ownership and geometry resets retire
it. The second candidate still needs eight sightings, RMS below 2 px and the same
existing position/heading consistency checks. No provisional heading, tilt,
position, blob ownership or inertial-filter state is published.

An actual optical-solver regression uses known LED projections and a renewed yaw
offset. The unchanged heading scanner finds true candidates on exposures 220,
222, 224 and so on. Before the repair paired association accepts none; afterward
it confirms on exposure 222, 33.3 ms after the first candidate. Additional real
LED scenes test both hands through a missing exposure. Boundary tests retain the
strict 100 ms limit and reject stale, divergent, weak and duplicate evidence.
The original right-only false-left reproducer remains rejected, and the verified
recorded normal / left-only / restored sequence retains exactly the previous
60/60, 300/0 and 48/48 coverage.

This fixes a deterministic reacquisition defect. Existing accepted-only physical
logs cannot prove which missing-observation stage caused a particular loss. It
does not establish that every reported left-hand visibility problem is resolved.
Controller angles, optical geometry, exposure-clock policy and frame generation
are unchanged.
