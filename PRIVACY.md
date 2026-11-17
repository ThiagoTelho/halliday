# Privacy

**Halliday doesn't track you. What happens on your Mac stays on your Mac.**

A VR headset sees more of you than any other device: where you look, how you move, the room
around you, how tall you are, how your hands shake. Many VR platforms send that to their makers.
Halliday is built the other way around. It has no servers, no accounts and no analytics. It never
sends anything about you anywhere. The only connections it makes are the ones you start, to
services you chose, and what you share with them is between you and them.

This page says exactly what that means, and how the code keeps it true.

## What Halliday never does

- No analytics, telemetry, usage statistics or "anonymous" counters.
- No crash reports of its own (macOS's own crash reporting is yours to set in System Settings).
- No accounts, no sign-in, no ads, no update checks, no servers of any kind.
- Nothing from the headset leaves your Mac. Head tracking is computed on the Mac, used for the
  frame being drawn and dropped. Halliday doesn't read the headset's eye tracking. It reads the
  headset's cameras for two things, both on your Mac only: to find the controllers (of each
  picture only the bright points of their lights are kept, for that moment), and for passthrough,
  when you switch it on (the newest picture is held in memory to draw the room in the headset,
  replaced sixty times a second and dropped when you switch it off). No camera picture is ever
  written to disk or sent anywhere.

## What stays on your Mac

Everything Halliday keeps is a plain file in your user folder. Nothing is synced or uploaded.

