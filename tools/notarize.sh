#!/bin/bash
# make notarize: has Apple notarize the signed app (make release), staples its ticket to it so it
# opens offline too, makes the DMG from it (tools/make-dmg.sh), and notarizes and staples that.
#
# It needs a notarytool keychain profile, which the person releasing stores once, themselves
# (their Apple ID's app-specific password never goes anywhere else):
#     xcrun notarytool store-credentials halliday-notary --apple-id <their Apple ID> --team-id <their team>
# NOTARY_PROFILE names another profile.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-halliday-notary}
APP=build/release/Halliday.app
[ -d "$APP" ] || { echo "no signed app: make release first"; exit 1; }

submit() {
    echo "notarizing $1 (a few minutes)…"
    out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
    echo "$out" | tail -4
    if ! echo "$out" | grep -q "status: Accepted"; then
        id=$(echo "$out" | awk '/^  id:/ {print $2; exit}')
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE"
        echo "not accepted: see Apple's log above"; exit 1
    fi
}

ZIP=build/release/Halliday-notarize.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
submit "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"

tools/make-dmg.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="build/release/Halliday-$version.dmg"
submit "$DMG"
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "ready to publish: $DMG"
