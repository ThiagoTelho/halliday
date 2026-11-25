#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/tests/wine-openxr-module-cache"
"${HALLIDAY_SWIFTC:-$(xcrun --find swiftc)}" -swift-version 6 -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$repo_dir/build/tests/wine-openxr-module-cache" \
    "$repo_dir/app/Sources/Halliday/CrossOverLibrary.swift" \
    "$repo_dir/app/Sources/Halliday/OpenVRRegistration.swift" \
    "$repo_dir/app/Sources/Halliday/WineOpenXRRegistration.swift" \
    "$repo_dir/tools/tests/WineOpenXRRegistrationTests.swift" \
    -o "$repo_dir/build/tests/wine-openxr-registration-tests"
"$repo_dir/build/tests/wine-openxr-registration-tests"
