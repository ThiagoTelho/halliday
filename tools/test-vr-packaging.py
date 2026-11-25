#!/usr/bin/env python3
"""CPU-only packaging policy fixtures with fake build products/tools; no app is launched.

These verify metadata, optional-module composition, failure boundaries and toolchain
selection. They do not claim to validate Mach-O code, real signatures or rendering.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]

MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys, zipfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'ditto':
    source, target = map(pathlib.Path, args[-2:])
    if '-c' in args:
        with zipfile.ZipFile(target, 'w') as out:
            for path in source.rglob('*'):
                if path.is_file(): out.write(path, path.relative_to(source.parent))
    else:
        shutil.copytree(source, target)
elif name == 'xcrun':
    if args[:3] == ['--sdk', 'macosx', '--show-sdk-path']:
        print('/fixture/sdk')
    elif args[0] == 'lipo' and '-create' in args:
        pathlib.Path(args[args.index('-output') + 1]).write_bytes(b'fixture universal library')
    elif args[:2] == ['lipo', '-archs']:
        print('arm64')
    elif args[:2] == ['otool', '-L']:
        print('@rpath/libMoltenVK.dylib (compatibility version 1.0.0)')
elif name == 'cargo':
    with open(os.environ['FIXTURE_CARGO_LOG'], 'a') as log:
        log.write(json.dumps({'args': args, 'CARGO_HOME': os.environ.get('CARGO_HOME'),
                             'RUSTUP_HOME': os.environ.get('RUSTUP_HOME'),
                             'DEVELOPER_DIR': os.environ.get('DEVELOPER_DIR')}) + '\n')
    target = args[args.index('--target') + 1]
    root = pathlib.Path(args[args.index('--target-dir') + 1])
    output = root / target / 'release/libhalliday_openxr.dylib'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(b'fixture thin library')
# codesign and xattr intentionally do nothing for these inert fixture bytes.
'''


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='halliday-package-fixture-')
        self.root = Path(self.temp.name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        for name in ['package-crossover-preview.sh', 'build-independent-native-openxr.sh']:
            shutil.copy2(ROOT / 'tools' / name, self.tools / name)
        self.bin = self.root / 'fixture-bin'
        self.bin.mkdir()
        for name in ['ditto', 'xcrun', 'codesign', 'xattr', 'cargo']:
            path = self.bin / name
            path.write_text(MOCK_TOOL)
            path.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('HALLIDAY_PACKAGE_', 'HALLIDAY_DEV_'))}
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env['PATH'],
                        FIXTURE_CARGO_LOG=str(self.root / 'cargo.jsonl'))
        self.plist = {'CFBundleName': 'Halliday', 'CFBundleDisplayName': 'Halliday',
                      'CFBundleIdentifier': 'app.halliday.Halliday', 'CFBundleVersion': '1.2.3',
                      'CFBundleShortVersionString': '1.2', 'SUFeedURL': 'https://example.invalid/appcast',
                      'SUEnableAutomaticChecks': True, 'SUAllowsAutomaticUpdates': True,
                      'SUPublicEDKey': 'fixture-signing-key'}
        self.write('build/Halliday.app/Contents/Info.plist', plistlib.dumps(self.plist))
        self.write('build/Halliday.app/Contents/MacOS/halliday', 'not an executable app')
        self.write('app/Halliday-dev.entitlements', 'fixture')

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, value='fixture', executable=False):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else value.encode())
        if executable:
            path.chmod(0o755)
        return path

    def package(self, **overrides):
        environment = dict(self.env, **overrides)
        return subprocess.run(['bash', str(self.tools/'package-crossover-preview.sh'), str(self.root/'artifact.zip')],
                              env=environment, capture_output=True, text=True, timeout=20)

    def archive(self, name='Halliday'):
        with zipfile.ZipFile(self.root/'artifact.zip') as archive:
            return {path[len(name)+5:]: archive.read(path) for path in archive.namelist()
                    if path.startswith(name+'.app/')}

    def metadata(self, name='Halliday'):
        return plistlib.loads(self.archive(name)['Contents/Info.plist'])

    def modules(self):
        for name in ['halliday_openxr.dll', 'halliday_openxr.json']:
            self.write('windows-openxr/build/windows/bin/'+name)
        self.write('build/halliday-xr-registry.exe')
        for name in ['LICENSE-BasaltVR', 'LICENSE-Khronos-MIT', 'LICENSE-Khronos-Vulkan-MIT', 'LICENSE-LLVM-MinGW']:
            self.write('windows-openxr/'+name)
        for name in ['halliday_openxr_router.dll', 'halliday_openxr_router.json', 'vrclient_x64.dll', 'LICENSE-nlohmann-json']:
            self.write('build/router-openxr/bin/'+name)
        for name in ['libhalliday_openxr.dylib', 'halliday_native_openxr.json']:
            self.write('build/independent-native-openxr/'+name)

    def test_ordinary_metadata_and_updater_are_unchanged(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.metadata(), self.plist)
        self.assertFalse(any('OpenXR/' in path for path in self.archive()))

    def test_development_overrides_are_explicit(self):
        result = self.package(HALLIDAY_PACKAGE_DEVELOPMENT='1', HALLIDAY_DEV_NAME='Example Preview',
                              HALLIDAY_DEV_BUNDLE_ID='app.example.preview', HALLIDAY_DEV_VERSION='1.2.3.4')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = self.metadata('Example Preview')
        self.assertEqual(value['CFBundleIdentifier'], 'app.example.preview')
        self.assertEqual(value['CFBundleVersion'], '1.2.3.4')
        self.assertEqual(value['HallidayRuntimeFolderName'], 'Example Preview')
        self.assertNotIn('SUFeedURL', value)
        self.assertFalse(value['SUEnableAutomaticChecks'])
        self.assertEqual(value['SUPublicEDKey'], self.plist['SUPublicEDKey'])

    def test_all_public_runtime_modules_and_licenses_are_included(self):
        self.modules()
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = self.archive()
        for file in ['WindowsOpenXR/halliday_openxr.dll', 'AutomaticOpenXR/vrclient_x64.dll',
                     'NativeOpenXR/libhalliday_openxr.dylib', 'NativeOpenXR/halliday_native_openxr.json',
                     'Licenses/nlohmann-json-MIT.txt', 'Licenses/OpenXR-Headers-MIT.txt',
                     'Licenses/Vulkan-Headers-MIT.txt']:
            self.assertIn('Contents/Resources/'+file, files)
        self.assertEqual(self.metadata(), self.plist)

    def test_native_module_contains_only_runtime_and_loader_manifest(self):
        self.modules()
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = self.archive()
        native = {path.removeprefix('Contents/Resources/NativeOpenXR/') for path in files
                  if path.startswith('Contents/Resources/NativeOpenXR/')}
        self.assertEqual(native, {'libhalliday_openxr.dylib', 'halliday_native_openxr.json'})
        self.assertFalse(any('NativeAlyx/' in path for path in files))

    def test_explicitly_required_missing_group_fails(self):
        result = self.package(HALLIDAY_PACKAGE_WINDOWS='yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing or invalid module file', result.stderr)
        self.assertFalse((self.root/'artifact.zip').exists())

    def test_partial_build_fails(self):
        self.write('windows-openxr/build/windows/bin/halliday_openxr.dll')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing or invalid module file', result.stderr)

    def test_disabled_groups_do_not_inherit_stale_base_modules(self):
        self.modules()
        self.write('build/Halliday.app/Contents/Resources/WindowsOpenXR/stale.dll')
        result = self.package(HALLIDAY_PACKAGE_WINDOWS='no', HALLIDAY_PACKAGE_ROUTER='no', HALLIDAY_PACKAGE_NATIVE='no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any('OpenXR/' in path for path in self.archive()))

    def test_old_private_payload_is_rejected(self):
        self.write('build/Halliday.app/Contents/Resources/NativeMoltenOpenXR/libmoltenvr_stock.dylib')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Refusing an old private runtime payload', result.stderr)
        self.assertFalse((self.root/'artifact.zip').exists())

    def native_build(self, offline='0'):
        self.write('core/Cargo.toml', '[workspace]')
        environment = dict(self.env, CARGO_HOME=str(self.root/'ordinary-cargo'),
                           RUSTUP_HOME=str(self.root/'ordinary-rustup'), CARGO_TARGET_DIR='custom-target',
                           DEVELOPER_DIR='/fixture/developer', HALLIDAY_CARGO_OFFLINE=offline)
        result = subprocess.run(['bash', str(self.tools/'build-independent-native-openxr.sh')],
                                env=environment, capture_output=True, text=True, timeout=20)
        return result, environment

    def test_native_build_respects_toolchain_and_target_dir(self):
        result, environment = self.native_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.root/'cargo.jsonl').read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        for call in calls:
            for key in ['CARGO_HOME', 'RUSTUP_HOME', 'DEVELOPER_DIR']:
                self.assertEqual(call[key], environment[key])
            self.assertNotIn('--offline', call['args'])
            self.assertEqual(call['args'][call['args'].index('--target-dir')+1], str(self.root/'custom-target'))
        self.assertTrue((self.root/'build/independent-native-openxr/libhalliday_openxr.dylib').is_file())

    def test_native_offline_is_opt_in(self):
        result, _ = self.native_build('1')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.root/'cargo.jsonl').read_text().splitlines()]
        self.assertTrue(all('--offline' in call['args'] for call in calls))


if __name__ == '__main__':
    unittest.main(verbosity=2)
