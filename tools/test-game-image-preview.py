#!/usr/bin/env python3
"""Bounded synthetic frames through the actual app compositor; no game or headset."""
import argparse
import json
import pathlib
import subprocess
from isolated_app_fixture import IsolatedAppFixture, new_validation_output, fixture_environment

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--unseen-surroundings', action='store_true', help='Also verify hidden Dusk/mesh/video work and returning home')
parser.add_argument('--run', action='store_true', help='Explicitly execute this offscreen GPU acceptance oracle')
args = parser.parse_args()
if not args.run:
    parser.error('No app/GPU was started; add --run to execute the owned offscreen oracle.')
try:
    output = new_validation_output(root, args.output)
except ValueError as error:
    parser.error(str(error))
with IsolatedAppFixture(args.app, 'game-image-acceptance', 'Halliday Image Acceptance',
                        '--game-image-render-snapshot') as fixture:
    exe = fixture.app / 'Contents/MacOS/halliday'
    environment = fixture_environment()
    cases = {}
    receipt = {'passed': False, 'scope': __doc__, 'cases': cases, 'checks': {}, 'fixture_identity': fixture.identity, 'source_sha256': fixture.source_sha256}

    def save():
        (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')

    def run(name, fsr, rcas, percent=80, extra=()):
        command = [str(exe), '--game-image-render-snapshot', str(output / (name + '.png')),
                   '--game-image-input-percent', str(percent),
                   '-gameSpacewarpEnabled', 'NO', '-gameFSREnabled', 'YES' if fsr else 'NO',
                   '-gameSharpeningEnabled', 'YES' if rcas else 'NO',
                   '-gameRenderPercent', str(percent), '-gameSharpness', '0.6', *extra]
        if args.unseen_surroundings:
            command.append('--game-image-unseen-surroundings')
        result = subprocess.run(command, env=environment, capture_output=True, timeout=45)
        (output / (name + '.log')).write_bytes(result.stdout + result.stderr)
        assert result.returncode == 0, f'{name} failed: {result.stderr.decode(errors="replace")[-1000:]}'
        case = json.loads((output / (name + '.json')).read_text())
        assert case['config']['fsr'] == fsr and case['config']['rcas'] == rcas
        assert case['config']['render_percent_setting'] == percent
        assert abs(case['config']['sharpness'] - 0.6) < 1e-5
        assert all(case['checks'][key] for key in (
            'cached_replay_exact', 'new_sequence_updates_image', 'source_projection_restored'))
        if args.unseen_surroundings:
            surroundings = case['surroundings_checks']
            assert all(surroundings[key] for key in ('hidden_projection_pixels_exact', 'video_hidden_work_zero',
                'home_bake_resumed', 'home_geometry_resumed'))
            assert surroundings['hidden_bakes'] == surroundings['hidden_geometry_passes'] == 0
        cases[name] = case
        save()
        return case['fingerprints_fnv1a64']['first']

    save()
    baseline = run('off80', False, False)
    fsr = run('fsr80', True, False)
    rcas = run('rcas80', False, True)
    both = run('both80', True, True)
    assert len({baseline, fsr, rcas, both}) == 4, 'Independent controls must change actual output'
    receipt['checks']['independent_effects_change_output'] = True
    full = run('off100', False, False, 100)
    assert full == run('fsr100', True, False, 100), '100% EASU-only must be a pixel-identical bypass'
    receipt['checks']['full_size_fsr_is_identity'] = True
    full_sharp = run('rcas100', False, True, 100)
    assert full_sharp != full and full_sharp == run('both100', True, True, 100)
    receipt['checks']['full_size_only_rcas_changes_output'] = True
    for colour in ('linear', 'srgb', 'mixed'):
        run('both80-flip-' + colour, True, True, extra=(
            '--game-image-flip', '--game-image-colour-mode', colour))
    receipt['checks']['flipped_and_explicit_colour_modes'] = True
    receipt['passed'] = True
    save()
    print(json.dumps({'passed': True, 'case_count': len(cases), 'checks': receipt['checks']}, indent=2))
