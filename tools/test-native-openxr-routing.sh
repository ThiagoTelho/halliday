#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/build/tests" "$TASK_ROOT/build/swift-module-cache" "$TASK_ROOT/build/validation/native-openxr-routing"
xcrun swiftc -swift-version 6 -module-cache-path "$TASK_ROOT/build/swift-module-cache" \
  "$TASK_ROOT/app/Sources/Halliday/Settings.swift" \
  "$TASK_ROOT/app/Sources/Halliday/CrossOverLibrary.swift" \
  "$TASK_ROOT/app/Sources/Halliday/NativeOpenXRSupport.swift" \
  "$TASK_ROOT/app/Sources/Halliday/NativeAlyxSupport.swift" \
  "$TASK_ROOT/tools/tests/NativeOpenXRSupportTests.swift" \
  -o "$TASK_ROOT/build/tests/native-openxr-routing-tests"
"$TASK_ROOT/build/tests/native-openxr-routing-tests" "$TASK_ROOT/build/validation/native-openxr-routing"
