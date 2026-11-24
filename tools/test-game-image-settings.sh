#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/Settings.swift" \
    "$repo_dir/app/Sources/Halliday/GameImagePlan.swift" \
    "$repo_dir/tools/tests/GameImageSettingsTests.swift" \
    -o "$repo_dir/build/tests/game-image-settings-tests"
"$repo_dir/build/tests/game-image-settings-tests"
