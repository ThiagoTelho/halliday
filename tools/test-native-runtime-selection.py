#!/usr/bin/env python3
"""CPU-only native bridge selection: explicit local path, never an installed fallback."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / 'build/validation/native-runtime-selection'
out.mkdir(parents=True, exist_ok=True)
source = out / 'probe.cpp'
source.write_text('''#include "runtime_selection.hpp"
#include <cstring>
int main(int argc, char** argv) {
    const char* selected = halliday_alyx_runtime::selected_library();
    if (!selected) return 1;
    return argc == 2 && !std::strcmp(selected, argv[1]) ? 0 : 2;
}
''')
exe = out / 'probe'
subprocess.run(['xcrun', 'clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I' + str(root / 'native-alyx/frame-bridge'), str(source), '-o', str(exe)], check=True)
environment = dict(os.environ)
environment.pop('HALLIDAY_NATIVE_OPENXR_RUNTIME', None)
environment.pop('HOME', None)
cases = [(None, 1), ('', 1), ('relative/runtime.dylib', 1),
         (str(out / "explicit library's path.dylib"), 0)]
results = []
for path, expected in cases:
    env = dict(environment)
    if path is not None:
        env['HALLIDAY_NATIVE_OPENXR_RUNTIME'] = path
    result = subprocess.run([str(exe), path or 'unused'], env=env,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == expected, (path, result.returncode, result.stderr)
    if expected:
        assert 'HALLIDAY_NATIVE_OPENXR_RUNTIME' in result.stderr
    results.append({'input': 'unset' if path is None else 'empty' if path == '' else
                    'relative' if not path.startswith('/') else 'explicit absolute',
                    'returncode': result.returncode, 'passed': True})
bridge = (root / 'native-alyx/frame-bridge/bridge.cpp').read_text()
selection = bridge.index('const char* path=halliday_alyx_runtime::selected_library(); if(!path)return 1;')
assert selection < bridge.index('dlopen(path,RTLD_NOW|RTLD_LOCAL)')
assert 'Library/Application Support/' not in bridge
assert 'halliday_alyx_runtime::application_name' in bridge
report = {'passed': True, 'scope': __doc__, 'cases': results,
          'actual_bridge_uses_mandatory_selector_before_dlopen': True}
(out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
