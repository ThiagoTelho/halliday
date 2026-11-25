#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_CC=${HALLIDAY_MINGW_CC:-x86_64-w64-mingw32-clang}
mkdir -p "$TASK_ROOT/build"
"$TASK_CC" -std=c11 -O2 -Wall -Wextra -Werror -static \
  "$TASK_ROOT/tools/windows-openxr-registry.c" -ladvapi32 \
  -o "$TASK_ROOT/build/halliday-xr-registry.exe"
