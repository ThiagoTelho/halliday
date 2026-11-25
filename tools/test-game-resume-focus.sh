#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build/tests" "$root/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$root/build/ModuleCache" \
  "$root/app/Sources/Halliday/NativeProcessIdentity.swift" \
  "$root/app/Sources/Halliday/GameResumeFocus.swift" \
  "$root/tools/tests/GameResumeFocusTests.swift" -o "$root/build/tests/game-resume-focus-tests"
"$root/build/tests/game-resume-focus-tests"
