#!/usr/bin/env python3
"""Existing Metal checker against a new public-v6 synthetic host, with GPU pixel verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--runtime',type=Path,default=ROOT/'build/independent-native-openxr/libhalliday_openxr.dylib')
p.add_argument('--arch',choices=['arm64','x86_64'],default='arm64')
p.add_argument('--quads',action='store_true',help='Verify ordered world/VIEW quad layers against the same real GPU pixels')
p.add_argument('--compute',action='store_true',help='Request UNORDERED_ACCESS and verify actual Metal compute writes')
p.add_argument('--flips',action='store_true',help='Verify independent legal reversed-FOV H/V/HV flips against GPU pixels')
p.add_argument('--geometry',action='store_true',help='Verify custom asymmetric FOV, eye offsets and canted-camera metadata')
p.add_argument('--expected-batches',type=int,default=1,help='Expected runtime readback command buffers per frame; 0 records without asserting (old-baseline comparisons)')
p.add_argument('--eye',default='64x64',help='Private synthetic host per-eye extent')
p.add_argument('--skip-lifecycle',action='store_true',help='Skip new swapchain regressions only when measuring an older baseline')
a=p.parse_args()
try:
    eye_width,eye_height=map(int,a.eye.split('x'))
    if not (32<=eye_width<=2048 and 32<=eye_height<=2048):raise ValueError()
except ValueError:p.error('eye must be WIDTHxHEIGHT between32 and2048 per dimension')
if a.expected_batches<0:p.error('expected-batches must be nonnegative')
output=ROOT/'build/validation/native-independent-metal'/('run-'+a.arch+'-'+uuid.uuid4().hex)
output.mkdir(parents=True)
runtime=output/'libhalliday_openxr.dylib';shutil.copy2(a.runtime.resolve(strict=True),runtime)
probe=output/('openxr-metal-check-'+a.arch);bridge=output/'bridge.shm'
env=os.environ.copy()
for name in list(env):
    if name.startswith(('MOLTENVR_','XR_RUNTIME_','WINE','CX_BOTTLE','DYLD_')) or name in ('HALLIDAY_BRIDGE','HALLIDAY_BRIDGE_PATH'):
        env.pop(name)
env['HALLIDAY_BRIDGE']=str(bridge)
env['HALLIDAY_METAL_CHECK_BATCH_EXPECTED']=str(a.expected_batches)
if a.skip_lifecycle:env['HALLIDAY_METAL_CHECK_SKIP_LIFECYCLE']='1'
else:env.pop('HALLIDAY_METAL_CHECK_SKIP_LIFECYCLE',None)
if a.quads:env['HALLIDAY_METAL_CHECK_QUADS']='1'
else:env.pop('HALLIDAY_METAL_CHECK_QUADS',None)
for flag,name in [(a.compute,'HALLIDAY_METAL_CHECK_COMPUTE'),(a.flips,'HALLIDAY_METAL_CHECK_FLIPS'),(a.geometry,'HALLIDAY_METAL_CHECK_GEOMETRY')]:
    if flag:env[name]='1'
    else:env.pop(name,None)
compiled=subprocess.run(['xcrun','clang++','-x','objective-c++','-arch',a.arch,'-std=c++17','-O2','-fobjc-arc',
    '-DHALLIDAY_METAL_CHECK_VERIFY','-I'+str(ROOT/'windows-openxr/include'),'-I'+str(ROOT/'windows-openxr/src'),
    '-framework','Metal','-framework','Foundation',str(ROOT/'tools/openxr-metal-check.m'),'-o',str(probe)],
    env=env,capture_output=True,text=True,timeout=60)
(output/'compile.log').write_text(compiled.stdout+compiled.stderr)
if compiled.returncode:raise SystemExit(compiled.stderr)
report={'passed':False,'arch':a.arch,'runtime_sha256':hashlib.sha256(runtime.read_bytes()).hexdigest(),
    'quads':a.quads,'compute_shader_writes':a.compute,'per_eye_fov_flips':a.flips,'custom_projection_geometry':a.geometry,
    'eye':a.eye,'expected_readback_command_buffers':a.expected_batches or None,
    'swapchain_lifecycle_checked':not a.skip_lifecycle,
    'scope':'Existing native Metal checker, optional GPU oracle comparison, new private public-v6 halliday-probe host. No installed app/headset/game/registry or active bridge.'}
host=None
try:
    with (output/'host.log').open('w') as log:
        host=subprocess.Popen([str(ROOT/'core/target/release/halliday-probe'),'game-host','-s','4','--eye',a.eye,'--hz','90'],
                              env=env,stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+3
        while not bridge.exists() and time.monotonic()<deadline and host.poll() is None:time.sleep(.02)
        if not bridge.exists():raise RuntimeError('Private synthetic Metal host did not start')
        result=subprocess.run([str(probe),str(runtime),'4'],env=env,capture_output=True,text=True,timeout=15)
        (output/'stdout.log').write_text(result.stdout);(output/'stderr.log').write_text(result.stderr)
        report['returncode']=result.returncode
        report['verified_frames']=[line for line in result.stdout.splitlines() if line.startswith('METAL VERIFY PASS')]
        report['verified_quad_batches']=[line for line in result.stdout.splitlines() if line.startswith('METAL QUAD VERIFY PASS')]
        report['readback_command_buffers']=[int(line.rsplit('=',1)[1]) for line in result.stdout.splitlines() if line.startswith('METAL BATCH VERIFY PASS')]
        report['verified_compute_frames']=[line for line in result.stdout.splitlines() if line.startswith('METAL UAV VERIFY PASS')]
        report['verified_geometry_frames']=[line for line in result.stdout.splitlines() if line.startswith('METAL GEOMETRY VERIFY PASS')]
        report['passed']=result.returncode==0 and len(report['verified_frames'])==4 and (not a.quads or len(report['verified_quad_batches'])==4) and (not a.compute or len(report['verified_compute_frames'])==4) and (not a.geometry or len(report['verified_geometry_frames'])==4)
        print(result.stdout,end='');print(result.stderr,end='')
except Exception as error:
    report['error']=str(error)
finally:
    if host is not None:
        try:host.wait(timeout=5)
        except subprocess.TimeoutExpired:host.terminate();host.wait(timeout=3)
    bridge.unlink(missing_ok=True)
    (output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Receipt:',output/'results.json')
raise SystemExit(0 if report['passed'] else 1)
