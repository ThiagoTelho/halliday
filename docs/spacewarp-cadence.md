# Spacewarp cadence: retain the bounded forecast on a missed frame

Previously, a repeated real image could produce a half-step forecast and then
revert to its original pixels once its age exceeded 1.5 source intervals. This
moved animation backwards while waiting for a late real frame. A CPU replay of
the original scheduler produced marker positions `25, 25, 20, 20, 20, 20, 20`
at 45→90 Hz, and `25, 25, 25, 20, 20, 20, 20` at 60→120 Hz. The corrected
scheduler produces `25, 25, 25, 25, 25, 25, 25` at both rates for the same
repeated source.

The scheduler now remembers the last requested forecast phase for each real
sequence. Once motion becomes stale, it retains exactly that phase. It does not
advance stale motion, start a first forecast after a stall, or exceed half of the
measured real-frame interval. Small target-clock jitter cannot decrease the
phase. A new real frame is still displayed immediately. Long source gaps reset
motion history; there is no future-frame wait, catch-up queue or added look-ahead.

`ProjectionLayer.imageTime` is the host's real-image arrival/creation time, not
an engine simulation timestamp. It is used to validate real-frame pairing;
forecast age starts at the image's first compositor target. Repeated forecasts
never become new source sequences or feed back into motion analysis.

The existing renderer can synthesize the retained phase from its unchanged real
pair. Source pose/FOV stay associated with that real pair, and ordinary latest-head
reprojection still runs on every display frame. This change needs no renderer,
projection, controller-pose or GPU-composition modification. Explicit toggles,
session/sequence resets, cadence changes and clock discontinuities discard the
retained phase before history is primed again.

`tools/test-game-spacewarp-cadence.sh` covers both display rates, monotonic cached
marker trajectories, missing/late sources, long stalls, partial-phase retention,
arrival/target jitter, fresh-source recovery, reconnect/toggle/rate changes and
invalid clocks. These are CPU scheduler regressions, not measured game FPS or
optical latency. The implementation is original Halliday scheduling code; no GPL
FrameGen source was copied.
