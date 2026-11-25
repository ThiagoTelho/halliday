#!/usr/bin/env python3
"""Bounded actual Spacewarp compositor GPU correctness; no games or headset."""
import argparse
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--full', action='store_true', help='Also check a2016x2048-per-eye source')
args = parser.parse_args()
output = args.output.resolve()
assert output.is_relative_to(root / 'build/validation') and not output.exists()
output.mkdir(parents=True)
exe = args.app.resolve() / 'Contents/MacOS/halliday'
receipt = {'passed': False, 'scope': __doc__, 'cases': {}}

def save():
    (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')

def run(name, fsr, rcas, full=False):
    command = [str(exe), '--game-spacewarp-render-snapshot', str(output / (name + '.png')),
               '-gameSpacewarpEnabled', 'YES', '-gameHalfFrameRate', 'YES',
               '-gameFSREnabled', 'YES' if fsr else 'NO',
               '-gameSharpeningEnabled', 'YES' if rcas else 'NO', '-gameSharpness', '0.6']
    if full:
        command.append('--game-spacewarp-full')
    completed = subprocess.run(command, capture_output=True, timeout=90)
    (output / (name + '.log')).write_bytes(completed.stdout + completed.stderr)
    assert completed.returncode == 0, f'{name}: {completed.stderr.decode(errors="replace")[-2000:]}'
    report = json.loads((output / (name + '.json')).read_text())
    assert report['config']['fsr'] == fsr and report['config']['rcas'] == rcas
    assert report['config']['input_per_eye'] == ([2016, 2048] if full else [512, 512])
    assert report['measured_window_counters'] == {'source': 2, 'generated': 1}
    assert all(report['checks'].values())
    centers = report['marker_centroids']
    assert centers['generated'][0] > centers['real2'][0]
    assert centers['generated'][1] < centers['real2'][1]
    receipt['cases'][name] = report
    save()

save()
run('spacewarp512', False, False)
run('spacewarp512-fsr-rcas', True, True)
if args.full:
    run('spacewarp-full', False, False, full=True)
receipt['passed'] = True
save()
print(json.dumps({'passed': True, 'cases': list(receipt['cases']), 'scope': __doc__}, indent=2))
