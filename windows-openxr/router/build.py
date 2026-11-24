#!/usr/bin/env python3
"""Build the standalone router and inert regression DLLs; no Wine or user-prefix changes."""
import argparse, json, os, shutil, subprocess
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
out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
src=Path(__file__).resolve().parent
common=[cxx,'-std=c++17','-O2','-Wall','-Wextra','-Werror','-static','-D_WIN32_WINNT=0x0A00','-I'+str(root/'windows-openxr/include'),'-I'+str(json_include)]
def build(source,name,flags=()):
    subprocess.run(common+list(flags)+[str(src/source),'-o',str(out/name)],check=True)
build('router.cpp','halliday_openxr_router.dll',['-shared'])
build('tests/fake_runtime.cpp','fake_halliday.dll',['-shared','-DFAKE_ID=1'])
build('tests/fake_runtime.cpp','fake_external.dll',['-shared','-DFAKE_ID=2'])
build('tests/router_smoke.cpp','router-smoke.exe',['-municode'])
build('tests/router_suite.cpp','router-suite.exe',['-municode'])
build('tests/config_tests.cpp','router-config-tests.exe',['-I'+str(src)])
shutil.copy2(src/'LICENSE-nlohmann-json',out/'LICENSE-nlohmann-json')
(out/'halliday_openxr_router.json').write_text(json.dumps({'file_format_version':'1.0.0','runtime':{'library_path':'./halliday_openxr_router.dll'}},indent=2)+'\n')
print(out)
