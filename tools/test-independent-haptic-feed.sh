#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests build/ModuleCache
xcrun clang++ -std=c++17 -mmacosx-version-min=14.0 -I windows-openxr/src -c tools/tests/independent-haptic-fixture.cpp -o build/tests/independent-haptic-fixture.o
xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache \
    -I app/Sources/CHallidayCore -L core/target/release -lhalliday_core \
    -framework IOKit -framework CoreFoundation -framework Security -lc++ \
    app/Sources/Halliday/GameHapticFeed.swift tools/tests/IndependentHapticFeedTests.swift \
    build/tests/independent-haptic-fixture.o -o build/tests/independent-haptic-feed-tests
build/tests/independent-haptic-feed-tests
