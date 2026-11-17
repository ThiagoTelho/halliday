#!/bin/sh
# Rebuilds app/Resources/AppIcon.icns from app/Resources/AppIcon.icon, the Liquid Glass icon
# document (edit it in Icon Composer). Apple's renderer draws the glass, so this needs Icon
# Composer installed; the .icns is committed, so a normal build does not run this.
#
# The .icns holds only the default look. To have macOS switch between its dark, clear and tinted
# icon styles, the .icon has to be compiled into the app with Xcode's actool instead.
set -eu
cd "$(dirname "$0")/.."
ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$ICTOOL" ] || { echo "Icon Composer not found in /Applications (it provides ictool)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# ictool fills the whole canvas; a macOS .icns keeps the tile at 824 px inside 1024.
"$ICTOOL" "$PWD/app/Resources/AppIcon.icon" --export-image --output-file "$TMP/tile.png" \
    --platform macOS --rendition Default --width 824 --height 824 --scale 1 >/dev/null
[ -s "$TMP/tile.png" ] || { echo "ictool wrote no image" >&2; exit 1; }
sips --padToHeightWidth 1024 1024 "$TMP/tile.png" --out "$TMP/full.png" >/dev/null
SET=$TMP/AppIcon.iconset
mkdir -p "$SET"
for entry in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 \
             256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
    name=${entry%%:*}; px=${entry##*:}
    sips -z "$px" "$px" "$TMP/full.png" --out "$SET/icon_$name.png" >/dev/null
done
iconutil -c icns "$SET" -o app/Resources/AppIcon.icns
echo "wrote app/Resources/AppIcon.icns"
