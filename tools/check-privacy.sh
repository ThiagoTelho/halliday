#!/bin/sh
# Privacy check (run by `make lint`): Halliday makes no network connection of its own. Every place
# in the code that can reach the network is listed below, with what it is for; anything else that
# appears fails the check, so a new connection can't arrive without being looked at (and, if it is
# right, added here and to PRIVACY.md).
#
# Allowed, each one started by the user (file, then text the line must contain):
#   BrowserWindow.swift  URLRequest(url:      WKWebView loads the page the user opened.
#   MusicPanel.swift     URLSession(configuration: .ephemeral)   the cover art Spotify gives for the
#                        song playing, from Spotify; no cookies or cache kept.
#   QuestAppWeb.swift    (the whole file) a Quest app's own web interface, open in a tab: its
#                        requests to its own servers, sent for it (the page's origin here isn't the
#                        one they allow), and the content it downloads into its own folder. Only
#                        while that app is open.
#   QuestAppFiles.swift  (the whole file) that app's downloads into its own folder: asked for by
#                        its page (Capacitor's Filesystem.downloadFile) or by an extension the user
#                        installed for it (halliday.files.download, ExtensionHost.swift), the latter
#                        only to the hosts the extension's manifest lists, which the user saw before
#                        installing it. Only while that app is open.
#   ExtensionFromGitHub.swift  (the whole file) an extension the user asked for by pasting its
#                        GitHub link: that repository's archive, fetched once from github.com
#                        (codeload.github.com, nothing else), no cookies, at most 25 MB.
#   Updates.swift        (the whole file) Sparkle, the updater, only once the user turned on update
#                        checks (setup or the companion; off until then) or asked for one: the
#                        latest release's appcast.xml from github.com, then, with the user's yes,
#                        that release's DMG. Nothing about the user or the Mac is sent
#                        (SUEnableSystemProfiling off). Sparkle may be used nowhere else.
# (VideoPlayer's "Watch in VR" plays a page's video from that site through AVFoundation's AVURLAsset,
# with no network code of Halliday's own.)
set -eu
cd "$(dirname "$0")/.."

allowed() {
    case "$1" in
        app/Sources/Halliday/BrowserWindow.swift:*'URLRequest(url:'*) return 0 ;;
        app/Sources/Halliday/MusicPanel.swift:*'URLSession(configuration: .ephemeral)'*) return 0 ;;
        # (every line of it: its requests, their tasks, and the app's own downloads)
        app/Sources/Halliday/QuestAppWeb.swift:*) return 0 ;;
        # (every line of it: the session those requests share, and the downloads)
        app/Sources/Halliday/QuestAppFiles.swift:*) return 0 ;;
        # (every line of it: one session, one download, its redirects kept to GitHub)
        app/Sources/Halliday/ExtensionFromGitHub.swift:*) return 0 ;;
        # (every line of it: the updater, opt-in)
        app/Sources/Halliday/Updates.swift:*) return 0 ;;
    esac
    return 1
}

status=0
# Network APIs in the Swift app and the Rust core (comment lines are skipped).
hits=$(grep -rnE 'import Sparkle|SPU[A-Za-z]*Updater|URLSession|NWConnection|NWListener|NWBrowser|CFStream|CFSocket|URLRequest[(]|import Network|reqwest|hyper::|TcpStream|UdpSocket|std::net' \
    app/Sources core/*/src) || [ $? -eq 1 ] || { echo "privacy check: grep failed" >&2; exit 2; }
# The scripts Halliday puts into web pages talk only to Halliday, never to the network.
js=$(grep -nE 'fetch[(]|XMLHttpRequest|WebSocket|sendBeacon|EventSource|new Image[(]' app/Resources/*.js) \
    || [ $? -eq 1 ] || { echo "privacy check: grep failed" >&2; exit 2; }

echo "$hits" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    code=$(printf '%s' "$line" | cut -d: -f3- | sed 's/^[[:space:]]*//')
    case "$code" in //*|\**) continue ;; esac
    if ! allowed "$line"; then
        echo "privacy check: network code outside the reviewed list: $line" >&2
        echo fail
    fi
done | grep -q fail && status=1
if [ -n "$js" ]; then
    echo "privacy check: a page script reaches the network: $js" >&2
    status=1
fi
if [ $status -ne 0 ]; then
    echo "See tools/check-privacy.sh and PRIVACY.md." >&2
    exit 1
fi
echo "privacy check: no network code outside the reviewed list"
