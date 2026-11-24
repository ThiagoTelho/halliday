#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache" "$repo_dir/build/validation/spacewarp"
xcrun swiftc -O -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" -framework Metal \
  "$repo_dir/app/Sources/Halliday/ProjectionGeometry.swift" "$repo_dir/app/Sources/Halliday/GameSpacewarp.swift" "$repo_dir/app/Sources/Halliday/GameOpticalFlow.swift" \
  "$repo_dir/tools/tests/GameSpacewarpMetalTests.swift" \
  -o "$repo_dir/build/tests/game-spacewarp-metal-tests"
"$repo_dir/build/tests/game-spacewarp-metal-tests" "$repo_dir/app/Resources/spacewarp" \
  "$repo_dir/build/validation/spacewarp/gpu-results.json"
