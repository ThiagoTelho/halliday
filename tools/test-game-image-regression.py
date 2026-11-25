#!/usr/bin/env python3
"""Compare real compositor images in private app identities; never alter user settings."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', type=Path, required=True)
p.add_argument('--candidate', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
output = a.output.resolve()
assert output.is_relative_to(ROOT/'build/validation') and not output.exists()
output.mkdir(parents=True)
stage = Path(tempfile.mkdtemp(prefix='halliday-image-regression-', dir='/private/tmp'))
report = {'passed': False, 'scope': __doc__, 'sources': {}, 'cases': {}}
identities = []
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
try:
    for label, source in [('baseline', a.baseline), ('candidate', a.candidate)]:
        source = source.resolve(strict=True)
        info = plistlib.loads((source/'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'].startswith('app.halliday.Halliday')
        nonce = uuid.uuid4().hex
        identity = 'app.halliday.Halliday.image-audit.'+nonce
        folder = 'Halliday Image Audit '+nonce
        support = Path.home()/'Library/Application Support'/folder
        preferences = Path.home()/'Library/Preferences'/(identity+'.plist')
        log = Path.home()/'Library/Logs'/(folder+'.log')
        assert not any(path.exists() for path in [support, preferences, log])
        identities.append((identity, support, preferences, log))
        target = stage/(label+'.app')
        subprocess.run(['ditto','--noextattr','--noqtn',str(source),str(target)],check=True,capture_output=True)
        report['sources'][label] = {'path': str(source), 'version': info['CFBundleVersion'],
            'executable_sha256': sha(source/'Contents/MacOS/halliday')}
        info['CFBundleIdentifier'] = identity
        info['HallidayRuntimeFolderName'] = folder
        (target/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['xattr','-cr',str(target)],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--deep','--sign','-',str(target)],check=True,capture_output=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(target)],check=True,capture_output=True)
        result = subprocess.run(['python3',str(ROOT/'tools/test-game-image-preview.py'),
            '--app',str(target),'--output',str(output/label)],capture_output=True,timeout=300)
        (output/(label+'.log')).write_bytes(result.stdout+result.stderr)
        assert result.returncode == 0, label+' compositor fixture failed'
    baseline = json.loads((output/'baseline/results.json').read_text())['cases']
    candidate = json.loads((output/'candidate/results.json').read_text())['cases']
    assert baseline.keys() == candidate.keys() and len(baseline) == 11
    for name, before in baseline.items():
        after = candidate[name]
        pngs = sorted((output/'baseline').glob(name+'*.png'))
        # The exact case file and its new-frame companion are written by the fixture.
        pngs = [path for path in pngs if path.name in (name+'.png',name+'-new-frame.png')]
        assert len(pngs) == 2, 'Missing captured images: '+name
        row = {'fingerprints_equal': before['fingerprints_fnv1a64'] == after['fingerprints_fnv1a64'],
            'config_equal': before['config'] == after['config'],
            'dimensions_equal': before['dimensions'] == after['dimensions'],
            'pngs_equal': all(path.read_bytes() == (output/'candidate'/path.name).read_bytes() for path in pngs)}
        report['cases'][name] = row
        assert all(row.values()), 'Image regression: '+name
    report['passed'] = True
except Exception as error:
    report['error'] = str(error)
finally:
    for identity, support, preferences, log in identities:
        subprocess.run(['defaults','delete',identity],capture_output=True)
        preferences.unlink(missing_ok=True)
        log.unlink(missing_ok=True)
        if support.exists(): shutil.rmtree(support)
    shutil.rmtree(stage)
    report['private_fixture_cleanup'] = True
    report['source_executables_unchanged'] = all(sha(Path(item['path'])/'Contents/MacOS/halliday') == item['executable_sha256']
        for item in report['sources'].values())
    (output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'passed': report['passed'], 'cases': len(report['cases']), 'error': report.get('error')},indent=2))
raise SystemExit(0 if report['passed'] else 1)
