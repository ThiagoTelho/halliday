#!/bin/sh
# CPU-only actual adapter contract: no runtime loader, graphics device or game.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/build/tests"
${CXX:-c++} -std=c++17 -O2 -I "$TASK_ROOT" -I "$TASK_ROOT/windows-openxr/include" \
  "$TASK_ROOT/tools/tests/NativeTouchRawFrameTests.cpp" \
  -o "$TASK_ROOT/build/tests/native-touch-raw-frame-tests"
"$TASK_ROOT/build/tests/native-touch-raw-frame-tests"
HALLIDAY_ALYX_TOUCH_RAW_POSE=1 "$TASK_ROOT/build/tests/native-touch-raw-frame-tests" --verify-launch raw
HALLIDAY_ALYX_TOUCH_RAW_POSE=0 "$TASK_ROOT/build/tests/native-touch-raw-frame-tests" --verify-launch legacy
