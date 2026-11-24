# Paired optical controller association

Both controller models previously fitted the complete set of camera blobs
independently. A weak fit of one model could reuse the other controller's
observations and immediately replace its own last position, heading and lean.
The position filter then accepted that alternative location as a new track.
Normal-session logs showed the weak left result converging to within 1.4–5.4 cm
of the well-observed right controller. Those logs aggregate approximately one
second and do not identify individual reused blobs.

The paired solver evaluates fits on clones and assigns each observation by its
exact `(camera view, source spot index)` within one immutable exposure. Common
frames with disjoint observations use the two original fits without additional
refitting. On conflict it evaluates both assignment orders, refits the other
model without observations already owned by the first, and compares joint
support and residual quality. Close ambiguous alternatives are withheld rather
than selecting a fixed preferred hand. Rejected hypotheses cannot modify last
position, heading, lean or the downstream inertial position filter.

A separate continuity check uses exposure timestamps and head pose/position to
compare positions in world space. Normal movement passes immediately; a
discontinuous location needs a consistent subsequent exposure before it becomes
the accepted track. This is not a static left/right world-side constraint: close
hands, crossed hands, head movement and fast legitimate movement are regression
cases. Both hands use the same rules.

The app submits one paired C-ABI snapshot and forwards only returned accepted
fixes. Existing single-hand APIs remain available. Geometry, camera calibration,
IMU orientation, the accepted Sense grip/aim conversion and game pose origins
are unchanged. The serial worker, generation retirement and replaceable pending
exposure remain in place. No LEDs are reprogrammed and no game-specific rules
are added.

The included saved-spot and known-position synthetic regressions cover both
hands, crossings, fast movement, missing observations and recovery. CPU replay
does not establish physical headset acceptance or game performance. The fixtures
contain anonymous scalar observations; no room images or device identity are
required.
