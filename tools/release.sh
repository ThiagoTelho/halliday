#!/bin/bash
# make release: build/Halliday.app signed for distribution into build/release/Halliday.app.
# Every Mach-O in the bundle gets this Mac's "Developer ID Application" identity, the hardened
# runtime and a secure timestamp, innermost first; the app gets app/Halliday.entitlements. The
# Quest runner gets no entitlements (one team's Developer ID passes library validation). Nothing
# here names a person: the identity is found in the keychain (RELEASE_ID to choose another).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=build/Halliday.app
OUT=build/release
ID=${RELEASE_ID:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}
[ -n "$ID" ] || { echo "no \"Developer ID Application\" identity in the keychain"; exit 1; }
[ -x "$SRC/Contents/Resources/quest/klepton-runner" ] && [ -x "$SRC/Contents/Resources/quest/unzl" ] \
    || { echo "the Quest runtime isn't in the app: make klepton unzl, then make release"; exit 1; }
tools/check-bundled-libs.sh "$SRC"
for f in Halliday.txt THIRD-PARTY.md libusb-COPYING.txt SDL3-LICENSE.txt MoltenVK-LICENSE.txt Zstandard-LICENSE.txt; do
    [ -f "$SRC/Contents/Resources/Licenses/$f" ] || { echo "the bundle's licences are missing $f (tools/collect-licenses.sh, run by make)"; exit 1; }
done

mkdir -p "$OUT"
rm -rf build/release/Halliday.app
ditto "$SRC" "$OUT/Halliday.app"
APP="$OUT/Halliday.app"
sign() { codesign --force --options runtime --timestamp --sign "$ID" "$@"; }

for lib in "$APP"/Contents/Resources/quest/*.dylib; do sign "$lib"; done
sign "$APP/Contents/Resources/quest/klepton-runner"
sign "$APP/Contents/Resources/quest/unzl"
sign --entitlements app/Halliday.entitlements "$APP"

codesign --verify --strict --deep --verbose=2 "$APP"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
echo "signed: $APP ($version); next: make dmg, make notarize"
