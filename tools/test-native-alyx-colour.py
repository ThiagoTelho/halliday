#!/usr/bin/env python3
"""Bounded real-dyld tests for the explicit legacy native-Alyx colour boundary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
args = parser.parse_args()
out = root/'build/validation/native-alyx-colour'/('dispatch-'+args.arch+'-'+uuid.uuid4().hex)
out.mkdir(parents=True)
helper = root/'build/native-alyx/bin/libhalliday_alyx_redirect.dylib'
env = dict(os.environ)
base = ['xcrun', 'clang++', '-arch', args.arch, '-std=c++17', '-O2', '-I'+str(root/'windows-openxr/include')]
for name, flags in [('independent', []), ('stock', ['-DOMIT_ENCODED_DECLARATION'])]:
    subprocess.run(base+flags+['-dynamiclib', str(root/'tools/tests/NativeAlyxColourRuntime.cpp'), '-o', str(out/(name+'.dylib'))], env=env, check=True)
subprocess.run(base+[str(root/'tools/tests/NativeAlyxColourProbe.cpp'), '-o', str(out/'probe')], env=env, check=True)
home = out/'home'
original = home/'Library/Application Support/MoltenVR/bin/libmoltenvr_openxr.dylib'
known = 'Halliday native Vulkan bridge'
cases = [('encoded RGBA UNORM', known, 37, 1, 'independent', {}),
         ('encoded BGRA UNORM', known, 44, 1, 'independent', {}),
         ('genuine RGBA SRGB', known, 43, 0, 'independent', {}),
         ('genuine BGRA SRGB', known, 50, 0, 'independent', {}),
         ('ordinary client', 'ordinary OpenXR game', 44, 0, 'independent', {}),
         ('lookalike client', known+' extra', 44, 0, 'independent', {}),
         ('historical public guest', 'MoltenVR native Vulkan probe', 44, 1, 'independent', {}),
         ('original stock runtime', known, 44, 0, 'stock', {}),
         ('failed declaration cleans new image', known, 44, 1, 'independent', {'TEST_DECLARATION_FAIL':'1'}),
         ('failed allocation has no declaration', known, 44, 0, 'independent', {'TEST_CREATE_FAIL':'1'})]
report = {'passed':False, 'arch':args.arch, 'helper_sha256':hashlib.sha256(helper.read_bytes()).hexdigest(), 'cases':[],
          'scope':'Owned dummy runtime and actual dyld interposition/public dispatch. No game, headset, installed app or GPU.'}
for name, app, fmt, count, runtime, extra in cases:
    selected = out/(runtime+'.dylib')
    process_env = dict(env, HOME=str(home), HALLIDAY_NATIVE_OPENXR_RUNTIME=str(selected),
                       DYLD_INSERT_LIBRARIES=str(helper), **extra)
    for request_name, request in [('direct selected path', selected), ('historical request alias', original)]:
        result = subprocess.run([str(out/'probe'), str(request), app, str(fmt), str(count)], env=process_env,
                                capture_output=True, text=True, timeout=10)
        report['cases'].append({'name':name, 'request':request_name, 'passed':result.returncode==0,
                               'returncode':result.returncode, 'stderr':result.stderr})
report['passed'] = all(case['passed'] for case in report['cases'])
(out/'results.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
print('Receipt:', out/'results.json')
raise SystemExit(0 if report['passed'] else 1)
