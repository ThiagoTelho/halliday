#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/SenseHaptics.swift" \
    "$repo_dir/tools/tests/SenseHapticsTests.swift" \
    -o "$repo_dir/build/tests/sense-haptics-tests"
"$repo_dir/build/tests/sense-haptics-tests"
