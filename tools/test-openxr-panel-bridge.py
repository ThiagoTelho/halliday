#!/usr/bin/env python3
"""Explicit GPU bridge-to-compositor oracle in a new, disposable app identity.

The source app is copied/read-only; no installed app or normal defaults domain is
modified. Requires a built public panel producer. This runner opens no headset.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
from isolated_app_fixture import IsolatedAppFixture, new_validation_output, fixture_environment

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, required=True)
p.add_argument('--producer', type=Path, default=ROOT/'core/target/release/examples/openxr-panel-producer')
p.add_argument('--output', type=Path, required=True)
p.add_argument('--torn-batch-repro', action='store_true')
p.add_argument('--display-hz', type=int, choices=[90, 120], default=90)
p.add_argument('--run', action='store_true', help='Explicitly execute this offscreen GPU acceptance oracle')
a = p.parse_args()
if not a.run:
    p.error('No app/GPU was started; add --run to execute the owned offscreen oracle.')
producer = a.producer.resolve()
if (not producer.is_file() or not os.access(producer, os.X_OK)
        or not any(producer.is_relative_to(folder) for folder in [ROOT/'core/target', ROOT/'build'])):
    p.error('Build the public openxr-panel-producer inside this repository first.')
try:
    output = new_validation_output(ROOT, a.output)
except ValueError as error:
    p.error(str(error))
process = None
report = {'passed': False, 'scope': __doc__, 'producer_sha256': hashlib.sha256(producer.read_bytes()).hexdigest()}
try:
    with IsolatedAppFixture(a.app, 'openxr-panel-acceptance', 'Halliday OpenXR Panel Acceptance',
                            '--openxr-panel-bridge-snapshot') as fixture:
        report.update(bundle=fixture.identity, app_executable_sha256=fixture.source_sha256)
        environment = fixture_environment()
        if a.torn_batch_repro:
            environment['HALLIDAY_PANEL_FIXTURE_TORN_BATCH'] = '1'
        command = [str(fixture.app/'Contents/MacOS/halliday'), '--openxr-panel-bridge-snapshot', str(output/'pixel-results.json'),
            '--panel-producer', str(producer), '--panel-display-hz', str(a.display_hz), '--copy-frames',
            '-nativeOpenXRBackend', 'halliday', '-gamesWindowsOpenXRBackend', 'halliday',
            '-gameRenderPercent', '100', '-gameHalfFrameRate', 'NO', '-gameSpacewarpEnabled', 'NO',
            '-gameFSREnabled', 'NO', '-gameSharpeningEnabled', 'NO', '-gameFloorLift', '0']
        try:
            with (output/'host.log').open('wb') as stream:
                process = subprocess.Popen(command, env=environment, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
                report['returncode'] = process.wait(timeout=45)
            if report['returncode'] != 0:
                raise RuntimeError('Integrated pixel oracle failed; inspect host.log.')
            pixels = json.loads((output/'pixel-results.json').read_text())
            if not pixels['passed'] or len(pixels['cases']) != 28:
                raise RuntimeError('Incomplete pixel-oracle results.')
            if (fixture.support/'OpenVR/halliday-bridge.shm').exists():
                raise RuntimeError('Fixture host did not release its bridge.')
            report.update(normal_bridge_cleanup=True, cases=pixels['cases'], passed=True)
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            if fixture.log.exists():
                shutil.copy2(fixture.log, output/'runtime.log')
    report['owned_fixture_cleanup'] = True
except Exception as error:
    report['error'] = str(error)
finally:
    (output/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
