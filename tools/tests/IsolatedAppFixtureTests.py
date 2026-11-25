"""CPU-only staging policy tests with inert app bytes and mocked signing/tools."""
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from isolated_app_fixture import IsolatedAppFixture, new_validation_output

class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='halliday-fixture-policy-')
        self.root = Path(self.temp.name)
        self.home = self.root/'synthetic-home'
        self.source = self.root/'Halliday.app'
        (self.source/'Contents/MacOS').mkdir(parents=True)
        self.executable = self.source/'Contents/MacOS/halliday'
        self.executable.write_bytes(b'inert fixture --game-image-render-snapshot')
        self.info = {'CFBundleIdentifier':'app.halliday.Halliday', 'CFBundleExecutable':'halliday',
                     'CFBundleVersion':'1.2.3', 'SUEnableAutomaticChecks':True, 'SUAllowsAutomaticUpdates':True}
        self.plist = self.source/'Contents/Info.plist'
        self.plist.write_bytes(plistlib.dumps(self.info))
        self.before = self.plist.read_bytes()
        self.calls = []
    def tearDown(self):
        self.temp.cleanup()
    def runner(self, args, **kwargs):
        self.calls.append(args)
        if args[0] == 'ditto':
            shutil.copytree(args[-2], args[-1], symlinks=True)
        return subprocess.CompletedProcess(args, 0, b'', b'')
    def fixture(self, **kwargs):
        return IsolatedAppFixture(self.source, 'image-policy', 'Halliday Test', '--game-image-render-snapshot',
                                  user_home=self.home, runner=kwargs.get('runner', self.runner))
    def test_owned_identity_cleanup_preserves_source_and_unrelated_state(self):
        unrelated = self.home/'Library/Application Support/Real app/save'
        unrelated.parent.mkdir(parents=True);unrelated.write_text('keep')
        with self.fixture() as f:
            clone = plistlib.loads((f.app/'Contents/Info.plist').read_bytes())
            self.assertTrue(f.identity.startswith('app.halliday.tests.image-policy.'))
            self.assertEqual(clone['CFBundleIdentifier'], f.identity)
            self.assertEqual(clone['HallidayRuntimeFolderName'], f.name)
            self.assertFalse(clone['SUEnableAutomaticChecks'] or clone['SUAllowsAutomaticUpdates'])
            self.assertEqual(clone['CFBundleVersion'], '1.2.3')
            f.support.mkdir(parents=True);(f.support/'owned').write_text('test')
            for p in [f.preferences, f.log]:p.parent.mkdir(parents=True, exist_ok=True);p.write_text('owned')
            staged = f.temporary
        self.assertFalse(staged.exists() or f.support.exists() or f.preferences.exists() or f.log.exists())
        self.assertEqual(self.plist.read_bytes(), self.before)
        self.assertEqual(unrelated.read_text(), 'keep')
        self.assertEqual([c for c in self.calls if c[0]=='defaults'], [['defaults','delete',f.identity]])
        f.close();self.assertEqual(len([c for c in self.calls if c[0]=='defaults']), 1)
    def test_failed_signing_cleans_only_new_staging(self):
        paths=[]
        def fail(args, **kw):
            if args[0]=='ditto': paths.append(Path(args[-1]).parent)
            if args[0]=='codesign':raise subprocess.CalledProcessError(1,args)
            return self.runner(args,**kw)
        with self.assertRaises(subprocess.CalledProcessError):
            with self.fixture(runner=fail):pass
        self.assertTrue(paths and all(not p.exists() for p in paths))
        self.assertEqual(self.plist.read_bytes(), self.before)
    def test_missing_entrypoint_fails_before_tool_calls(self):
        self.executable.write_bytes(b'inert older app')
        with self.assertRaises(ValueError):self.fixture()
        self.assertEqual(self.calls, [])
    def test_source_executable_symlink_rejected(self):
        actual=self.root/'other';self.executable.rename(actual);self.executable.symlink_to(actual)
        with self.assertRaises(ValueError):self.fixture()
    def test_wrong_identity_rejected(self):
        self.plist.write_bytes(plistlib.dumps(dict(self.info,CFBundleIdentifier='com.example.other')))
        with self.assertRaises(ValueError):self.fixture()
    def test_namespace_and_title_cannot_escape(self):
        for namespace,title in [('../bad','test'),('good','../bad')]:
            with self.assertRaises(ValueError):
                IsolatedAppFixture(self.source,namespace,title,'--game-image-render-snapshot',user_home=self.home,runner=self.runner)
    def test_output_requires_new_owned_directory(self):
        output=new_validation_output(self.root,self.root/'build/validation/case')
        self.assertTrue(output.is_dir())
        for p in [output, self.root/'build/validation', self.root/'outside']:
            with self.assertRaises(ValueError):new_validation_output(self.root,p)
    def test_output_symlink_escape_rejected(self):
        parent=self.root/'build/validation';parent.mkdir(parents=True)
        outside=self.root/'outside';outside.mkdir();(parent/'alias').symlink_to(outside,target_is_directory=True)
        with self.assertRaises(ValueError):new_validation_output(self.root,parent/'alias/new')

if __name__=='__main__':unittest.main()
