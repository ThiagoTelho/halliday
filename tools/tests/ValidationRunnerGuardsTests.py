"""CPU fail-closed checks: no app, Wine, GPU, SDK download or HID is invoked."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class GuardTests(unittest.TestCase):
    def test_explicit_run_is_required_before_inputs_or_state(self):
        output = ROOT/'build/validation/guard-must-not-create'
        self.assertFalse(output.exists())
        for script, args in [
            ('tools/test-game-image-preview.py', ['--app','/nonexistent/fixture.app','--output',str(output)]),
            ('tools/test-openxr-panel-bridge.py', ['--app','/nonexistent/fixture.app','--output',str(output)]),
            ('tools/test-openxr-loader-smoke.py', []),
            ('tools/test-independent-windows-vulkan.py', []),
            ('windows-openxr/vulkan_smoke.py', []),
        ]:
            with self.subTest(script=script):
                p = subprocess.run([sys.executable,str(ROOT/script),*args],capture_output=True,text=True,timeout=5)
                self.assertEqual(p.returncode,2,p.stderr)
                self.assertIn('--run',p.stderr)
                self.assertFalse(output.exists())
    def test_paired_transfer_prepare_and_unmarked_bottle_fail_safely(self):
        parent=ROOT/'build/validation';parent.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='runner-guard-',dir=parent) as temp:
            folder=Path(temp);bottle=folder/'bottle';bottle.mkdir();(bottle/'cxbottle.conf').write_text('inert')
            client=folder/'client.exe';client.write_bytes(b'PASS: actual D3D11 automatic prior staging')
            dll=folder/'runtime.dll';dll.write_bytes(b'inert')
            output=folder/'not-created'
            args=[sys.executable,str(ROOT/'tools/test-prior-staging.py'),'--bottle',str(bottle),
                  '--client',str(client),'--dll',str(dll),'--output',str(output)]
            p=subprocess.run(args,capture_output=True,text=True,timeout=5)
            self.assertEqual(p.returncode,0,p.stderr);self.assertIn('prepared_only',p.stdout)
            self.assertFalse(output.exists())
            p=subprocess.run(args+['--run'],capture_output=True,text=True,timeout=5)
            self.assertEqual(p.returncode,2,p.stderr);self.assertIn('disposable',p.stderr)
            self.assertFalse(output.exists())
    def test_loader_build_never_fetches_a_missing_sdk(self):
        p=subprocess.run(['bash',str(ROOT/'tools/build-openxr-loader-smoke.sh'),'--sdk','/nonexistent/public-sdk'],
                         capture_output=True,text=True,timeout=5)
        self.assertEqual(p.returncode,2,p.stderr);self.assertIn('nothing is downloaded',p.stderr)

if __name__=='__main__':unittest.main()
