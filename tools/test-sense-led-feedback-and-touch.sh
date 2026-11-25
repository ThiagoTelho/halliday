#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos14.0" -module-cache-path "$repo_dir/build/ModuleCache" \
  "$repo_dir/app/Sources/Halliday/SenseOutputPolicy.swift" \
  "$repo_dir/app/Sources/Halliday/SenseLEDSynchronizer.swift" \
  "$repo_dir/app/Sources/Halliday/GameControllerTouch.swift" \
  "$repo_dir/tools/tests/SenseLEDFeedbackAndTouchTests.swift" -o "$repo_dir/build/tests/sense-led-feedback-and-touch-tests"
"$repo_dir/build/tests/sense-led-feedback-and-touch-tests"
