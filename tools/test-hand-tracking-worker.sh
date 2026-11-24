#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    -I "$repo_dir/app/Sources/CHallidayCore" -L "${HALLIDAY_CORE_LIBRARY_DIR:-$repo_dir/core/target/release}" -lhalliday_core \
    -framework Foundation -framework IOKit -framework CoreFoundation -framework Security \
    "$repo_dir/app/Sources/Halliday/CameraTrackingProfiles.swift" \
    "$repo_dir/app/Sources/Halliday/HandTrackingWorker.swift" \
    "$repo_dir/tools/tests/HandTrackingWorkerTests.swift" \
    -o "$repo_dir/build/tests/hand-tracking-worker-tests"
"$repo_dir/build/tests/hand-tracking-worker-tests" "$repo_dir/tools/tests/fixtures/hand-tracking-worker.json" "$@"
