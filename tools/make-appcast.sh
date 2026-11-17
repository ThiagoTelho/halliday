#!/bin/bash
# make appcast: build/release/appcast.xml, Sparkle's update feed, for the notarized
# build/release/Halliday-<version>.dmg (make release notarize). Sparkle's generate_appcast signs
# the DMG with the EdDSA key the person releasing made once with
# reference/sparkle/bin/generate_keys, which keeps it in their login keychain (it never leaves
# it); the app checks that signature with Info.plist's SUPublicEDKey, and Halliday's Developer ID
# signature as well.
#
# The feed goes up with the DMG as files of the GitHub release (make publish): the app reads
# releases/latest/download/appcast.xml, so the newest release's feed is the one every copy sees.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/release/Halliday.app
[ -d "$APP" ] || { echo "no signed app: make release notarize first"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="build/release/Halliday-$version.dmg"
[ -f "$DMG" ] || { echo "no $DMG: make notarize first"; exit 1; }
xcrun stapler validate "$DMG" >/dev/null || { echo "$DMG isn't notarized: make notarize first"; exit 1; }
grep -q PUBLIC_KEY_PENDING app/Info.plist && { echo "Info.plist has no SUPublicEDKey yet (reference/sparkle/bin/generate_keys)"; exit 1; }

# The repository, from the feed's address in Info.plist.
feed=$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' app/Info.plist)
repo=${feed%/releases/latest/download/appcast.xml}

WORK=build/release/appcast-work
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$DMG" "$WORK/"
reference/sparkle/bin/generate_appcast "$WORK" \
    --download-url-prefix "$repo/releases/download/v$version/" \
    --link "$repo/releases/tag/v$version" \
    -o build/release/appcast.xml
rm -rf "$WORK"
grep -q 'sparkle:edSignature' build/release/appcast.xml || { echo "the feed came out unsigned"; exit 1; }
echo "made: build/release/appcast.xml (Halliday $version); next: make publish NOTES=FILE"
