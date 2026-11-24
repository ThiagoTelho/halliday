#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache" "$repo_dir/build/validation/amd-optical-flow"
xcrun swiftc -O -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" -framework Metal \
  "$repo_dir/app/Sources/Halliday/GameOpticalFlow.swift" "$repo_dir/tools/tests/GameOpticalFlowMetalTests.swift" \
  -o "$repo_dir/build/tests/game-optical-flow-metal-tests"
"$repo_dir/build/tests/game-optical-flow-metal-tests" "$repo_dir/app/Resources/amd-optical-flow" \
  "$repo_dir/build/validation/amd-optical-flow/gpu-results.json"
