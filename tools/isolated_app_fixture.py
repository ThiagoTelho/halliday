"""Owned application staging for explicit offscreen acceptance runners only.

Copies a built app; never modifies or launches the source bundle. Each staging
gets a new bundle/defaults/support identity, and cleanup is limited to that UUID.
"""
from pathlib import Path
import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile
import uuid


def new_validation_output(repository, requested):
    root = (Path(repository) / 'build/validation').resolve()
    output = Path(requested).resolve()
    if output == root or not output.is_relative_to(root) or output.exists() or output.is_symlink():
        raise ValueError('Output must be a new child of repository build/validation.')
    output.mkdir(parents=True)
    return output


class IsolatedAppFixture:
    def __init__(self, source, namespace, title, entrypoint, *, user_home=None, runner=subprocess.run):
        self.source = Path(source).resolve(strict=True)
        self.runner = runner
        self.token = uuid.uuid4().hex
        self.identity = 'app.halliday.tests.' + namespace + '.' + self.token
        self.name = title + ' ' + self.token
        self.home = Path(user_home).resolve() if user_home else Path.home().resolve()
        self.support = self.home / 'Library/Application Support' / self.name
        self.log = self.home / 'Library/Logs' / (self.name + '.log')
        self.preferences = self.home / 'Library/Preferences' / (self.identity + '.plist')
        self.temporary = None
        self.app = None
        self.staged = False
        if not title or '/' in title or '\n' in title or title in {'.', '..'}:
            raise ValueError('Invalid fixture title.')
        if not namespace or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in namespace):
            raise ValueError('Invalid fixture namespace.')
        info_path = self.source / 'Contents/Info.plist'
        if not info_path.is_file() or info_path.is_symlink():
            raise ValueError('Expected an ordinary Halliday app bundle.')
        self.info = plistlib.loads(info_path.read_bytes())
        if not self.info.get('CFBundleIdentifier', '').startswith('app.halliday.') or self.info.get('CFBundleExecutable') != 'halliday':
            raise ValueError('Expected a built Halliday application.')
        executable = self.source / 'Contents/MacOS/halliday'
        if not executable.is_file() or executable.is_symlink() or executable.stat().st_size > 256 * 1024 * 1024:
            raise ValueError('Invalid source executable.')
        image = executable.read_bytes()
        if entrypoint.encode() not in image:
            raise ValueError('Source app does not contain the required snapshot entry point.')
        self.source_sha256 = hashlib.sha256(image).hexdigest()
        for path in [self.support, self.log, self.preferences]:
            if path.exists() or path.is_symlink():
                raise ValueError('Refusing an existing fixture identity.')

    def __enter__(self):
        self.temporary = Path(tempfile.mkdtemp(prefix='halliday-owned-' + self.token + '-', dir='/private/tmp'))
        self.app = self.temporary / 'Halliday Fixture.app'
        try:
            self.runner(['ditto', '--noextattr', '--noqtn', str(self.source), str(self.app)], check=True, capture_output=True, timeout=60)
            info = dict(self.info, CFBundleIdentifier=self.identity, HallidayRuntimeFolderName=self.name,
                        SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False)
            (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            self.runner(['xattr', '-cr', str(self.app)], check=True, capture_output=True, timeout=15)
            self.runner(['codesign', '--force', '--deep', '--sign', '-', str(self.app)], check=True, capture_output=True, timeout=45)
            self.runner(['codesign', '--verify', '--deep', '--strict', str(self.app)], check=True, capture_output=True, timeout=30)
            self.staged = True
            return self
        except BaseException:
            self.close()
            raise

    def close(self):
        # The only application defaults domain touched is this newly generated UUID.
        if self.staged:
            self.runner(['defaults', 'delete', self.identity], capture_output=True, timeout=10)
        for path in [self.preferences, self.log]:
            if path.exists() or path.is_symlink():
                path.unlink()
        if self.support.is_symlink():
            self.support.unlink()
        elif self.support.exists():
            shutil.rmtree(self.support)
        if self.temporary and self.temporary.name.startswith('halliday-owned-' + self.token + '-'):
            shutil.rmtree(self.temporary, ignore_errors=True)
        self.staged = False

    def __exit__(self, *_):
        self.close()


def fixture_environment():
    return {key: value for key, value in os.environ.items()
            if not key.startswith(('MOLTENVR_', 'XR_', 'DYLD_', 'WINE', 'CX_BOTTLE', 'HALLIDAY_'))
            and key not in {'EYE_RES', 'VB_FPS'}}
