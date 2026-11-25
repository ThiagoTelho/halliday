#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/GameBridgeLease.swift" \
    "$repo_dir/tools/tests/GameBridgeLeaseTests.swift" \
    -o "$repo_dir/build/tests/game-bridge-lease-tests"
"$repo_dir/build/tests/game-bridge-lease-tests"
