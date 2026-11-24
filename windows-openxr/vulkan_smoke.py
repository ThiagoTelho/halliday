#!/usr/bin/env python3
"""Compatibility CLI for the guarded synthetic Vulkan runner (48 verified frames)."""
import argparse
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--legacy', action='store_true')
parser.add_argument('--runtime', type=Path, default=root/'build/windows/bin/halliday_openxr.dll')
parser.add_argument('--crossover', type=Path, default=Path('/Applications/CrossOver.app'))
parser.add_argument('--bottle', type=Path, default=root/'build/tests/crossover-runtime-smoke')
parser.add_argument('--run', action='store_true')
args = parser.parse_args()
if not args.run:
    parser.error('No Wine/GPU command was started; use --run with a marked disposable bottle.')
command = [sys.executable, str(root.parent/'tools/test-independent-windows-vulkan.py'), '--run',
           '--runtime', str(args.runtime), '--bottle', str(args.bottle),
           '--wine', str(args.crossover/'Contents/SharedSupport/CrossOver/bin/wine'),
           '--api', 'legacy' if args.legacy else 'vulkan2']
raise SystemExit(subprocess.call(command))
