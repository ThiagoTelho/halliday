#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
  "$repo_dir/app/Sources/Halliday/ProjectionGeometry.swift" \
  "$repo_dir/tools/tests/ProjectionGeometryTests.swift" -o "$repo_dir/build/tests/projection-geometry-tests"
"$repo_dir/build/tests/projection-geometry-tests"
