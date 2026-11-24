# Desktop game host, launch and routing

This contribution connects the independent Windows/native runtimes to the app.
The original OpenVR path, Sense poses, FSR/RCAS and live cadence controls remain
available. Spacewarp and system-audio capture are separate contributions.

## Shared presentation

The host consumes complete tagged publications: image sequence, source head pose,
each eye's camera/FOV, rectangle, orientation and transfer interpretation, plus
ordered quads. Torn or required missing metadata keeps the previous complete
image. Quads are composed after game-image processing; a quad-only carrier does
not run through the game upscaler. Legacy untagged OpenVR retains its sampling.

The app skips environment baking while an immersive projection/video hides the
place. It does not alter the environment cache's clock or game pixel density.
Mappings and picture slots are leased through GPU copy completion. Producer
restart/watchdog handling retires stale state without letting late callbacks
release a replacement. The generic reserved-mailbox haptic feed targets both
connected Sense controllers and cancels on focus loss/close.

## Ordinary launches

CrossOver discovery reads installed applications, bottles, external Steam
libraries and manual imports. Launches retain the selected bottle/backend and
literal paths/arguments. Steam launches use `--no-convert` with the generic
`steam://launch/APPID/vr` URI, so VR selection does not depend on a game allowlist.
No graphics-provider DLL is replaced.

OpenVR and Windows OpenXR registrations keep reversible original receipts.
Automatic routing selects a validated provider once per process. The app's
500 ms policy publication favors a worn, ready Halliday headset. Fresh
`connected:true` telemetry marks an optional provider active and affects its
priority; installed-file presence alone does not establish a connection. The
saved original remains a fallback when Halliday or its policy is unavailable,
even without telemetry. A user may restore that original runtime explicitly. Existing processes keep their chosen runtime.

Native VeRantyx uses the source-built native runtime and helpers from
[PR05](native-runtime.md), with bounded Steam readiness, executable/start-time
identity checks and a private managed launcher. Original scripts/settings/saves
are preserved. Only the verified VeRantyx0.3.2 ABI gets the optional coherent
reader; other versions retain their reader.

## Input and packaging

Real controller menu interaction does not automatically capture the desktop
mouse or move game focus to the headset's display. Explicit desktop-mouse
fallback remains available. Dashboard settings are placed beside the game bar;
the host menu laser/cursor disappear while the game owns input.

`make vr-modules` builds public optional game modules. `make vr-package` adds
them to an ordinary app; `make crossover-preview` explicitly requests a separate
development identity. Ordinary `make app` preserves its version, identity and
updater and needs no installed game or closed runtime. Packaging refuses stale
private runtime payloads rather than silently carrying them.

CPU fixtures cover discovery/commands, reversible registration, provider
availability, process identity, native launch preparation, router JSON/policy,
pointer ownership, projection math and packaging. GPU compositor fixtures are
available separately and require explicit execution. Source/typecheck success
does not establish physical headset acceptance, every-game compatibility or
comparative game FPS/latency.
