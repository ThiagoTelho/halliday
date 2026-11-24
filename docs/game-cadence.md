# Live game cadence and PS VR2 refresh

`Half frame rate` is off by default. Enabling it changes the game wake budget
from 120 to 60 Hz, or 90 to 45 Hz, while head/controller state and the physical
compositor continue at the display rate. It does not generate frames.

`GameFrameCadence` uses display targets rather than callback counts. Late
callbacks coalesce missed deadlines into one wake. Repeated targets and live
full/half or 90/120 changes cannot replay a wake or build a catch-up queue.
`halliday_bridge_publish_frame` separates state publication from game
notification; the legacy API and mapped v6 header layout are unchanged.
The published frame interval and OpenVR display-frequency property follow the
live game budget. Existing mappings, images and game sessions stay open.

Both Mac Settings and headset Settings offer 90/120 Hz. Only modes advertised by
the connected Sony panel with identical logical and physical geometry are
eligible. Halliday confirms the selected physical mode before changing game
cadence or saving the preference; a failed request leaves the preference intact.
Zero (the default) retains the Mac's current mode. A deliberate choice is restored
once per display connection, without repeated failed requests.

Changing the physical mode retires the old display clock and pending callbacks,
then starts new timing without recreating the renderer. Old queued callbacks
cannot consume targets from the replacement clock.

## Validation

```sh
tools/test-game-frame-cadence.sh
tools/test-psvr2-refresh-modes.sh
tools/test-game-image-settings.sh
cargo test --manifest-path core/Cargo.toml -p halliday-bridge -p halliday-core -j 2
```

The Swift fixtures cover deadline-based cadence, live transitions, duplicate and
missed callbacks, clock resets, exact mode geometry, unsupported modes and
preference preservation. The Rust fixtures check fresh pose/input reads on
non-notifying ticks, wake coalescing and unchanged legacy behavior. These are CPU
checks; they do not change a physical display. Physical live-switch acceptance
and game responsiveness must be checked separately on a PS VR2.
