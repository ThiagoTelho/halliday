#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/tests/system-audio-module-cache"
"${HALLIDAY_SWIFTC:-$(xcrun --find swiftc)}" -swift-version 6 -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$repo_dir/build/tests/system-audio-module-cache" \
    -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreMedia \
    -framework ScreenCaptureKit -framework CoreGraphics \
    "$repo_dir/app/Sources/Halliday/SystemAudioBuffer.swift" \
    "$repo_dir/app/Sources/Halliday/SystemGameAudio.swift" \
    "$repo_dir/tools/tests/SystemGameAudioTests.swift" \
    -o "$repo_dir/build/tests/system-game-audio-tests"
"$repo_dir/build/tests/system-game-audio-tests"
