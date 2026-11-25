#!/usr/bin/env python3
"""Inert OpenVR router tests in the project-owned disposable CrossOver bottle.

Never changes a registry, game DLL, user prefix or active headset. The optional
actual OpenComposite case refuses Init unless all runtime registrations are absent.
"""
import argparse, hashlib, json, os, shutil, subprocess, time, uuid
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--run', action='store_true')
parser.add_argument('--actual-oc', type=Path)
parser.add_argument('--bin', type=Path, default=root/'build/router-openxr/bin')
args = parser.parse_args()
bottle = root/'windows-openxr/build/tests/crossover-runtime-smoke'
assert bottle.resolve() == bottle and (bottle/'cxbottle.conf').is_file(), 'only the owned smoke bottle is permitted'
out = root/'build/validation/openvr-routing'/('router-'+uuid.uuid4().hex[:10])
out.mkdir(parents=True)
frozen = out/'binaries'; frozen.mkdir()
for name in ['vrclient_x64.dll','openvr-router-smoke.exe','fake_vr_halliday.dll','fake_vr_external.dll',
             'halliday_openxr_router.dll','fake_halliday.dll','fake_external.dll']:
    shutil.copy2(args.bin/name, frozen/name)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
win = lambda p: 'Z:'+str(p.resolve()).replace('/', '\\')
report = {'passed':False,'scope':'Inert x64 OpenVR broker/public ClientCore003 fixtures; no game or headset success claim.',
          'router_sha256':sha(frozen/'vrclient_x64.dll'),'xr_router_sha256':sha(frozen/'halliday_openxr_router.dll'),
          'bottle':str(bottle),'run_requested':args.run,'cases':[]}
base = {'version':1,'updated_unix_ms':0,'halliday_ready':True,'psvr2_worn':True,'external_active':True}
cases = [('psvr-worn',1,{}),('quest-running',2,{'psvr2_worn':False}),
         ('psvr-only',1,{'psvr2_worn':False,'external_active':False}),('halliday-not-ready',2,{'halliday_ready':False}),
         ('missing-policy',2,{}),('stale-policy',2,{}),('future-policy',2,{}),('malformed-policy',2,{}),
         ('halliday-only-no-policy',1,{}),('missing-openvr-config',0,{}),('self-backend',0,{}),('nested-router',0,{}),
         ('bad-backend-factory',0,{}),('safe-error-fallback',2,{'psvr2_worn':False}),
         ('classic-bin',1,{}),('openvr-before-xr',2,{'psvr2_worn':False}),('xr-before-openvr',2,{'psvr2_worn':False})]
if args.actual_oc:
    assert args.actual_oc.is_file()
    report['actual_oc']={'path':str(args.actual_oc.resolve()),'sha256':sha(args.actual_oc)}
    cases.append(('actual-oc-negative',2,{'psvr2_worn':False}))
wine = '/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine'
try:
    for name, expected, patch in cases:
        case = out/name; case.mkdir()
        folder = case/'OpenVR/bin' if name == 'classic-bin' else case/'OpenVR/bin/win64'
        folder.mkdir(parents=True)
        router = folder/'vrclient_x64.dll'; shutil.copy2(frozen/'vrclient_x64.dll',router)
        xr = case/'halliday_openxr_router.dll'; shutil.copy2(frozen/'halliday_openxr_router.dll',xr)
        policy = case/'policy.json'
        config = {'version':1,'halliday_manifest':win(case/'halliday.json'),'external_manifest':win(case/'external.json'),
                  'policy_file':win(policy),'halliday_openvr_library':win(frozen/'fake_vr_halliday.dll'),
                  'external_openvr_library':win(frozen/'fake_vr_external.dll')}
        for kind in ['halliday','external']:
            (case/(kind+'.json')).write_text(json.dumps({'file_format_version':'1.0.0',
                'runtime':{'library_path':win(frozen/('fake_'+kind+'.dll'))}}))
        if name == 'missing-openvr-config':
            config.pop('halliday_openvr_library');config.pop('external_openvr_library')
        if name == 'halliday-only-no-policy':
            config.pop('external_manifest');config.pop('external_openvr_library')
        if name in ['safe-error-fallback','actual-oc-negative']:
            config['external_safe_error_strings'] = True
        if name in ['self-backend','nested-router']:
            config['halliday_openvr_library']=win(router if name=='self-backend' else xr)
        if name == 'actual-oc-negative':config['external_openvr_library']=win(args.actual_oc)
        (case/'halliday-openxr-router.json').write_text(json.dumps(config,indent=2)+'\n')
        state=dict(base,updated_unix_ms=int(time.time()*1000),**patch)
        if name == 'stale-policy':state['updated_unix_ms']-=10_000
        if name == 'future-policy':state['updated_unix_ms']+=10_000
        if name not in ['missing-policy','halliday-only-no-policy']:policy.write_text('{' if name=='malformed-policy' else json.dumps(state))
        env=os.environ.copy();env.update(WINEDEBUG='-all',CX_DEBUGMSG='-all',MVK_CONFIG_LOG_LEVEL='0')
        env.pop('HALLIDAY_FAKE_POLICY_OFFSET_MS',None)
        if name not in ['missing-policy','malformed-policy','halliday-only-no-policy']:
            env['HALLIDAY_FAKE_POLICY_OFFSET_MS']=str(-10_000 if name=='stale-policy' else 10_000 if name=='future-policy' else 0)
        for key in ['HALLIDAY_FAKE_VR_INIT_FAIL','HALLIDAY_FAKE_VR_BAD_FACTORY','HALLIDAY_FAKE_VR_BAD_ERRORS']:
            env.pop(key,None)
        mode='normal'
        if name=='bad-backend-factory':env['HALLIDAY_FAKE_VR_BAD_FACTORY']='1'
        if name=='safe-error-fallback':
            env['HALLIDAY_FAKE_VR_BAD_ERRORS']='1';env['HALLIDAY_FAKE_VR_INIT_FAIL']='1';mode='negative'
        if name=='actual-oc-negative':mode='actual'
        if name=='xr-before-openvr':mode='xrfirst'
        command=[wine,'--bottle',str(bottle),'--no-update','--no-gui',str(frozen/'openvr-router-smoke.exe'),
                 win(router),win(policy),str(expected),mode]
        if name in ['openvr-before-xr','xr-before-openvr']:command.append(win(xr))
        record={'name':name,'expected_backend':expected,'mode':mode,'command':command}
        report['cases'].append(record)
        if args.run:
            process=subprocess.run(command,env=env,cwd=case,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
            (case/'output.log').write_bytes(process.stdout)
            record.update(exit_code=process.returncode,passed=process.returncode==0 and b'PASS OpenVR' in process.stdout)
            print(name,process.returncode,flush=True)
            if not record['passed']:raise RuntimeError('OpenVR case failed: '+name)
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    report['passed']=args.run
finally:
    (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
print(out)
