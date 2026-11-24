#!/usr/bin/env python3
"""Test the compiled native gate with inert fake dylibs only. Never loads Steam."""
from pathlib import Path
import json
import os
import signal
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
HELPER=ROOT/'build/native-alyx/bin/halliday-steam-ready'
SOURCE=ROOT/'tools/tests/SteamReadinessFake.c'
OUT=ROOT/'build/validation/steam-readiness-gate'
OUT.mkdir(parents=True,exist_ok=True)
results=[]
with tempfile.TemporaryDirectory(prefix='halliday-fake-steam-') as td:
    folder=Path(td)
    full=folder/'fake library.dylib';missing=folder/'missing-release.dylib'
    for library,defines in [(full,[]),(missing,['-DHALLIDAY_FAKE_MISSING_RELEASE'])]:
        subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-dynamiclib',
            '-arch','arm64','-arch','x86_64',*defines,str(SOURCE),'-o',str(library)],check=True)
    for arch in ['arm64','x86_64']:
        prefix=['/usr/bin/arch','-'+arch,str(HELPER)]
        def run(name,mode='ready',library=full,args=(),expected=0,calls=None):
            log=folder/(arch+'-'+name+'.calls');counter=folder/(arch+'-'+name+'.attempts');pidfile=folder/(arch+'-'+name+'.pid')
            env=dict(os.environ,HALLIDAY_FAKE_STEAM_MODE=mode,HALLIDAY_FAKE_STEAM_CALLS=str(log),
                HALLIDAY_FAKE_STEAM_ATTEMPTS=str(counter),HALLIDAY_FAKE_STEAM_PID=str(pidfile))
            start=time.monotonic()
            timeout='2000' if expected==0 else '250'
            probe='1500' if expected==0 else '80'
            p=subprocess.run(prefix+['--library',str(library),'--timeout-ms',timeout,'--probe-timeout-ms',probe,
                '--interval-ms','10',*args],capture_output=True,text=True,env=env,timeout=3)
            elapsed=time.monotonic()-start;observed=log.read_text() if log.exists() else ''
            assert p.returncode==expected,(arch,name,p.returncode,p.stdout,p.stderr)
            if calls is not None:assert observed==calls,(name,observed,calls)
            assert elapsed<2.5,(name,elapsed)
            if expected==70:assert 'Alyx was not started' in p.stderr
            if mode=='eventually':assert counter.read_text()=='3' and observed=='ccculrp'
            if mode=='hang' and pidfile.exists():
                try:os.kill(int(pidfile.read_text()),0)
                except ProcessLookupError:pass
                else:raise AssertionError('probe child survived timeout')
            results.append({'arch':arch,'case':name,'passed':True,'exit':p.returncode,'seconds':round(elapsed,3),'calls':observed})
            return p
        run('ready',calls='culrp')
        p=run('offline-local-user','offline',calls='culrp');assert 'offline client supported' in p.stdout
        p=run('eventually-ready','eventually');assert '3 attempt(s)' in p.stdout
        p=run('no-client','no-pipe',expected=70);assert p.stdout.count('Steam readiness: client-starting')==1
        p=run('no-user','no-user',expected=70);calls=(folder/(arch+'-no-user.calls')).read_text();assert calls and calls.replace('cup','')==''
        run('missing-library',library=folder/'absent.dylib',expected=70,calls='')
        run('missing-required-release',library=missing,expected=70,calls='')
        run('hung-api','hang',expected=70)
        run('invalid-zero-timeout',args=['--timeout-ms','0'],expected=64,calls='')
        run('invalid-excessive-timeout',args=['--timeout-ms','45001'],expected=64,calls='')
        run('invalid-relative-library',library=Path('relative.dylib'),expected=64,calls='')
        run('live-owner',args=['--owner-pid',str(os.getpid())],calls='culrp')
        # Cancellation while the library's API is stuck must reap only our child.
        pidfile=folder/(arch+'-cancel.pid')
        env=dict(os.environ,HALLIDAY_FAKE_STEAM_MODE='hang',HALLIDAY_FAKE_STEAM_PID=str(pidfile))
        p=subprocess.Popen(prefix+['--library',str(full),'--timeout-ms','3000'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
        deadline=time.monotonic()+2
        while not pidfile.exists() and time.monotonic()<deadline:time.sleep(.005)
        assert pidfile.exists(),'fake API was not reached'
        p.send_signal(signal.SIGTERM);stdout,stderr=p.communicate(timeout=2)
        assert p.returncode==143,(arch,p.returncode,stdout,stderr)
        try:os.kill(int(pidfile.read_text()),0)
        except ProcessLookupError:pass
        else:raise AssertionError('probe child survived cancellation')
        results.append({'arch':arch,'case':'cancel-reaps-owned-probe','passed':True,'exit':p.returncode})
        # Losing Halliday while waiting must not launch a game later, even if
        # the old PID is eventually reused by another process.
        owner=subprocess.Popen(['/bin/sleep','10'])
        pidfile=folder/(arch+'-owner-loss.pid')
        env=dict(os.environ,HALLIDAY_FAKE_STEAM_MODE='hang',HALLIDAY_FAKE_STEAM_PID=str(pidfile))
        p=subprocess.Popen(prefix+['--library',str(full),'--owner-pid',str(owner.pid),'--timeout-ms','3000'],
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
        deadline=time.monotonic()+2
        while not pidfile.exists() and time.monotonic()<deadline:time.sleep(.005)
        assert pidfile.exists(),'owner-loss fixture did not reach the fake API'
        owner.terminate();owner.wait(timeout=1);stdout,stderr=p.communicate(timeout=2)
        assert p.returncode==70 and 'launch owner closed' in stderr,(arch,p.returncode,stdout,stderr)
        if pidfile.exists():
            try:os.kill(int(pidfile.read_text()),0)
            except ProcessLookupError:pass
            else:raise AssertionError('probe child survived owner loss')
        results.append({'arch':arch,'case':'owner-loss-reaps-probe','passed':True,'exit':p.returncode})
(OUT/'results.json').write_text(json.dumps({'passed':True,'real_steam_loaded':False,'games_started':False,'cases':results},indent=2)+'\n')
print('PASS:',len(results),'native Steam gate cases; real Steam never loaded')
