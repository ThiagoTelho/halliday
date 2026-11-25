#!/usr/bin/env python3
"""Fake-module routing tests. Wine is confined to an existing disposable project bottle.

No registry keys are read/written, no real VR modules are loaded, no game/HID/GPU is used.
"""
import argparse,hashlib,json,os,shutil,subprocess,time,uuid
from pathlib import Path
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bottle',type=Path,default=root/'windows-openxr/build/tests/crossover-runtime-smoke')
parser.add_argument('--wine',type=Path,default=Path('/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine'))
parser.add_argument('--only', help='Comma-separated case names; config suite always runs')
parser.add_argument('--binaries',type=Path,default=root/'build/router-openxr/bin')
args=parser.parse_args()
bottle=args.bottle.resolve(strict=True)
allowed=[root/'windows-openxr/build/tests',root/'build/validation']
if not any(bottle.is_relative_to(p.resolve()) for p in allowed) or not(bottle/'cxbottle.conf').is_file():
    parser.error('Only an existing disposable bottle under this project test/validation directories is allowed')
out=root/'build/validation/automatic-runtime-routing'/('router-'+uuid.uuid4().hex[:10]);out.mkdir(parents=True)
def win(p):return 'Z:'+str(p.resolve()).replace('/','\\')
def manifest(folder,name,alias=False):
    folder.mkdir(parents=True,exist_ok=True)
    shutil.copy2(args.binaries/name,folder/name)
    value={'file_format_version':'1.0.0','runtime':{'library_path':'./'+name}}
    if alias:value['runtime']['functions']={'xrNegotiateLoaderRuntimeInterface':'testNegotiate'}
    file=folder/'runtime.json';file.write_text(json.dumps(value,ensure_ascii=False));return file
cases=[('worn','fresh',1,'none'),('not-worn-other-connected','unworn',2,'none'),('no-external','no-external',1,'none'),('halliday-only-no-policy','missing',1,'none'),
('host-not-ready','notready',2,'none'),('missing-policy','missing',2,'none'),('bad-policy','malformed',2,'none'),
('duplicate-policy','duplicate',2,'none'),('oversized-policy','oversize',2,'none'),('stale-policy','stale',2,'none'),
('future-policy','future',2,'none'),('custom-export','fresh',1,'alias'),('negotiate-error','fresh',1,'negotiate'),
('create-error','fresh',1,'create'),('missing-selected-manifest','fresh',1,'selection'),
('missing-selected-dll','fresh',1,'selection'),('duplicate-selected-manifest','fresh',1,'selection'),
('self-recursion','fresh',1,'selection'),('invalid-nonselected-external','fresh',1,'none'),
('invalid-nonselected-halliday','unworn',2,'none'),('unicode-Квест-🚀','fresh',1,'none'),('concurrent-first','fresh',1,'concurrent'),
('cross-api-halliday','unworn',1,'prepin-halliday'),('cross-api-external','fresh',2,'prepin-external'),('child-independent','fresh',1,'child')]
env=os.environ.copy()
for key in list(env):
    if key.startswith('HALLIDAY_') or key in ['CX_LOG','WINEPREFIX','CX_BOTTLE','XR_RUNTIME_JSON','XR_RUNTIME_JSON_64','WINEDLLOVERRIDES']:
        env.pop(key,None)
env.update(CX_DEBUGMSG='-all',WINEDEBUG='-all')
base=[str(args.wine),'--bottle',str(bottle),'--no-update','--no-gui']
results=[]
# The pure parser/policy suite is also exercised in the actual Windows binary.
for name,command in [('config',base+[str(args.binaries/'router-config-tests.exe')])]:
    p=subprocess.run(command,env=env,capture_output=True,timeout=40)
    (out/(name+'.log')).write_bytes(p.stdout+p.stderr)
    results.append({'case':name,'exit':p.returncode,'output':p.stdout.decode(errors='replace')})
batch=[]
for name,mode,expected,failure in cases:
    if args.only and name not in args.only.split(','):continue
    folder=out/name;folder.mkdir()
    shutil.copy2(args.binaries/'halliday_openxr_router.dll',folder/'halliday_openxr_router.dll')
    h=manifest(folder/'halliday','fake_halliday.dll',failure=='alias')
    m=manifest(folder/'external','fake_external.dll')
    config={'version':1,'halliday_manifest':win(h),'external_manifest':win(m),'policy_file':win(folder/'policy.json')}
    if name=='halliday-only-no-policy':config.pop('external_manifest')
    if name=='missing-selected-manifest':h.unlink()
    if name=='missing-selected-dll':(h.parent/'fake_halliday.dll').unlink()
    if name=='duplicate-selected-manifest':h.write_text('{"file_format_version":"1.0.0","runtime":{"library_path":"fake_halliday.dll","library_path":"bad.dll"}}')
    if name=='self-recursion':h.write_text(json.dumps({'file_format_version':'1.0.0','runtime':{'library_path':win(folder/'halliday_openxr_router.dll')}}))
    if name=='invalid-nonselected-external':m.write_text('{broken')
    if name=='invalid-nonselected-halliday':h.write_text('{broken')
    (folder/'halliday-openxr-router.json').write_text(json.dumps(config,ensure_ascii=False),encoding='utf-8')
    batch.append({'name':name,'folder':win(folder),'mode':mode,'expected':expected,'failure':failure})
fixture=out/'cases.json';fixture.write_text(json.dumps({'program':win(args.binaries/'router-smoke.exe'),'cases':batch},ensure_ascii=False),encoding='utf-8')
start=time.monotonic()
p=subprocess.run(base+[str(args.binaries/'router-suite.exe'),win(fixture)],env=env,capture_output=True,timeout=max(60,35*len(batch)))
(out/'suite.log').write_bytes(p.stdout+p.stderr)
print(p.stdout.decode(errors='replace'),flush=True)
for item in batch:
    log=(out/item['name']/'result.log')
    raw=log.read_bytes() if log.is_file() else b'Missing child result'
    result={'case':item['name'],'pass':'PASS:' in raw.decode(errors='replace') and 'FAIL:' not in raw.decode(errors='replace'),'output':raw.decode(errors='replace')}
    results.append(result)
summary={'results':results,'all_pass':p.returncode==0 and all((x.get('exit')==0 or x.get('pass') is True) and 'PASS:' in x['output'] for x in results),
 'scope':'Inert fake modules only; existing disposable bottle; no registry/HID/GPU/game/real runtime operations.',
 'binaries':[{ 'path':str(p.resolve()),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(args.binaries.iterdir()) if p.is_file()]}
(out/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
print(out/'summary.json')
raise SystemExit(0 if summary['all_pass'] else 1)
