#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" -framework Metal \
    "$repo_dir/app/Sources/Halliday/FrameColour.swift" \
    "$repo_dir/app/Sources/Halliday/OpenXRComposition.swift" \
    "$repo_dir/app/Sources/Halliday/Shaders.swift" \
    "$repo_dir/tools/tests/FrameColourMetalTests.swift" \
    -o "$repo_dir/build/tests/frame-colour-metal-tests"
"$repo_dir/build/tests/frame-colour-metal-tests"
