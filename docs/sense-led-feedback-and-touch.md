# Sense LED synchronization and capacitive contacts

The controller's optical LEDs must keep the programmed timing while classic
haptic output is sent. Output is serialized per connection; the Bluetooth
transport counter and LED settings latch have independent sequences. Start,
refresh, cancellation and stop packets retain the current LED latch. A retired
connection cannot write through the replacement connection's state.

`SenseLEDSynchronizer` uses bounded device-clock history, a known output timestamp
echo and two distinct post-echo optical exposures. It retains the existing camera
period, pulse duration and calibrated exposure-centre offset. Missing or occluded
hands are not treated as evidence of bad synchronization. Stale clock data stops
new timing commands; reconnect and explicit mode changes reset the helper.
The `senseLEDFeedback` preference defaults to true; the fixed synchronization path is
retained as an explicit fallback.

Actual Sense contact bits are forwarded independently of pressed buttons and
analog proximity through the existing touched-bit bridge. No skeletal hand
stream is synthesized. Existing native and Windows action bindings consume the
same contacts.

This contribution retains classic haptics and LED-latch preservation. It does
not include Bluetooth PCM playback, adaptive triggers, headset rumble, eye
tracking or eye calibration.

## Validation

- `tools/test-sense-led-feedback-and-touch.sh`: clock rollover, known-output
  echo, independent optical confirmation, stale/reconnect guards, real contact
  mapping and classic-output request retirement.
- `tools/test-sense-led-programming.sh`: actual Rust C ABI, an independent CRC
  and device-latch oracle, both-hand transport/latch wrap, reconnect and invalid
  input handling; no HID writes.
- `tools/test-sense-haptics.sh`: retained classic scheduler regression tests.

Hardware feedback does not establish a quantified tracking improvement or
physical haptic quality. The user's tests confirmed finger-contact animation
and improved controller operation; intermittent left-hand loss remains a limit.

Wire-protocol facts are referenced to Monado revision
`27a1999f6d7fb4972570d63a06e437c93a61e49f`, BSL-1.0. Existing attribution and
licence text are retained in `THIRD-PARTY.md`. No Sony SDK or driver code is used.
