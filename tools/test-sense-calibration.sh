#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache"
python3 - "$repo_dir" <<'PY'
from pathlib import Path
import re,sys
root=Path(sys.argv[1]);source=(root/'core/halliday-core/src/sense.rs').read_text()
capture=source.split('const RIGHT_CAL: [&str; 2] = [',1)[1].split('];',1)[0]
parts=re.findall(r'"([0-9a-f ]+)"',capture)
assert len(parts)==2
for index,text in enumerate(parts):
    (root/f'build/tests/sense-calibration-{index}.bin').write_bytes(bytes.fromhex(text))
PY
xcrun swiftc -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" \
    -I "$repo_dir/app/Sources/CHallidayCore" -L "${HALLIDAY_CORE_LIBRARY_DIR:-$repo_dir/core/target/release}" -lhalliday_core \
    -framework IOKit -framework CoreFoundation -framework Security -lc++ \
    "$repo_dir/app/Sources/Halliday/SenseCalibration.swift" \
    "$repo_dir/tools/tests/SenseCalibrationTests.swift" \
    -o "$repo_dir/build/tests/sense-calibration-tests"
"$repo_dir/build/tests/sense-calibration-tests" \
    "$repo_dir/build/tests/sense-calibration-0.bin" "$repo_dir/build/tests/sense-calibration-1.bin"
