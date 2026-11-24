#!/usr/bin/env python3
"""Check the shared game-host configuration in an isolated fixture app, without games."""
import argparse
import json
import pathlib
import plistlib
import signal
import struct
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
app, output = args.app.resolve(), args.output.resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
# Require a deliberately isolated fixture bundle, never the installed app.
assert info['CFBundleIdentifier'].startswith('app.halliday.tests.')
assert info['HallidayRuntimeFolderName'].startswith('Halliday Fixture ')
assert output.is_relative_to(root / 'build/validation') and not output.exists()
support = pathlib.Path.home() / 'Library/Application Support' / info['HallidayRuntimeFolderName'] / 'OpenVR'
bridge = support / 'halliday-bridge.shm'
assert not bridge.exists(), 'The fixture needs a new, unused runtime support folder'
output.mkdir(parents=True)
receipt = {'passed': False, 'scope': __doc__, 'cases': []}

def save():
    (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')

save()
for percent, per_eye, half_rate in [(100, (2016, 2048), False),
                                   (80, (1600, 1632), False),
                                   (100, (2016, 2048), True),
                                   (80, (1600, 1632), True)]:
    process = None
    try:
        with (output / f'launch-{percent}-half-{int(half_rate)}.log').open('wb') as log:
            process = subprocess.Popen([str(app / 'Contents/MacOS/halliday'),
                '--no-activate', '--no-companion', '--no-sense', '--ignore-headset',
                '-gameRenderPercent', str(percent), '-gameHalfFrameRate', 'YES' if half_rate else 'NO',
                '-gameFSREnabled', 'NO',
                '-gameSharpeningEnabled', 'NO'], stdout=log, stderr=log)
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                assert process.poll() is None, 'Preview exited during host startup'
                if bridge.exists() and bridge.stat().st_size >= 20:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('Shared game host did not start')
            with (support / 'halliday-bridge.shm').open('rb') as file:
                header = file.read(20)
                openvr = struct.unpack_from('<II', header, 8)
                openvr_hz = struct.unpack_from('<f', header, 16)[0]
            assert openvr == per_eye, (percent, 'shared OpenVR/OpenXR geometry', openvr)
            # Desktop fixtures use the host's 90 Hz fallback; physical rate switching
            # and actual xrWaitFrame notifications are checked by separate fixtures.
            game_hz = 45 if half_rate else 90
            assert openvr_hz == game_hz, (percent, half_rate, 'OpenVR', openvr_hz)
            process.send_signal(signal.SIGTERM)
            assert process.wait(timeout=15) == 0, 'Preview failed normal shutdown'
            receipt['cases'].append({'render_percent': percent, 'half_frame_rate': half_rate,
                'physical_display_hz': 90, 'negotiated_game_hz': game_hz, 'shared_config_per_eye': openvr,
                'normal_exit': True})
            save()
    finally:
        if process and process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        save()
receipt['passed'] = True
save()
print(json.dumps(receipt, indent=2))
