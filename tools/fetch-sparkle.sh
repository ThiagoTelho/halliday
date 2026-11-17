#!/bin/bash
# Sparkle (https://sparkle-project.org, MIT), the updater the app carries for its opt-in update
# checks: the release's prebuilt framework and tools, pinned to one version and its checksum, into
# reference/sparkle/ (git-ignored). The Makefile runs this when the framework isn't there yet.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
DEST=reference/sparkle
[ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ] && exit 0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "$SHA256  $TMP/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "Sparkle $VERSION: checksum doesn't match"; exit 1; }
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$TMP/sparkle.tar.xz" -C "$DEST"
echo "$VERSION" > "$DEST/.version"
echo "Sparkle $VERSION in $DEST"
