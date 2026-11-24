#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo_dir/build/tests/independent-compositor"
test_target="$(uname -m)-apple-macos14.0"
mkdir -p "$out" "$repo_dir/build/ModuleCache"
compile_and_run() {
    local name="$1"; shift
    xcrun swiftc -swift-version 6 -target "$test_target" \
        -module-cache-path "$repo_dir/build/ModuleCache" "$@" -o "$out/$name"
    "$out/$name"
}
sources="$repo_dir/app/Sources/Halliday"
tests="$repo_dir/tools/tests"
compile_and_run mailbox "$sources/CompositorSceneMailbox.swift" "$tests/CompositorSceneMailboxTests.swift"
compile_and_run refresh-driver "$sources/CompositorSceneMailbox.swift" "$sources/CompositorRefreshDriver.swift" "$tests/CompositorRefreshDriverTests.swift"
compile_and_run presentation-timing "$sources/CompositorPresentationTelemetry.swift" "$tests/CompositorPresentationTelemetryTests.swift"
compile_and_run late-target "$sources/LateDisplayTimeline.swift" "$tests/LateDisplayTimelineTests.swift"
compile_and_run clock-retirement "$sources/CompositorSceneMailbox.swift" "$sources/LateDisplayTimeline.swift" "$tests/ClockRetirementTests.swift"
