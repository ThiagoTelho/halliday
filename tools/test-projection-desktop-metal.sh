#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build/tests" "$repo_dir/build/ModuleCache" "$repo_dir/build/validation/openxr-projection-audit"
# Compile the real host uniform declaration rather than maintaining a duplicate.
python3 - "$repo_dir" <<'PY'
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
text=(root/'app/Sources/Halliday/Renderer.swift').read_text()
uniforms=re.search(r'^struct SceneUniforms \{.*?^\}',text,re.M|re.S).group(0)
(root/'build/tests/ProjectionDesktopUniforms.swift').write_text('import simd\n'+uniforms+'\n')
PY
xcrun swiftc -O -swift-version 6 -module-cache-path "$repo_dir/build/ModuleCache" -framework Metal \
  "$repo_dir/app/Sources/Halliday/FrameColour.swift" \
  "$repo_dir/app/Sources/Halliday/OpenXRComposition.swift" \
  "$repo_dir/app/Sources/Halliday/GameViewGeometry.swift" \
  "$repo_dir/app/Sources/Halliday/Shaders.swift" \
  "$repo_dir/build/tests/ProjectionDesktopUniforms.swift" \
  "$repo_dir/tools/tests/ProjectionDesktopMetalTests.swift" \
  -o "$repo_dir/build/tests/projection-desktop-metal-tests"
"$repo_dir/build/tests/projection-desktop-metal-tests" \
  "$repo_dir/build/validation/openxr-projection-audit/desktop-metal.json"
