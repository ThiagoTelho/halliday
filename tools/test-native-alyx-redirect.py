#!/usr/bin/env python3
"""Actual dyld interposition check using owned dummy libraries, never a game."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
parser.add_argument('--skip-build', action='store_true')
args = parser.parse_args()
if not args.skip_build:
    subprocess.run(['python3', str(root/'native-alyx/build.py')], check=True)
module = root/'build/native-alyx/bin/libhalliday_alyx_redirect.dylib'
subprocess.run(['lipo', str(module), '-verify_arch', args.arch], check=True)
with tempfile.TemporaryDirectory(prefix='halliday-alyx-redirect-', dir='/private/tmp') as temp:
    folder = Path(temp)
    (folder/'marker.c').write_text('int halliday_redirect_marker(void) { return 73; }\n')
    (folder/'probe.cpp').write_text('''#include <dlfcn.h>
int main(int argc,char** argv) {
 if(argc!=2) return 4;
 void* h=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if(!h) return 2;
 auto marker=(int(*)())dlsym(h,"halliday_redirect_marker");
 return marker&&marker()==73?0:3;
}\n''')
    selected = folder/"selected library's fixture.dylib"
    probe = folder/'probe'
    subprocess.run(['xcrun','clang','-arch',args.arch,'-dynamiclib',str(folder/'marker.c'),'-o',str(selected)],check=True)
    subprocess.run(['xcrun','clang++','-arch',args.arch,str(folder/'probe.cpp'),'-o',str(probe)],check=True)
    home = folder/'synthetic home'
    original = home/'Library/Application Support/MoltenVR/bin/libmoltenvr_openxr.dylib'
    env = dict(os.environ, HOME=str(home), HALLIDAY_NATIVE_OPENXR_RUNTIME=str(selected),
               DYLD_INSERT_LIBRARIES=str(module))
    def check(path, expected):
        result=subprocess.run([str(probe),str(path)],env=env)
        assert result.returncode==expected,(path,result.returncode,expected)
    check(original,0)
    check(selected,0)
    check('/usr/lib/libSystem.B.dylib',3)
    check(folder/'other/Library/Application Support/MoltenVR/bin/libmoltenvr_openxr.dylib',2)
    env['HALLIDAY_NATIVE_OPENXR_RUNTIME']=str(folder/'missing.dylib')
    check(original,2)
    env.pop('HALLIDAY_NATIVE_OPENXR_RUNTIME')
    check(original,2)
print(f'PASS ({args.arch}): exact native Alyx runtime redirect; unrelated libraries, lookalike paths and missing targets remain untouched')
