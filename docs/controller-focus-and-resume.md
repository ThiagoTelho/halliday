# Controller input and explicit game focus

A controller ray can operate an in-headset panel without becoming a macOS mouse. While a game is presenting, including its paused dashboard, Halliday no longer posts controller mouse events, activates a desktop window, parks the cursor, or recaptures it. Headset output cannot become the key/main window. The ordinary desktop preview keeps its explicit mouse-capture path.

Synthetic desktop actions have an ownership generation. A mode change cancels delayed clicks and queued raises. Cleanup emits one release for each button whose synthetic down was actually posted; a cancelled down has no matching release. Local VR panels continue to receive their normal press/release events.

Explicit Resume may activate the actual game once. The selected native process must have a usable game window and retain its executable path and process start time under the same producer lease. A Windows process ID is never used as a macOS PID. Duplicate same-name games, launchers, unbound helpers, expired producers, recycled PIDs, and a changed desktop foreground app make the request a no-op. The remembered target cannot switch to another same-name process during one lease. Discovery runs off the compositor thread with a bounded owned `ps` child.

For the exact Windows OpenXR helper executables, the runtime may publish its verified live parent game basename in the existing name field. Its PID, lease, epoch and timing continue to belong to the helper. Missing/reused/ambiguous parent identity keeps the helper name and makes Resume fail closed. This uses no new bridge ABI. Native OpenXR already defaults to the current executable basename; its explicit `HALLIDAY_APP_NAME` alias remains supported and no native runtime change is needed.

On a dashboard transition, each hand publishes neutral controls. Controls held at Resume remain neutral until that particular button, trigger, grip or stick is physically released. Other controls rearm independently; poses and ordinary focused input are unchanged. This also covers PS/keyboard Resume between two input publications.

## CPU validation

```sh
tools/test-controller-pointer-policy.sh
tools/test-game-resume-focus.sh
tools/test-game-controller-input-rearm.sh
```

The policy fixture covers game/dashboard ownership in eight contexts, queued action cancellation and balanced releases. Resume mocks cover identity, ambiguity, helper rejection, stale async requests, process reuse and sticky targets. Input fixtures cover both hands, analog/digital release, repeated focus and normal input preservation. A source-wiring guard checks the real callsites without posting OS events. Full Swift 6 application typechecking verifies integration. These are CPU/mock/source checks; physical headset focus, cursor visibility and game control acceptance remain a separate manual check.
