#!/usr/bin/env python3
"""Run the actual CLI selection policy on inert scripts; no game/runtime is loaded."""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / 'native-alyx/halliday-alyx-bridge'
known_hash = '54724892ee8000399257c1a6e12679885a01f87f41c6f7b5ca7a8766f0fb9aab'
wrapper = source.read_text()
assert wrapper.count(known_hash) == 1
with tempfile.TemporaryDirectory(prefix='halliday-native-wrapper-') as td:
    folder = Path(td)
    original_dir = folder / "port with spaces ' and literal $ paths"
    original_dir.mkdir()
    original = original_dir / 'original-reader'
    original.write_text('#!/bin/bash\nprintf "original\\n"\nprintf "%s\\n" "$@"\n')
    original.chmod(0o755)
    (original_dir / 'libMoltenVK.dylib').write_bytes(b'inert public-driver placeholder')
    runtime = folder / 'inert-selected-runtime.dylib'
    runtime.write_bytes(b'inert runtime placeholder; never dlopened')
    (folder / 'libhalliday_alyx_redirect.dylib').write_bytes(b'inert redirect placeholder; shell interpreter ignores DYLD injection')
    reader = folder / 'halliday-native-frame-bridge'
    reader.write_text('#!/bin/bash\nprintf "coherent\\n"\nprintf "%s\\n" "$@"\n')
    reader.chmod(0o755)
    probe = folder / 'halliday-alyx-bridge'
    args = ['--literal', "a b '$HOME' *"]
    env = dict(os.environ, HALLIDAY_ALYX_ORIGINAL_BRIDGE=str(original), HALLIDAY_NATIVE_OPENXR_RUNTIME=str(runtime))
    def run(expected, code=0):
        result = subprocess.run(['/bin/bash', str(probe), *args], env=env, text=True, capture_output=True, timeout=3)
        assert result.returncode == code, (result.returncode, result.stderr)
        if code == 0:
            assert result.stdout.splitlines() == [expected, *args], result.stdout
        return result
    # Unmodified production allowlist must retain an unknown port's original reader.
    probe.write_text(wrapper)
    run('original')
    # Only the fixture's known identity is substituted to exercise the guarded branch.
    fixture_hash = hashlib.sha256(original.read_bytes()).hexdigest()
    probe.write_text(wrapper.replace(known_hash, fixture_hash))
    run('coherent')
    reader.rename(folder/'held-reader')
    run('original')
    reader.symlink_to(folder/'held-reader')
    result = run('', 1)
    assert 'invalid' in result.stderr
    reader.unlink()
    (folder/'held-reader').rename(reader)
    (original_dir/'libMoltenVK.dylib').unlink()
    result = run('', 1)
    assert 'no Vulkan loader' in result.stderr
    # Original bridge symlinks are deliberately outside the verified ABI allowlist.
    link = original_dir/'symlink-reader'
    link.symlink_to(original)
    env['HALLIDAY_ALYX_ORIGINAL_BRIDGE'] = str(link)
    run('original')
print('PASS 6 native reader-selection cases; unknown ABI/symlink originals retain their reader; invalid optional reader fails; arguments preserved')
