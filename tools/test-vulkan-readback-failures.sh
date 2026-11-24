#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
destination="$repo_dir/build/validation/openxr-readback-failures"
mkdir -p "$destination"
vulkan_include="${VULKAN_SDK:+$VULKAN_SDK/include}"
xcrun clang++ -std=c++17 -O2 -I "${vulkan_include:-/opt/homebrew/include}" \
    "$repo_dir/tools/tests/VulkanReadbackFailureTests.cpp" -o "$destination/check"
"$destination/check"
