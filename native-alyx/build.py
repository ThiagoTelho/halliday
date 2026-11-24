#!/usr/bin/env python3
"""Build the selected-only redirect helper; no installed game file is changed."""
import pathlib
import argparse
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--steam-ready-only', action='store_true')
args = parser.parse_args()
out = root / 'build/native-alyx/bin'
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=14.0',
                str(root/'native-alyx/steam_ready.c'), '-o', str(out/'halliday-steam-ready')], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(out/'halliday-steam-ready')], check=True)
if args.steam_ready_only:
    print(out)
    raise SystemExit(0)
subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', '-dynamiclib', '-arch', 'arm64', '-arch', 'x86_64',
                '-I' + str(root/'windows-openxr/include'),
                '-mmacosx-version-min=14.0', str(root/'native-alyx/redirect.cpp'),
                '-install_name', '@rpath/libhalliday_alyx_redirect.dylib',
                '-o', str(out/'libhalliday_alyx_redirect.dylib')], check=True)
shutil.copy2(root/'native-alyx/halliday-alyx-bridge', out/'halliday-alyx-bridge')
(out/'halliday-alyx-bridge').chmod(0o755)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(out/'libhalliday_alyx_redirect.dylib')], check=True)
print(out)
