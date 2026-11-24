#!/bin/bash
# CPU-only copied-slot transaction test. No runtime, driver, game or headset.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repository/build/tests"
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror \
    "$repository/tools/tests/NativeCoherentFrameReaderTests.cpp" \
    -o "$repository/build/tests/native-coherent-frame-reader-tests"
"$repository/build/tests/native-coherent-frame-reader-tests"
