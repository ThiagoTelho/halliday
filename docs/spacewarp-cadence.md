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

`ProjectionLayer.imageTime` remains the host's real-image receipt time, not an
engine simulation timestamp. A separate optional `imageTiming` carries the
producer epoch, exact image index, signed nanoseconds and clock kind through the
same publication as the pixels. OpenXR uses the submitted `xrEndFrame.displayTime`
(intended presentation, not simulation time); a negotiated OpenVR producer uses
its paired Submit monotonic clock. These kinds and producer epochs never mix.

When metadata is present, positive same-clock image-time differences scale flow
displacement. Delayed/bunched imports no longer speed up or slow down that motion.
A game producing 43 FPS under a 60 FPS budget retains its 23.256 ms source interval;
an 8.333 ms prediction advances 0.35833 of that motion, not a guessed 0.5. Adjacent
successful publication indices are not assumed to be adjacent simulation steps.
Receipt gaps only guard prolonged stalls. Advertised invalid/stale metadata keeps
the real image but disables prediction until a valid pair is primed. Unadvertised
legacy clients remain compatible with the previous approximate receipt-time
fallback; the host does not manufacture a missing content timestamp.

Forecast age still starts at the image's first compositor target, without
comparing absolute clocks across processes. Repeated forecasts never become
new source sequences or feed back into motion analysis.

The existing renderer can synthesize the retained phase from its unchanged real
pair. Source pose/FOV stay associated with that real pair, and ordinary latest-head
reprojection still runs on every display frame. Explicit toggles,
session/sequence resets, cadence changes and clock discontinuities discard the
retained phase before history is primed again.

`tools/test-game-spacewarp-cadence.sh` covers both display rates, monotonic cached
marker trajectories, missing/late sources, long stalls, partial-phase retention,
arrival/target jitter, fresh-source recovery, reconnect/toggle/rate changes and
invalid clocks. These are CPU scheduler regressions, not measured game FPS or
optical latency. The implementation is original Halliday scheduling code; no GPL
FrameGen source was copied.

`tools/test-game-spacewarp-source-time.sh` adds analytical 90/120 Hz trajectories
for regular/delayed/bunched delivery, actual 43 FPS under a 60 FPS budget, skipped
source times, clock/epoch/index/availability changes, corrupted cached metadata
and long receipt stalls. It measures CPU scheduling correctness, not game FPS or
end-to-end motion latency. Shared-protocol and producer readback fixtures verify
that the timestamp follows the selected old asynchronous image rather than a
newer Submit/EndFrame call.
