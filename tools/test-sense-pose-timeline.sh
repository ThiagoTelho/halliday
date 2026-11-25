#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
swift_compiler=(xcrun swiftc)
if [[ -n "${HALLIDAY_SWIFTC:-}" ]]; then swift_compiler=("$HALLIDAY_SWIFTC"); fi
"${swift_compiler[@]}" -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/SensePoseTimeline.swift" \
    "$repo_dir/tools/tests/SensePoseTimelineTests.swift" -o "$repo_dir/build/tests/sense-pose-timeline"
"$repo_dir/build/tests/sense-pose-timeline" "$repo_dir/tools/tests/fixtures/hand-tracking-worker.json"
"${swift_compiler[@]}" -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    -I "$repo_dir/app/Sources/CHallidayCore" -L "${HALLIDAY_CORE_LIBRARY_DIR:-$repo_dir/core/target/release}" -lhalliday_core \
    -framework Foundation -framework IOKit -framework CoreFoundation -framework Security \
    "$repo_dir/app/Sources/Halliday/CameraTrackingProfiles.swift" \
    "$repo_dir/app/Sources/Halliday/HandTrackingWorker.swift" \
    "$repo_dir/tools/tests/HandExposureStagingTests.swift" -o "$repo_dir/build/tests/hand-exposure-staging"
"$repo_dir/build/tests/hand-exposure-staging" "$repo_dir/tools/tests/fixtures/hand-tracking-worker.json"
xcrun clang -std=c11 -I "$repo_dir/core/halliday-core/include" \
    -c "$repo_dir/tools/tests/SenseStateABI.c" -o "$repo_dir/build/tests/sense-state-abi.o"
python3 "$repo_dir/tools/tests/test_exposure_orientation_wiring.py"
echo "PASS: Sense101 C ABI offsets/size/alignment and additive timed snapshot signature"
