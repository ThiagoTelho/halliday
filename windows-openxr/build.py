#!/usr/bin/env python3
"""Build isolated native protocol checks and/or the Windows runtime. No Wine launch."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("target", choices=("native", "windows", "all"), default="all", nargs="?")
parser.add_argument("--jobs", type=int, default=2, help="Maximum compiler jobs (default: 2)")
args = parser.parse_args()
if args.jobs < 1: parser.error("--jobs must be positive")
environment = os.environ.copy()
if not environment.get("HALLIDAY_MINGW_BIN"):
    candidate = root.parent / ".tools/llvm-mingw/bin"
    if candidate.is_dir(): environment["HALLIDAY_MINGW_BIN"] = str(candidate)

def run(*command):
    subprocess.run(command, cwd=root, env=environment, check=True)

for target in ("native", "windows"):
    if args.target not in (target, "all"): continue
    output = root / "build" / target
    options = ["-DCMAKE_BUILD_TYPE=RelWithDebInfo"]
    if target == "windows":
        options += ["-DCMAKE_TOOLCHAIN_FILE=" + str(root / "cmake/llvm-mingw.cmake")]
    run(shutil.which("cmake") or "cmake", "-S", str(root), "-B", str(output), *options)
    run("cmake", "--build", str(output), "--parallel", str(args.jobs))
    if target == "native": run("ctest", "--test-dir", str(output), "--output-on-failure")
