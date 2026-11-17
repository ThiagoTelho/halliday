#!/bin/bash
# make dmg: build/release/Halliday-<version>.dmg from the signed build/release/Halliday.app (make
# release), signed with the same Developer ID. Notarize it with `make notarize`, which also runs this.
#
# The window is board 21 ("Night, all space"): the picture from tools/dmg-background.swift (1× and
# 2× in one TIFF), Halliday at (180, 180) and Applications at (460, 180) in a 640 × 400 window with
# no toolbar, the disk wearing Halliday's icon. Finder writes that layout itself: a read-write
# image is mounted, Finder is told through AppleScript how to show it (macOS asks once to let the
# terminal control Finder), and the image is then made read-only and compressed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/release/Halliday.app
[ -d "$APP" ] || { echo "no signed app: make release first"; exit 1; }
ID=${RELEASE_ID:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="build/release/Halliday-$version.dmg"
WORK=build/release/dmg-work
VOLUME=Halliday
MOUNT="/Volumes/$VOLUME"
[ -e "$MOUNT" ] && { echo "a disk named $VOLUME is already mounted: eject it first"; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/stage/.background"
# The picture.
swiftc -O tools/dmg-background.swift -o "$WORK/background"
"$WORK/background" "$WORK/bg.png" 1
"$WORK/background" "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/stage/.background/background.tiff" 2>/dev/null
# The contents.
ditto "$APP" "$WORK/stage/Halliday.app"
ln -s /Applications "$WORK/stage/Applications"

# A read-write image to lay out.
hdiutil create -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -mountpoint "$MOUNT" >/dev/null
detach() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true; }
trap detach EXIT
# The disk wears Halliday's icon (made from the folder, the image leaves this file out).
cp app/Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a V "$MOUNT/.VolumeIcon.icns"

# Finder lays out the window (the window's bounds include its 28-point title bar).
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set label position of opts to bottom
        set shows item info of opts to false
        set background picture of opts to file ".background:background.tiff"
        set position of item "Halliday.app" of container window to {180, 180}
        set position of item "Applications" of container window to {460, 180}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
# Finder writes .DS_Store when it likes: wait until it has.
for _ in $(seq 1 20); do [ -f "$MOUNT/.DS_Store" ] && break; sleep 0.5; done
[ -f "$MOUNT/.DS_Store" ] || { echo "Finder didn't write the window's layout"; exit 1; }
# Set after Finder has saved its layout, which clears it.
SetFile -a C "$MOUNT"
GetFileInfo -a "$MOUNT" | grep -q C || { echo "the disk's icon flag didn't stick"; exit 1; }
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
chmod -Rf go-w "$MOUNT" || true
sync
detach
trap - EXIT

# Read-only and compressed, then signed.
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format ULFO -o "$DMG" >/dev/null
rm -rf "$WORK"
codesign --force --timestamp --sign "$ID" "$DMG"
echo "made: $DMG"