| What | Where |
|---|---|
| Settings, window places, layouts, video resume points, Home favourites, how you hold each Sense controller (its tilt), the height you set for yourself in games; for Games, your yes to setting games up, which games are VR games, the containers Halliday set up, and each game's last launch (when, how long, or why it stopped) | `~/Library/Preferences/app.halliday.Halliday.plist` |
| Browser history and bookmarks | `~/Library/Application Support/Halliday/browser.json` |
| Notes | `~/Library/Application Support/Halliday/Notes/` |
| Your 360° environment images | `~/Library/Application Support/Halliday/Environments/` |
| Where moved Mac windows came from (so they go back after a crash) | `~/Library/Application Support/Halliday/moved-windows.json` |
| Halliday's OpenVR runtime for Windows VR games (`vrclient_x64.dll`), and while Halliday runs the memory it shares with a game (the head and controller poses it sends, the frames, overlay pictures and loading skybox the game sends back; removed when Halliday quits) | `~/Library/Application Support/Halliday/OpenVR/` |
| What the runtime logs inside a game (the interfaces and settings the game asks for) | `~/Library/Application Support/Halliday/OpenVR/vrclient.log` |
| Quest apps you install from your own APK files: the file, its unpacked contents, what the app itself saves and downloads, any settings of its own (`settings.json`), what its catalogue handed its player at the last launch (the scene's description, with the id of the account signed in there), and what it printed the last time it ran | `~/Library/Application Support/Halliday/Quest/<package>/` |
| Extensions you install, and which of them are switched off | `~/Library/Application Support/Halliday/Extensions/<id>/`, and Halliday's preferences |
| Halliday's volume (videos, Quest apps, its own sounds) | `~/Library/Application Support/Halliday/Quest/volume`, and Halliday's preferences |
| Pointing a game's Wine prefix at that runtime, only when you ask (in Games, or `halliday --install-openvr`): one file, and a copy of the one it replaces, which Undo puts back. Games reads GameHub's list of games and its Steam library folder to find your VR games; it changes nothing of GameHub's | `drive_c/users/*/AppData/Local/openvr/openvrpaths.vrpath` in that prefix |
| MKV files repacked for playing | `~/Library/Caches/Halliday/Repacked/` |
| Cookies and data of the sites you visit (as in any browser) | WebKit's store for Halliday, under `~/Library/WebKit/` and `~/Library/Caches/` |
| A log of what Halliday did, for fixing problems (app names and window titles, the hosts of VR pages, notices, which programs used the GPU) | `~/Library/Logs/Halliday.log`, and the run before as `Halliday.previous.log` |
| Headset recordings, only if you make one with `halliday-probe -r` | where you choose |

**Private tabs** keep nothing: no history, and their cookies and site data are gone once the last
private tab closes.

To remove everything Halliday has kept, quit it and delete those files.

## What the macOS permissions are for

- **Screen Recording**: to show your Mac windows in VR. Halliday captures only its own hidden
  display, where the windows you bring into VR are moved, and, while a VR game runs, the window
  its runtime shows the game's frames in, on a second hidden display of Halliday's. The pictures stay in the graphics
  memory and never leave the Mac. They are written to disk only if you ask for a snapshot with
  one of the developer flags (`--keys-snapshot` and the like), to the file you name.
- **Accessibility**: to move those windows onto that display, resize them, and pass your clicks
  and typing to them.
- **Automation** (asked once per app): only if you open Music in Halliday, to show and control
  what Music or Spotify is playing.
- **Files and folders**: only the folders you open in Files, Videos or Photos.

## When you talk to someone else

Some things you do in Halliday reach other services. Halliday doesn't add anything about you to
them. What those services do with what they receive is set by them, as it would be from any app
on your Mac.

- **Websites you open** in the browser see what any browser shows them. By default Halliday's
  browser introduces itself as Safari on an Apple Vision Pro, so VR sites offer their VR mode; you
  can switch it to a Mac in the browser's settings.
- **Searching**: words typed in the address bar go to DuckDuckGo as a search.
- **VR web pages** (WebXR) receive your head's position and rotation, your pointer and the
  headset's field of view while you are in their VR mode. They need these to draw the scene. The
  page alone receives them, as in any browser with WebXR.
- **Watch in VR** plays a page's video in Halliday's player, fetched from that site with that
  site's own cookies, as the page itself would.
- **Music** gets the song's cover art from the address Spotify gives for it, with no cookies and
  no cache.
- **A Quest app with a web interface of its own** (its catalogue and sign-in, a web application
  inside the app's package) is shown in a browser tab, served from the copy you installed. The
  requests that interface makes to the app's own servers are sent by Halliday for it, with the
  cookies those servers set, as an Android headset's web view would send them: what you type there
  (a sign-in) goes to that app's servers and nowhere else. Halliday tells the app a device model
  ("Quest 3"), an id made up for that one app and how much room your disk has (apps measure a
  download against it); it keeps none of what passes. Content you download in such an app is
  fetched by Halliday from the addresses the app gives, into that app's folder. This happens
  only while you have such an app open.
- **Extensions** you install (docs/extensions.md) are code from their authors, not Halliday's.
  One runs sealed off from your Mac: it answers its app's own calls, and the only connection it
  can ask Halliday to make is a download into that app's folder, from the hosts its manifest
  lists, which Halliday shows you before installing it. Halliday has no extension store and
  never updates an extension by itself.
- **An extension from GitHub**: when you paste an extension's GitHub link in the companion (or
  give one to `halliday --install-extension`), Halliday fetches that repository's archive from
  GitHub once, without cookies. GitHub sees that request, as it would from your browser. Nothing
  else is sent, and nothing is installed before you have seen what the extension is.
- **WebKit**, the engine of Halliday's browser and of Safari, may check addresses against lists of
  fraudulent sites through Apple. That is part of macOS, not of Halliday.
- **ffmpeg**, if you install it for MKV files, runs on your Mac and doesn't go online.

## How this is kept true

- Halliday is open source: everything above can be read in the code.
- `tools/check-privacy.sh` runs with `make lint`, before every commit. It knows every place in the
  code that can reach the network (today: the browser loading the pages you open, the cover art
  above, a Quest app's own web interface reaching its own servers, the downloads of that app and
its extensions, and an extension fetched from the GitHub link you gave) and fails if any other appears. It also fails if a script Halliday puts into web pages
  could contact the network. A new connection can only arrive by being added to that list, and
  to this page, in plain view.

If you find something here that isn't true of the code, please open an issue: it is a bug.
