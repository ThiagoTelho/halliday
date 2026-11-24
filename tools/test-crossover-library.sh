#!/bin/bash
# Standalone fixtures; all inputs and compiler outputs stay in a temporary directory.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/halliday-crossover-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
"${HALLIDAY_SWIFTC:-$(xcrun --find swiftc)}" -swift-version 6 -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$test_dir/module-cache" \
    "$repo_dir/app/Sources/Halliday/CrossOverLibrary.swift" \
    "$repo_dir/tools/tests/CrossOverLibraryTests.swift" -o "$test_dir/crossover-tests"
"$test_dir/crossover-tests"
"${HALLIDAY_SWIFTC:-$(xcrun --find swiftc)}" -swift-version 6 -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$test_dir/module-cache" \
    "$repo_dir/app/Sources/Halliday/CrossOverLibrary.swift" \
    "$repo_dir/app/Sources/Halliday/OpenVRRegistration.swift" \
    "$repo_dir/app/Sources/Halliday/WineOpenXRRegistration.swift" \
    "$repo_dir/app/Sources/Halliday/NativeAlyxSupport.swift" \
    "$repo_dir/app/Sources/Halliday/GameLibrary.swift" \
    "$repo_dir/tools/tests/GameLibraryTests.swift" -o "$test_dir/game-library-tests"
HALLIDAY_LIBRARY_FIXTURE_ROOT="$test_dir/model-fixture" "$test_dir/game-library-tests" --sample-games
