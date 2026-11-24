# Verified helper application identity

A mod may render through `OpenXRHelper32.exe` or `OpenXRHelper64.exe`. The runtime
continues to publish that process's PID, ownership epoch and frame timing. For
these two exact helper basenames only, `client.name` may instead name the
helper's verified live Windows parent, so the host can resolve the real game
window when resuming. Ordinary executables keep their existing name. No v6 ABI
field or ownership/lifetime rule changes.

The Win32 adapter finds the current helper in Toolhelp, opens its recorded
parent, queries the complete executable image and checks creation/session
identity. The parent must predate the helper, remain live, and still be the
recorded parent at the end of the query. Equal/coarse creation times are
ambiguous and are rejected. Steam, helper processes, launchers, shell/system
parents, invalid data and names that cannot fit the complete 63-byte field are
rejected. Missing or unverifiable information retains the helper name. This
never substitutes a globally guessed macOS parent or changes the helper PID.
The host still rejects ambiguous/non-game window matches.

Lookup happens once during existing initialization/name publication, with all
snapshot/process handles scoped to the query. It adds no per-frame lookup.

## Validation

`helper_game_identity_policy_test` is a portable CMake/CTest target. It covers
ordinary names, both exact helpers, generic game names, denied parents, missing
identity, PID/creation/session mismatch, reused/equal creation times and dead
parents. `helper_game_identity_windows_test` compiles without executing by
default; explicit owned-path arguments can launch one bounded CPU test child.
Its graphics/runtime creation paths are absent.

The saved [receipt](tests/helper_game_identity_receipt.json) records six real
owned Win32 process chains and one bounded actual D3DMetal control integration.
The latter renames the tiny D3D11 probe to `OpenXRHelper64.exe`, launches it from
an owned test game parent, and checks application name together with unchanged
helper PID/lease and the existing exact prior pixels/source timestamps. It uses
an explicit copied DLL, private bridge and disposable prefix; no game, headset,
TCC capture, installed application or runtime registry registration is involved.
These are correctness checks; real UI focus/Resume acceptance is separate.
