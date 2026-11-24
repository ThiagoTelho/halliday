#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/build/tests" "$TASK_ROOT/build/swift-module-cache"
xcrun swiftc -swift-version 6 -module-cache-path "$TASK_ROOT/build/swift-module-cache" \
  "$TASK_ROOT/app/Sources/Halliday/CrossOverLibrary.swift" \
  "$TASK_ROOT/app/Sources/Halliday/NativeAlyxSupport.swift" \
  "$TASK_ROOT/tools/tests/NativeAlyxSupportTests.swift" \
  -o "$TASK_ROOT/build/tests/native-alyx-launcher-tests"
"$TASK_ROOT/build/tests/native-alyx-launcher-tests"
