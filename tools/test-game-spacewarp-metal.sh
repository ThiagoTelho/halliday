#!/bin/bash
set -euo pipefail
case "${1:-}" in
  ""|--build-only) run_gpu=0 ;;
  --run) run_gpu=1 ;;
  *) echo "Usage: $0 [--build-only|--run]" >&2; exit 2 ;;
esac
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache" "$repo_dir/build/validation/spacewarp"
xcrun swiftc -O -swift-version 6 -target "$(uname -m)-apple-macos14.0" -module-cache-path "$repo_dir/build/ModuleCache" -framework Metal \
  "$repo_dir/app/Sources/Halliday/ProjectionGeometry.swift" "$repo_dir/app/Sources/Halliday/GameSpacewarp.swift" "$repo_dir/app/Sources/Halliday/GameOpticalFlow.swift" \
  "$repo_dir/tools/tests/GameSpacewarpMetalTests.swift" \
  -o "$repo_dir/build/tests/game-spacewarp-metal-tests"
if [[ "$run_gpu" != 1 ]]; then
  echo 'Compiled only; add --run for the explicit bounded offscreen GPU fixture.'
  exit 0
fi
"$repo_dir/build/tests/game-spacewarp-metal-tests" "$repo_dir/app/Resources/spacewarp" \
  "$repo_dir/build/validation/spacewarp/gpu-results.json"
