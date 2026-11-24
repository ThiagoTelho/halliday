#!/bin/bash
set -euo pipefail
policy_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$policy_root/build/tests" "$policy_root/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$policy_root/build/ModuleCache" \
    "$policy_root/app/Sources/Halliday/ControllerPointerPolicy.swift" \
    "$policy_root/tools/tests/ControllerPointerPolicyTests.swift" \
    -o "$policy_root/build/tests/controller-pointer-policy-tests"
"$policy_root/build/tests/controller-pointer-policy-tests"

python3 "$policy_root/tools/tests/test_controller_pointer_wiring.py"
