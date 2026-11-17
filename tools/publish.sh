#!/bin/bash
# make publish NOTES=FILE: the GitHub release v<version>, with the notarized DMG and Sparkle's
# feed (make release notarize appcast). Once it is the latest release, every copy of Halliday with
# update checks on finds it. NOTES is a Markdown file with the release's notes.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES=${1:?usage: tools/publish.sh NOTES.md}
APP=build/release/Halliday.app
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="build/release/Halliday-$version.dmg"
FEED=build/release/appcast.xml
[ -f "$DMG" ] && [ -f "$FEED" ] || { echo "make release notarize appcast first"; exit 1; }
grep -q "Halliday-$version.dmg" "$FEED" || { echo "$FEED isn't for $version: make appcast again"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit first: the release is tagged at what is pushed"; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}' 2>/dev/null)" ] || { echo "push first: the tag must be on GitHub's commit"; exit 1; }

feed=$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' app/Info.plist)
repo=${feed#https://github.com/}
repo=${repo%/releases/latest/download/appcast.xml}
gh release create "v$version" "$DMG" "$FEED" --repo "$repo" --target "$(git rev-parse HEAD)" \
    --title "Halliday $version" --notes-file "$NOTES"
