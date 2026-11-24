#!/usr/bin/env python3
"""Real Windows Vulkan/OpenXR pixels, using only this project's disposable bottle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--legacy', action='store_true')
parser.add_argument('--runtime', type=Path, default=root/'build/windows/bin/halliday_openxr.dll')
parser.add_argument('--crossover', type=Path, default=Path('/Applications/CrossOver.app'))
args = parser.parse_args()
runtime = args.runtime.resolve(strict=True)
exe = root/'build/windows/bin/runtime_vulkan_smoke.exe'
bottle = root/'build/tests/crossover-runtime-smoke'
if not (bottle/'user.reg').is_file():
    parser.error('Run the existing isolated D3D smoke once to create its disposable test bottle.')
run = root.parent/'build/validation/windows-vulkan'/('legacy-' if args.legacy else 'vulkan2-')
run = run.with_name(run.name+uuid.uuid4().hex)
run.mkdir(parents=True)
bridge = root/'build/tests'/('vulkan-'+uuid.uuid4().hex+'.shm')
snapshot = run/'halliday_openxr.dll'
snapshot.write_bytes(runtime.read_bytes())
win = lambda p: 'Z:'+str(p).replace('/', '\\')
env = dict(os.environ, WINEDEBUG='-all', CX_DEBUGMSG='-all', CX_LOG=str(run/'wine.log'))
for key in list(env):
    if key.startswith(('XR_', 'WINEPREFIX', 'CX_BOTTLE', 'HALLIDAY_BRIDGE')):
        env.pop(key)
command = [str(args.crossover/'Contents/SharedSupport/CrossOver/bin/wine'),
           '--bottle', str(bottle), '--no-update', '--no-gui', '--start', str(exe),
           win(snapshot), 'vulkan-1.dll', win(bridge)]
if args.legacy:
    command.append('--legacy')
report = {'passed': False, 'api': 'Vulkan legacy' if args.legacy else 'Vulkan2',
          'runtime_sha256': hashlib.sha256(snapshot.read_bytes()).hexdigest(),
          'scope': 'Real Vulkan app GPU commands and OpenXR image lifecycle through CrossOver; private synthetic host; no game, user bottle, registry, installed app or headset.'}
try:
    result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=90)
    (run/'stdout.log').write_text(result.stdout)
    (run/'stderr.log').write_text(result.stderr)
    output = result.stdout+result.stderr+(run/'wine.log').read_text(errors='replace')
    report.update(exit_code=result.returncode,
                  frames=[json.loads(line[6:]) for line in result.stdout.splitlines() if line.startswith('EVENT ')],
                  checks=[line for line in output.splitlines() if 'CHECK PASS:' in line or 'FAIL:' in line],
                  provider=[line for line in output.splitlines() if line.startswith('GPU ')])
    report['passed'] = result.returncode == 0 and len(report['frames']) == 16 and 'PASS: independent Windows public' in output
    print(result.stdout, end='')
    for line in output.splitlines():
        if 'FAIL:' in line:
            print(line)
finally:
    bridge.unlink(missing_ok=True)
    (run/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    print('Receipt:', run/'results.json')
raise SystemExit(0 if report['passed'] else 1)
