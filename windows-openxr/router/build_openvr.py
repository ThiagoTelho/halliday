#!/usr/bin/env python3
"""Build OpenVR routing/probes only; never opens Wine or changes a prefix."""
import argparse, os, shutil, subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cxx', default=os.environ.get('HALLIDAY_MINGW_CXX'))
parser.add_argument('--json-include', type=Path, default=os.environ.get('HALLIDAY_JSON_INCLUDE'))
parser.add_argument('--output', type=Path, default=root/'build/router-openxr/bin')
args = parser.parse_args()
cxx = args.cxx or shutil.which('x86_64-w64-mingw32-clang++') or shutil.which('x86_64-w64-mingw32-g++')
json_include = args.json_include or next((p for p in map(Path, ['/opt/homebrew/include', '/usr/local/include', '/usr/include'])
                                         if (p/'nlohmann/json.hpp').is_file()), None)
if not cxx or not json_include or not (json_include/'nlohmann/json.hpp').is_file():
    parser.error('Set --cxx (or HALLIDAY_MINGW_CXX) to a MinGW C++ compiler and --json-include (or HALLIDAY_JSON_INCLUDE) to nlohmann/json headers')
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
src = Path(__file__).resolve().parent
common = [cxx, '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror', '-static',
          '-D_WIN32_WINNT=0x0A00', '-I'+str(json_include), '-I'+str(root/'windows-openxr/include')]
def build(source, name, flags=()):
    subprocess.run(common+list(flags)+[str(src/source), '-o', str(out/name)], check=True)
build('tests/openvr_core_probe.cpp', 'openvr-core-probe.exe', ['-municode'])
if (src/'openvr_router.cpp').exists():
    build('openvr_router.cpp', 'vrclient_x64.dll', ['-shared'])
if (src/'tests/openvr_router_smoke.cpp').exists():
    build('tests/openvr_router_smoke.cpp', 'openvr-router-smoke.exe', ['-municode'])
if (src/'tests/fake_openvr.cpp').exists():
    for name, identifier in [('fake_vr_halliday.dll', 1), ('fake_vr_external.dll', 2)]:
        build('tests/fake_openvr.cpp', name, ['-shared', '-DFAKE_ID='+str(identifier)])
print(out)
