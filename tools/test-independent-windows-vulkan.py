#!/usr/bin/env python3
"""Real Vulkan pixels/call-count checks in an explicit disposable CrossOver bottle.

The test directly negotiates its copied DLL; it does not register a runtime,
launch games or touch an installed app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--bottle', type=Path, default=ROOT / 'windows-openxr/build/tests/crossover-runtime-smoke')
p.add_argument('--wine', type=Path, default=Path('/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine'))
p.add_argument('--runtime', type=Path, default=ROOT / 'windows-openxr/build/windows/bin/halliday_openxr.dll')
p.add_argument('--probe', type=Path, default=ROOT / 'windows-openxr/build/windows/bin/runtime_vulkan_smoke.exe')
p.add_argument('--run', action='store_true', help='Explicitly run GPU/Wine against a marked disposable bottle')
p.add_argument('--api', choices=['both', 'legacy', 'legacy-no-hook', 'vulkan2'], default='both')
a = p.parse_args()
if not a.run:
    p.error('No Wine/GPU command was started; use --run with a marked disposable test bottle.')
bottle = a.bottle.resolve(strict=True)
if not any(bottle.is_relative_to(ROOT / part) for part in ['windows-openxr/build/tests', 'build/validation']):
    p.error('the bottle must be disposable and inside this repository build/tests or build/validation')
config = bottle / 'cxbottle.conf'
if not config.is_file():
    p.error('initialize the disposable CrossOver bottle first')
marker = bottle/'.halliday-disposable-openxr-test'
if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 64 or marker.read_bytes() != b'halliday-openxr-disposable-v1\n':
    p.error('The bottle requires the explicit disposable-fixture ownership marker.')
for source in [a.runtime, a.probe]:
    if not any(source.resolve().is_relative_to(folder) for folder in [ROOT/'build', ROOT/'windows-openxr/build']):
        p.error('Use only source-built project runtime/probe artifacts.')
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
windows = lambda path: 'Z:' + str(path.resolve()).replace('/', '\\')
token = uuid.uuid4().hex
fixture = ROOT / 'windows-openxr/build/tests' / ('vulkan-batch-' + token)
fixture.mkdir()
runtime = fixture / 'halliday_openxr.dll'
probe = fixture / 'runtime_vulkan_smoke.exe'
shutil.copy2(a.runtime, runtime)
shutil.copy2(a.probe, probe)
output = ROOT / 'build/validation/windows-vulkan' / ('batch-' + token)
output.mkdir(parents=True)
env = dict(os.environ)
for key in list(env):
    if key.startswith(('CX_', 'WINE', 'XR_RUNTIME_', 'MOLTENVR_', 'DYLD_')) or key in ('HALLIDAY_BRIDGE', 'HALLIDAY_BRIDGE_PATH'):
        env.pop(key)
env['WINEDEBUG'] = '-all'
report = {'passed': False, 'runtime_sha256': sha(runtime), 'probe_sha256': sha(probe),
          'bottle': str(bottle), 'configuration_sha256': sha(config), 'runs': {},
          'scope': 'Real Apple GPU Vulkan patterns, actual queue/fence call counts, private synthetic host, disposable bottle. No game, physical headset, codec, installed app or end-to-end FPS/latency measurement.'}
modes = ['vulkan2', 'legacy'] if a.api == 'both' else [a.api]
try:
    for mode in modes:
        bridge = fixture / (mode + '.shm')
        command = [str(a.wine), '--bottle', str(bottle), '--no-update', '--no-gui', '--start', str(probe),
                   windows(runtime), 'vulkan-1.dll', windows(bridge)]
        if mode in ('legacy', 'legacy-no-hook'):
            command.append('--legacy-no-hook' if mode == 'legacy-no-hook' else '--legacy')
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
        (output / (mode + '.stdout.log')).write_text(result.stdout)
        (output / (mode + '.stderr.log')).write_text(result.stderr)
        frames = [json.loads(line[6:]) for line in result.stdout.splitlines() if line.startswith('EVENT ')]
        passed = result.returncode == 0 and len(frames) == 48 and 'PASS: independent Windows public' in result.stdout
        report['runs'][mode] = {'passed': passed, 'exit_code': result.returncode, 'frames': frames,
            'checks': [line for line in result.stdout.splitlines() if line.startswith('CHECK PASS:')],
            'provider': [line for line in result.stdout.splitlines() if line.startswith('GPU ')]}
        print(mode + ': ' + ('PASS' if passed else 'FAIL'), flush=True)
        if not passed:
            print(result.stdout[-5000:] + result.stderr[-1500:])
            raise RuntimeError(mode + ' GPU fixture failed')
        if bridge.exists():
            raise RuntimeError('runtime fixture did not remove its private bridge')
    report['passed'] = True
except (RuntimeError, subprocess.TimeoutExpired) as error:
    report['error'] = str(error)
finally:
    report['configuration_unchanged'] = sha(config) == report['configuration_sha256']
    report['passed'] &= report['configuration_unchanged']
    (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Receipt:', output / 'results.json')
    # Retain failed fixture files for inspection; completed binary inputs are
    # already identified by hash and remain in normal build output.
    if report['passed']:
        shutil.rmtree(fixture)
raise SystemExit(0 if report['passed'] else 1)
