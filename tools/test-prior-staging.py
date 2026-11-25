#!/usr/bin/env python3
"""Exercise common automatic prior staging in owned runtime copies/disposable bottle.

No registry, user runtime, game or headset files are changed. Renamed public-API
clients must all use the same staging path without policy files. Obsolete policy
sentinels must not alter capture behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def windows_path(path):
    return 'Z:' + str(path.resolve()).replace('/', '\\')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--client', type=Path, required=True)
    parser.add_argument('--bottle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--wine', type=Path, default=Path('/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine'))
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    prefix, output = args.bottle.resolve(), args.output.resolve()
    if not (prefix.is_relative_to(ROOT/'windows-openxr/build/tests') or prefix.is_relative_to(ROOT/'build/validation')):
        parser.error('only the existing disposable test bottle is accepted')
    configuration = prefix/'cxbottle.conf'
    if not configuration.is_file() or output.exists() or not output.is_relative_to(ROOT/'build/validation'):
        parser.error('an existing test bottle and NEW validation output are required')
    if not any(args.client.resolve().is_relative_to(folder) for folder in [ROOT/'build', ROOT/'windows-openxr/build']):
        parser.error('only the locally built test client is accepted')
    client_bytes = args.client.read_bytes()
    if b'PASS: actual D3D11 automatic prior staging' not in client_bytes:
        parser.error('this is not the current owned public-API prior-staging fixture')
    cases = [
        ('unknown-default', 'unknown-future-game.exe', False),
        ('unknown-obsolete-policy-ignored', 'another-game.exe', True),
        ('dirt-obsolete-policy-ignored', 'DiRTRally2.EXE', True),
        ('ets2-obsolete-policy-ignored', 'EuroTrucks2.EXE', True),
    ]
    if not args.run:
        print(json.dumps({'prepared_only': True, 'cases': [case[0] for case in cases],
                          'scope': 'actual D3D11 GPU in disposable host; no real game/headset; use --run only when authorized'}))
        return
    marker = prefix/'.halliday-disposable-openxr-test'
    if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 64 or marker.read_bytes() != b'halliday-openxr-disposable-v1\n':
        parser.error('Mark the explicitly disposable bottle before using --run.')
    if not any(args.dll.resolve().is_relative_to(folder) for folder in [ROOT/'build', ROOT/'windows-openxr/build']):
        parser.error('Only a source-built project runtime is accepted.')
    output.mkdir(parents=True)
    owned_host = ROOT/'windows-openxr/build/tests'/('prior-staging-'+uuid.uuid4().hex[:12])
    owned_host.mkdir()
    receipt = {'passed': False, 'source_dll_sha256': sha(args.dll), 'source_client_sha256': sha(args.client),
               'bottle': str(prefix), 'configuration_before_sha256': sha(configuration),
               'no_registry_or_installed_files_changed': True, 'runs': []}
    def save():
        (output/'summary.json').write_text(json.dumps(receipt, indent=2)+'\n')
    try:
        for label, exe_name, obsolete_policy in cases:
            case = output/label
            case.mkdir()
            runtime = case/'halliday_openxr.dll'
            client = case/exe_name
            shutil.copy2(args.dll, runtime)
            shutil.copy2(args.client, client)
            if obsolete_policy:
                # Historical files have no runtime semantics in the common path.
                (case/'capture-mode').write_bytes(b'sync\n')
                profiles = case/'capture-profiles'
                profiles.mkdir()
                for name in ('dirtrally2.exe', 'eurotrucks2.exe'):
                    (profiles/name).write_bytes(b'sync\n')
            host = owned_host/(label+'.shm')
            env = dict(os.environ)
            for key in list(env):
                if key.startswith(('MOLTENVR_', 'HALLIDAY_')) or key in (
                    'CX_ROOT', 'CX_BOTTLE', 'WINEPREFIX', 'WINEDLLPATH', 'XR_RUNTIME_JSON', 'XR_RUNTIME_JSON_64'):
                    env.pop(key, None)
            env['WINEDEBUG'] = '-all'
            env['HALLIDAY_CHECK_PRIOR_STAGING_ONLY'] = '1'
            command = [str(args.wine), '--env', 'CX_GRAPHICS_BACKEND=d3dmetal', '--bottle', str(prefix),
                       '--no-update', '--no-gui', '--start', str(client), windows_path(runtime), windows_path(host)]
            start = time.monotonic()
            result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=75)
            (case/'stdout.log').write_bytes(result.stdout)
            (case/'stderr.log').write_bytes(result.stderr)
            passed = result.returncode == 0 and b'PASS: actual D3D11 automatic prior staging' in result.stdout
            receipt['runs'].append({'label': label, 'expected': 'PRIOR',
                'command': command, 'exit_code': result.returncode, 'seconds': time.monotonic()-start,
                'runtime_sha256': sha(runtime), 'obsolete_policy_files_present': obsolete_policy,
                'passed': passed})
            save()
            if not passed:
                raise RuntimeError(label+': automatic staging/GPU fixture failed; see preserved logs')
        receipt['passed'] = True
    finally:
        receipt['configuration_after_sha256'] = sha(configuration)
        receipt['configuration_unchanged'] = receipt['configuration_before_sha256'] == receipt['configuration_after_sha256']
        for file in owned_host.iterdir():
            if file.name.endswith('.shm') or file.name.endswith('.shm.restart'):
                file.unlink()
        try:
            owned_host.rmdir()
        except OSError:
            pass
        receipt['owned_hosts_cleaned'] = not owned_host.exists()
        save()
    print(json.dumps({'passed': receipt['passed'], 'runs': len(receipt['runs']), 'receipt': str(output/'summary.json')}))

if __name__ == '__main__':
    main()
