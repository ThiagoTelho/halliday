# System game audio

**Game audio in PS VR2** relays the Mac system mix while a real VR game is
presenting and the headset USB/display are connected. It works independently of
OpenVR/OpenXR, D3D11/D3D12/Vulkan or the game's own audio API. The desktop Sound
card and headset Settings expose the same persistent toggle. Halliday's existing
volume and mute controls apply to relayed audio.

## Ordinary capture path

ScreenCaptureKit captures 48 kHz stereo Float32 and explicitly excludes the
current process's audio, so Halliday's relay and interface sounds are not fed
back into capture. Microphone capture is disabled; no video output is registered.
This captures the system mix, including other applications playing at the time,
rather than isolating a particular game process.

The output engine selects the live DisplayPort **PS VR2** device explicitly and
verifies the selected device. It does not change the Mac's default output,
input/microphone, device gain or the volume of another application. If PS VR2 is
already the default output, capture is bypassed to avoid duplicate playback;
Halliday does not take over the other app's direct audio volume in that case.

Borrowed capture samples are copied into a 2,880-frame stereo buffer (60 ms at
48 kHz). Overflow drops oldest samples, starvation/lock contention emits silence,
nonfinite samples become zero and stale/closed data cannot replay. The render
callback uses a nonblocking lock attempt and performs no allocation. Buffer size
is a capacity bound, not a measured end-to-end latency claim.

Capture/playback stop when disabled, presentation ends, the headset disconnects,
or Halliday shuts down. Device/default-route changes restart only the relay;
a confirmed physical display-mode change also restarts its display-backed stream.
Asynchronous starts use generation cancellation and recheck after awaits, so an
old completion cannot revive a stopped session. All data stays in memory.

## Permission and acceptance

The ordinary path requires macOS **Screen & System Audio Recording** permission.
The UI reports when it is missing; this feature does not edit TCC or grant itself
access. An application with a new local signature may need authorization again.
The usage text describes sending game/system audio to the headset.

Physical audio acceptance is pending for this prepared contribution: grant
permission to the final signed app, play a real game, check stereo sound and
volume/mute, and verify stop/reconnect plus an output-route change. The CPU
fixtures below do not capture or play audio and cannot establish physical sound,
AV sync, dropouts or end-to-end latency.

## Experimental Core Audio backend

The source includes an explicitly opt-in process-tap alternative, selected only
by `HALLIDAY_AUDIO_CAPTURE_BACKEND=coreaudio` in Halliday's process environment.
It requires macOS 14.2+, mandates excluding Halliday's own HAL process object,
and creates a private tap-only aggregate input without changing the default
output. Failure or invalid format falls back to the ordinary ScreenCaptureKit
path, which still requires its permission. It has synthetic HAL-driver/callback
coverage; physical tap acceptance is pending. It is not exposed as a normal UI
choice or the default backend.

## CPU checks

```sh
make system-game-audio-check
```

Swift 6 fixtures exercise real production render callbacks on a background
thread, copied planar/interleaved CMSampleBuffers, strict packed-PCM validation,
bounded FIFO overflow/wrap/stale/starvation/close, capture configuration's own-
process/microphone exclusions, DisplayPort device eligibility and inactive
facade behavior. Injected Core Audio operations cover every startup failure and
cancellation unwind without creating a tap/device. A separate UserDefaults suite
checks audio-toggle persistence without changing volume or other preferences.
