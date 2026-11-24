# Native Steam readiness

Halliday's prepared VeRantyx launcher waits for the real Mac Steam client
before starting the VR bridge, game or shader prewarm. Finding `steam_osx`, or
finishing `NSWorkspace.openApplication`, does not establish a ready Steamworks
user during a cold start.

`halliday-steam-ready` loads the same user-installed `steamclient.dylib` in an
isolated probe child. It calls the exported `Steam_CreateSteamPipe` and
`Steam_ConnectToGlobalUser`, then releases only that probe's user and pipe.
The optional `Steam_BLoggedOn` result is diagnostic: a local user in offline
mode is accepted. The helper neither creates a Steam user nor starts Steam,
changes ownership, or replaces the game's normal Steam API initialization.

The overall wait is bounded to 45 seconds, each probe to 2 seconds, with a
250 ms retry interval. SIGINT/SIGTERM and the disappearance of the initiating
Halliday process reap the probe. The owner check includes its process birth
time, so a recycled PID cannot resume the launch. Unsupported exports fail
immediately. Only state changes are logged, without account identifiers.

The game-specific child environment uses Alyx's `SteamAppId` and `SteamGameId`
546560. These variables and the gate apply only to Halliday's generated
VeRantyx script. The user's launcher, game files, mods and Steam library are
unchanged. Inversa uses its existing launch path.

Build the universal helper with:

```sh
python3 native-alyx/build.py --steam-ready-only
```

Preview packages it as `Contents/Resources/NativeAlyx/halliday-steam-ready`.
The full `native-alyx/build.py` also builds it alongside the existing helpers.

`tools/test-steam-readiness.py` tests both architectures against inert fake
dylibs, including offline readiness, delayed initialization, failed/missing
APIs, timeouts, cancellation and owner loss. It never loads the real Steam
library or launches a game.

The gate establishes local Steam IPC/global-user readiness. It does not
pretend to verify game ownership or every Steam Networking interface. The
game still requests its own interfaces normally; a warm-launch acceptance
with bounded raw logging is needed to confirm the reported fatal is resolved.
