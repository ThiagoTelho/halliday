#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache" "$repo_dir/build/validation/fsr1"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" -framework Metal \
    "$repo_dir/app/Sources/Halliday/GameUpscaler.swift" \
    "$repo_dir/tools/tests/GameUpscalerMetalTests.swift" \
    -o "$repo_dir/build/tests/game-upscaler-metal-tests"
"$repo_dir/build/tests/game-upscaler-metal-tests" "$repo_dir/app/Resources/fsr1" \
    "$repo_dir/build/validation/fsr1/gpu-results.json"
