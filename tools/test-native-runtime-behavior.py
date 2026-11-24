#!/usr/bin/env python3
"""Source-built OpenXR lifecycle and timing observations with an isolated host.

Uses public OpenXR Metal calls and our public host C APIs. Default: compile-only. Explicit --run binds a Metal device without rendering
swapchain images. No app, game, hardware input or normal preferences are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--independent', type=Path, default=ROOT/'core/target/debug/libhalliday_openxr.dylib')
p.add_argument('--run', action='store_true', help='Explicitly execute the owned lifecycle probe (opens a Metal device)')
p.add_argument('--initial-hz', type=float, help='Emulate the launcher initial Hz hint for independent cases')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if a.initial_hz is not None and not 20 <= a.initial_hz <= 240:
    p.error('initial Hz must be finite and between 20 and 240')
out = a.output.resolve()
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
if not out.is_relative_to(ROOT / 'build/validation') or out.exists():
    p.error('output must be a new private directory under repository build/validation')
out.mkdir(parents=True)
env = dict(os.environ)
for key in list(env):
    if key.startswith(('MOLTENVR_', 'XR_RUNTIME_', 'DYLD_', 'HALLIDAY_')) or key in ['EYE_RES', 'VB_FPS']:
        env.pop(key)
probe = out / 'native-runtime-behavior'
compiled = subprocess.run(['xcrun', 'clang++', '-x', 'objective-c++', '-arch', 'arm64', '-std=c++17', '-O2',
    '-fobjc-arc', '-mmacosx-version-min=14.0', '-I'+str(ROOT/'windows-openxr/include'),
    '-I'+str(ROOT/'core/halliday-core/include'), str(ROOT/'tools/tests/native-runtime-behavior.mm'),
    '-x', 'none', str(Path(os.environ.get('HALLIDAY_CORE_LIBRARY_DIR', ROOT/'core/target/release'))/'libhalliday_core.a'), '-framework', 'Foundation',
    '-framework', 'Metal', '-framework', 'IOKit', '-framework', 'CoreFoundation', '-framework', 'Security',
    '-o', str(probe)], capture_output=True, text=True, env=env, timeout=60)
(out/'compile.log').write_text(compiled.stdout+compiled.stderr)
if compiled.returncode:
    raise SystemExit(compiled.stderr)
if not a.run:
    (out/'results.json').write_text(json.dumps({'compiled': True, 'executed': False, 'probe_sha256': sha(probe)}, indent=2)+'\n')
    print('PASS: lifecycle probe compiled only; use --run explicitly for graphics-device access.')
    raise SystemExit(0)
source_runtime = a.independent.resolve(strict=True)
if not any(source_runtime.is_relative_to(folder) for folder in [ROOT/'build', ROOT/'core/target']):
    p.error('Use a source-built runtime in this repository build/core target directories.')
cases = [('independent', source_runtime)]
report = {'scope': __doc__, 'probe_sha256': sha(probe), 'runs': {},
    'boundaries': ['Host dashboard/reference changes are Halliday extensions.',
                   'Prediction lead uses the runtime mach host clock; this is not measured motion-to-photon latency.',
                   'LOCAL origin placement is runtime policy, not physical controller calibration.']}

for label, source in cases:
    folder = out/label
    folder.mkdir()
    runtime = folder/source.name
    shutil.copy2(source, runtime)
    case_env = dict(env)
    if a.initial_hz is not None:
        case_env.update(HALLIDAY_DISPLAY_HZ=str(a.initial_hz), HALLIDAY_DISPLAY_HZ_INITIAL='1')
    result = subprocess.run([str(probe), str(runtime), str(folder/'host')], capture_output=True,
                            text=True, timeout=40, env=case_env)
    (folder/'stdout.log').write_text(result.stdout)
    (folder/'stderr.log').write_text(result.stderr)
    events = [json.loads(line[6:]) for line in result.stdout.splitlines() if line.startswith('EVENT ')]
    report['runs'][label] = {'exit_code': result.returncode, 'source': str(source.resolve()),
        'runtime_sha256': sha(runtime), 'source_unchanged': sha(source) == sha(runtime), 'events': events,
        'initial_hint_hz': a.initial_hz,
        'observation_completed': result.returncode == 0 and 'PASS direct' in result.stdout}
    (out/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    print(label+': '+('COMPLETE' if report['runs'][label]['observation_completed'] else 'FAILED'), flush=True)
    if result.returncode:
        print(result.stderr[-2000:], flush=True)
report['observations_completed'] = all(v['observation_completed'] for v in report['runs'].values())
(out/'results.json').write_text(json.dumps(report, indent=2)+'\n')
print('Receipt:', out/'results.json')
raise SystemExit(0 if report['observations_completed'] else 1)
