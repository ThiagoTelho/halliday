#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/GameProducerWatchdog.swift" \
    "$repo_dir/tools/tests/GameProducerWatchdogTests.swift" \
    -o "$repo_dir/build/tests/game-producer-watchdog-tests"
"$repo_dir/build/tests/game-producer-watchdog-tests"
