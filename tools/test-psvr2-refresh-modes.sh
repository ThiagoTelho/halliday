#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/PSVR2RefreshModes.swift" \
    "$repo_dir/tools/tests/PSVR2RefreshModesTests.swift" \
    -o "$repo_dir/build/tests/psvr2-refresh-modes-tests"
"$repo_dir/build/tests/psvr2-refresh-modes-tests"
