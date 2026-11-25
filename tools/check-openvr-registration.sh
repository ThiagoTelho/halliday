#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/build/tests" "$TASK_ROOT/build/swift-module-cache"
xcrun swiftc -swift-version 6 -module-cache-path "$TASK_ROOT/build/swift-module-cache" \
  "$TASK_ROOT/app/Sources/Halliday/OpenVRRegistration.swift" \
  "$TASK_ROOT/tools/openvr-registration-tests.swift" \
  -o "$TASK_ROOT/build/tests/openvr-registration-tests"
"$TASK_ROOT/build/tests/openvr-registration-tests"
