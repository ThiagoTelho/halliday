#!/bin/bash
# CPU-only public loader/instance dispatch. No graphics device or host session.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
runtime="${1:-$repository/core/target/debug/libhalliday_openxr.dylib}"
[[ -r "$runtime" ]] || { echo "Build halliday-openxr first, or pass a runtime path." >&2; exit 2; }
mkdir -p "$repository/build/tests"
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -I "$repository/windows-openxr/include" \
    "$repository/tools/tests/native-openxr-dispatch.cpp" \
    -o "$repository/build/tests/native-openxr-dispatch-tests"
"$repository/build/tests/native-openxr-dispatch-tests" "$runtime"
