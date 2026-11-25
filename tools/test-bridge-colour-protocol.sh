#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun clang++ -std=c++17 -O2 -I "$repo_dir/windows-openxr/src" -c \
    "$repo_dir/tools/tests/bridge-colour-fixture.cpp" -o "$repo_dir/build/tests/bridge-colour-fixture.o"
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    -I "$repo_dir/app/Sources/CHallidayCore" -L "${HALLIDAY_CORE_LIBRARY_DIR:-$repo_dir/core/target/release}" -lhalliday_core -lc++ \
    -framework Foundation -framework IOKit -framework CoreFoundation -framework Security \
    "$repo_dir/tools/tests/BridgeColourProtocolTests.swift" "$repo_dir/build/tests/bridge-colour-fixture.o" \
    -o "$repo_dir/build/tests/bridge-colour-protocol-tests"
"$repo_dir/build/tests/bridge-colour-protocol-tests"
