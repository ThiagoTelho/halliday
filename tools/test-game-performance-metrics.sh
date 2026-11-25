#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
swift_compiler=(xcrun swiftc)
if [[ -n "${HALLIDAY_SWIFTC:-}" ]]; then swift_compiler=("$HALLIDAY_SWIFTC"); fi
"${swift_compiler[@]}" -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/PerformanceHUDSnapshot.swift" \
    "$repo_dir/app/Sources/Halliday/GamePerformanceMetrics.swift" \
    "$repo_dir/tools/tests/GamePerformanceMetricsTests.swift" \
    -o "$repo_dir/build/tests/game-performance-metrics"
"$repo_dir/build/tests/game-performance-metrics"
