# Automatic Windows OpenXR routing

This x64 runtime forwards the Khronos loader's negotiation to one existing
runtime, without wrapping handles, sessions, graphics or input. Explicit bottle
setup allows ordinary Steam, CrossOver and non-Steam launches to use Halliday or
the bottle's previously registered runtime. No external runtime is required,
bundled, copied or patched.

## Configuration

Register `halliday_openxr_router.json` as the bottle's ActiveRuntime. Its DLL
reads the adjacent, host-generated `halliday-openxr-router.json`:

```json
{
  "version": 1,
  "halliday_manifest": "Z:\\Users\\example\\Halliday\\WindowsOpenXR\\halliday_openxr.json",
  "policy_file": "Z:\\Users\\example\\Halliday\\runtime-policy.json",
  "external_manifest": "C:\\ExistingVR\\runtime.json"
}
```

`external_manifest` is optional. Bottle setup preserves the original manifest
and its library/dependency location; it does not search another application's
installation directory. Only a valid AMD64 Windows DLL becomes a configured
route. Validation establishes an installed provider, **not** a connected headset.
If no external provider is configured, the router always selects Halliday,
including when no policy file exists.

All router paths are absolute Windows paths. A relative `runtime.library_path`
inside a selected manifest resolves against that manifest, never the game's
working directory. Manifest negotiation-export remapping is preserved.
`halliday_openvr_library` and optional `external_openvr_library` configure the
separate [OpenVR broker](OPENVR.md); the OpenXR DLL does not load an OpenVR module.

The host atomically publishes the following policy approximately every 500 ms:

```json
{
  "version": 1,
  "updated_unix_ms": 1790000000000,
  "halliday_ready": true,
  "psvr2_worn": true,
  "external_active": false
}
```

With an external provider configured, a fresh policy selects Halliday when it
is ready and either PSVR2 is worn or no external connection is confirmed. A
confirmed external connection wins while PSVR2 is unworn. An unavailable
Halliday, missing policy, or invalid/stale policy retains the original provider.
Policies expire after 3000 ms and permit at most 500 ms future clock skew.

External connection telemetry is optional. `ExternalVRActivity` accepts only a
fresh, bounded, regular local JSON file containing Boolean `connected: true`;
file existence, installed modules, process names, poses and FPS do not establish
connection. An external provider may opt in through an explicitly configured
local `external_activity_file`; no provider-specific path is inferred from its
manifest. No streamer is needed for Halliday-only use. Providers may opt in using the macOS preference
`gamesExternalVRStatusFile` before bottle setup; its value is an absolute local
status-file path. Providers without telemetry retain explicit **Original
runtime** selection. The per-bottle `external_activity_file` stores this host
probe path and is ignored by the Windows broker.

Supplying both old and new aliases is rejected, rather than silently choosing one.

## Lifetime and failure behavior

Selection is reserved once per process, shared between the OpenXR and OpenVR
brokers. The router and chosen provider remain pinned until process exit.
Changing settings or headsets requires a new game process; an existing session
cannot silently switch runtime. Only the selected provider is loaded. A missing
selected route, bad DLL/export, failed negotiation or `xrCreateInstance` does
not try the other provider. Recursive router targets are rejected.

Configuration and manifest reads are bounded to 16 KiB, policy to 4 KiB. JSON
nesting, types, duplicate keys, clock boundaries and path forms are checked.
Registration and undo use durable receipts; concurrent external registration
changes are preserved. **Original runtime** restores the saved registration.

No persistent log is produced by default. Set `HALLIDAY_OPENXR_ROUTER_LOG` to an
absolute diagnostic file path only when explicitly investigating a launch.

## Build and tests

Requires a MinGW C++17 compiler, checked-in Khronos headers and MIT-licensed
`nlohmann/json` headers. `LICENSE-nlohmann-json` accompanies the broker.

```sh
python3 windows-openxr/router/build.py --cxx /path/to/x86_64-w64-mingw32-clang++ --json-include /path/to/include
python3 windows-openxr/router/build_openvr.py --cxx /path/to/x86_64-w64-mingw32-clang++ --json-include /path/to/include
cmake -S windows-openxr/router -B build/router-native
cmake --build build/router-native
ctest --test-dir build/router-native --output-on-failure
```

Compiler/header paths may also come from `HALLIDAY_MINGW_CXX` and
`HALLIDAY_JSON_INCLUDE`, or standard installed locations. No sibling project or
private toolchain path is used.

The portable parser/policy suite uses no Wine, headset or GPU. Optional Windows
fixture runners use inert fake DLLs and an existing project-owned disposable
bottle, never game DLLs, user bottles or registrations. They cover exact API
forwarding, optional external routes, malformed input, failure without fallback,
cross-API selection, policy changes and module reload. These fixtures do not
claim real game/headset validation.
