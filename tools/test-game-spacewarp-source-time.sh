#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache" "$repo_dir/build/validation/spacewarp"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos14.0" -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/GameSpacewarpCadence.swift" \
    "$repo_dir/tools/tests/GameSpacewarpSourceTimeTests.swift" \
    -o "$repo_dir/build/tests/game-spacewarp-source-time-tests"
"$repo_dir/build/tests/game-spacewarp-source-time-tests" "$repo_dir/build/validation/spacewarp/source-time-cadence.json"
