#!/usr/bin/env python3
"""Bounded public Vulkan/OpenXR fixture; no installed app, game, bottle or headset."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime', type=Path, default=ROOT / 'core/target/debug/libhalliday_openxr.dylib')
parser.add_argument('--driver', type=Path, default=Path('/opt/homebrew/lib/libMoltenVK.dylib'))
parser.add_argument('--vulkan-include', type=Path, default=Path(os.environ['VULKAN_SDK'])/'include' if os.environ.get('VULKAN_SDK') else Path('/opt/homebrew/include'))
parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
parser.add_argument('--colour-gray', action='store_true', help='Read actual middle-gray GPU bytes/tags for the Metal colour oracle')
legacy_options = parser.add_mutually_exclusive_group()
legacy_options.add_argument('--legacy', action='store_true', help='Exercise XR_KHR_vulkan_enable with app-created VkInstance/VkDevice')
legacy_options.add_argument('--legacy-no-hook', action='store_true', help='Legacy API with a globally loaded application driver and no early loader hook')
args = parser.parse_args()
args.legacy = args.legacy or args.legacy_no_hook
runtime = args.runtime.resolve(strict=True)
driver = args.driver.resolve(strict=True)
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
for binary in [runtime, driver]:
    found = subprocess.run(['lipo', str(binary), '-verify_arch', args.arch], capture_output=True, text=True)
    if found.returncode:
        parser.error(f'{binary} has no actual {args.arch} slice; cannot run this architecture')
output = ROOT / 'build/validation/native-independent-vulkan' / ('run-' + args.arch + ('-legacy-' if args.legacy else '-') + uuid.uuid4().hex)
output.mkdir(parents=True)
snapshot = output / 'libhalliday_openxr.dylib'
shutil.copy2(runtime, snapshot)
probe = output / ('native-independent-vulkan-probe-' + args.arch)
environment = os.environ.copy()
for name in list(environment):
    if name.startswith(('XR_RUNTIME_', 'WINE', 'CX_BOTTLE', 'DYLD_')) or name in ('HALLIDAY_BRIDGE', 'HALLIDAY_BRIDGE_PATH'):
        environment.pop(name)
environment.pop('HALLIDAY_CHECK_TRANSFER_GRAY', None)
if args.colour_gray:
    environment['HALLIDAY_CHECK_TRANSFER_GRAY'] = '1'
load_path = snapshot
compile_result = subprocess.run(['xcrun', 'clang++', '-arch', args.arch, '-std=c++17', '-O2', '-mmacosx-version-min=14.0',
    '-I' + str(ROOT / 'windows-openxr/include'), '-I' + str(ROOT / 'windows-openxr/src'), '-I' + str(ROOT / 'windows-openxr/tests'), '-I' + str(args.vulkan_include),
    str(ROOT / 'tools/tests/native-independent-vulkan-probe.cpp'), '-o', str(probe)],
    env=environment, capture_output=True, text=True, timeout=60)
(output / 'compile.log').write_text(compile_result.stdout + compile_result.stderr)
if compile_result.returncode:
    raise SystemExit(compile_result.stderr)
bridge = output / 'bridge.shm'
mode = 'Vulkan legacy' if args.legacy else 'Vulkan2'
report = {'passed': False, 'architecture': args.arch, 'api': mode,
    'loader_mode': 'application global symbol' if args.legacy_no_hook else 'application early hook' if args.legacy else 'Vulkan2 public create info',
    'runtime': str(runtime), 'runtime_sha256': sha(snapshot),
    'driver': str(driver), 'driver_sha256': sha(driver), 'probe_sha256': sha(probe),
    'scope': f'Public {mode}/OpenXR calls into independent source runtime, private public-v6 synthetic host. Real GPU patterns and CPU readback transport; no installed app, game/bottle/headset, codec or end-to-end performance measurement.',
    'source': str(ROOT / 'tools/tests/native-independent-vulkan-probe.cpp')}
try:
    result = subprocess.run([str(probe), str(load_path), str(driver), str(bridge)] + (['--legacy-no-hook'] if args.legacy_no_hook else ['--legacy'] if args.legacy else []), env=environment,
        capture_output=True, text=True, timeout=60)
    (output / 'stdout.log').write_text(result.stdout)
    (output / 'stderr.log').write_text(result.stderr)
    report['returncode'] = result.returncode
    report['frames'] = [json.loads(line[6:]) for line in result.stdout.splitlines() if line.startswith('EVENT ')]
    report['colour_samples'] = [json.loads(line[6:]) for line in result.stdout.splitlines() if line.startswith('COLOR ')]
    report['checks'] = [line for line in result.stdout.splitlines() if line.startswith('CHECK PASS:')]
    report['provider'] = [line for line in result.stdout.splitlines() if line.startswith('GPU ')]
    report['passed'] = result.returncode == 0 and len(report['frames']) == 16 and f'PASS: independent native public {mode} runtime' in result.stdout
    if args.colour_gray:
        report['passed'] = report['passed'] and len(report['colour_samples']) == 16
    print(result.stdout, end='')
    if result.stderr:
        # Preserve the provider's full diagnostics in stderr.log; show relevant
        # failures/warnings here rather than its complete extension catalogue.
        for line in result.stderr.splitlines():
            if any(word in line.lower() for word in ('fail:', 'error', 'warning', '[mvk-warn]')):
                print(line)
except subprocess.TimeoutExpired as error:
    report['error'] = 'Bounded native Vulkan fixture timed out after 60s'
    (output / 'stdout.log').write_text((error.stdout or b'').decode(errors='replace'))
    (output / 'stderr.log').write_text((error.stderr or b'').decode(errors='replace'))
finally:
    bridge.unlink(missing_ok=True)
    (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Receipt:', output / 'results.json')
raise SystemExit(0 if report['passed'] else 1)
