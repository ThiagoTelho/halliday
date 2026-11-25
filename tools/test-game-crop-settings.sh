#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/build/tests" "$TASK_ROOT/build/swift-module-cache"
xcrun swiftc -swift-version 6 -module-cache-path "$TASK_ROOT/build/swift-module-cache" \
  "$TASK_ROOT/app/Sources/Halliday/Settings.swift" \
  "$TASK_ROOT/app/Sources/Halliday/GameHalfFrameRateMode.swift" \
  "$TASK_ROOT/app/Sources/Halliday/GameImagePlan.swift" \
  "$TASK_ROOT/app/Sources/Halliday/GameViewGeometry.swift" \
  "$TASK_ROOT/app/Sources/Halliday/GameImageSettingsGeometry.swift" \
  "$TASK_ROOT/tools/tests/GameCropSettingsTests.swift" \
  -o "$TASK_ROOT/build/tests/game-crop-settings-tests"
"$TASK_ROOT/build/tests/game-crop-settings-tests"
