#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/GameHalfFrameRateMode.swift" \
    "$repo_dir/app/Sources/Halliday/GameAutoFrameRate.swift" \
    "$repo_dir/app/Sources/Halliday/GameFrameCadence.swift" \
    "$repo_dir/tools/tests/GameAutoFrameRateTests.swift" \
    -o "$repo_dir/build/tests/game-auto-frame-rate-tests"
"$repo_dir/build/tests/game-auto-frame-rate-tests"
python3 "$repo_dir/tools/tests/test-game-auto-frame-rate-wiring.py"
