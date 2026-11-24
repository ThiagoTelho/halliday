#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
"${HALLIDAY_SWIFTC:-$(xcrun --find swiftc)}" -swift-version 6 -target arm64-apple-macos14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/Settings.swift" \
    "$repo_dir/tools/tests/SystemGameAudioSettingsTests.swift" \
    -o "$repo_dir/build/tests/system-game-audio-settings-tests"
"$repo_dir/build/tests/system-game-audio-settings-tests"
