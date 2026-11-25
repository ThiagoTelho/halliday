# Automatic OpenVR routing

The x64 broker exports Valve's `VRClientCoreFactory("IVRClientCore_003")` for
ordinary runtime discovery. It does not replace a game's `openvr_api.dll`.

```text
<owned-bottle-profile>/halliday-openxr-router.json
<owned-bottle-profile>/OpenVR/bin/vrclient_x64.dll
<owned-bottle-profile>/OpenVR/bin/win64/vrclient_x64.dll
```

Both layouts read the profile-root JSON. `halliday_openvr_library` names the
real Halliday ClientCore DLL; optional `external_openvr_library` references a
valid x64 provider from the bottle's saved original `openvrpaths.vrpath`.
The provider stays in its original location and retains dependency lookup.
No provider is inferred from a neighboring OpenXR library or game-local proxy.
If Windows user profiles disagree about their original providers, setup does
not guess one common external route; every original registration remains
available to undo. A Halliday-only configuration needs no external OpenVR DLL.

The strict policy and shared process-choice mapping match the OpenXR broker.
Selection is reserved before provider loading and stays fixed until process
exit, including OpenVR-to-OpenComposite-to-OpenXR initialization. A selected
provider failure never loads another backend. If only one API has an external
provider, choosing external for the other API fails explicitly.

Ordinary providers return their original ClientCore unchanged, including error
strings. `external_safe_error_strings: true` is an opt-in compatibility setting
for a provider whose two error-description methods are broken. It forwards the
other five methods and preserves numeric initialization errors, returning bounded
thread-local descriptions with the numeric code for unknown errors. This
compatibility mode is off by default and does not patch provider binaries.

Game-local OpenComposite bypasses OpenVR runtime discovery and may reach the
OpenXR broker downstream. Native macOS OpenVR, 32-bit consumers, ClientCore002,
and interfaces not implemented by the chosen provider are outside this x64
ClientCore003 broker's guarantee.

`build_openvr.py` builds the broker and inert fixtures. `test_openvr.py --run`
uses only a disposable project bottle and tests all seven methods, direct error
string forwarding, optional compatibility mode, both layouts, Halliday-only
startup, rejection, process pinning and cross-API initialization order. The
optional `--actual-oc PATH` negative probe requires absent runtime registrations
before loading a real module; it is not part of portable CI or game validation.

Persistent diagnostics are off by default. Set `HALLIDAY_OPENVR_ROUTER_LOG` only
for an explicit diagnostic launch.
