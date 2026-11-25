#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    "$repo_dir/app/Sources/Halliday/SenseAimDefaults.swift" \
    "$repo_dir/tools/tests/SenseAimDefaultsTests.swift" \
    -o "$repo_dir/build/tests/sense-aim-defaults-tests"
"$repo_dir/build/tests/sense-aim-defaults-tests"
python3 - "$repo_dir" <<'PY'
from pathlib import Path
import re
import sys
source = (Path(sys.argv[1]) / 'app/Sources/Halliday/AppDelegate.swift').read_text()
update = source.split('private func updateSense(head:', 1)[1].split('\n    private func ', 1)[0]
# The live button path must never invoke the deliberately saved tilt calibration.
calls = re.findall(r'calibrateSense\([^\n]+', update)
assert len(calls) == 1 and 'tilt: false)' in calls[0], calls
assert 'SenseAimDefaults.tapAction(' in update
assert 'if pressed.contains(.ps) { recenterHold(began: true) }' in update
assert 'if released.contains(.ps) { recenterHold(began: false) }' in update
assert 'menu: state.buttons.contains(.menu)' in update
print('PASS: actual button handler retains connection heading seed, PS hold recenter and game menu passthrough; no tap tilt calibration call remains')
PY
