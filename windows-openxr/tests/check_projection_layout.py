"""Independently derive the Rust HLPG layout and compare with C++ and public C DTOs."""
import ctypes
import json
from pathlib import Path
import re
import subprocess
import sys

root=Path(__file__).resolve().parents[2]
source=re.sub(r'//[^\n]*','',(root/'core/halliday-bridge/src/projection.rs').read_text())
types={'f32':ctypes.c_float,'u32':ctypes.c_uint32,'u64':ctypes.c_uint64,'AtomicU32':ctypes.c_uint32,'AtomicU64':ctypes.c_uint64}
constants={'SLOTS':3,'WORDS':int(re.search(r'const WORDS: usize = (\d+);',source).group(1))}
def resolve(name):
    name=name.strip()
    if name in types:return types[name]
    if name.startswith('['):
        depth=0
        for i,c in enumerate(name[1:-1],1):
            if c=='[':depth+=1
            if c==']':depth-=1
            if c==';' and depth==0:
                count=name[i+1:-1].strip();return resolve(name[1:i])*(constants[count] if count in constants else int(count))
        raise AssertionError(name)
    body=re.search(r'pub struct '+name+r'\s*\{(.*?)\n\}',source,re.S).group(1)
    fields=re.findall(r'pub (\w+):\s*([^,]+),',body)
    assert fields,name
    result=type(name,(ctypes.Structure,),{'_fields_':[(field,resolve(kind)) for field,kind in fields]});types[name]=result;return result
view,record,extension,snapshot=map(resolve,['View','Record','Extension','Snapshot'])
flag_source=(root/'core/halliday-bridge/src/lib.rs').read_text()
expected={'View':ctypes.sizeof(view),'Record':ctypes.sizeof(record),'Extension':ctypes.sizeof(extension),'Snapshot':ctypes.sizeof(snapshot),
    'offset':int(re.search(r'pub const OFFSET: usize = (\d+);',source).group(1)),
    'views_offset':record.views.offset,'records_offset':extension.records.offset,'orientation_offset':view.orientation.offset,
    'tangents_offset':view.tangents.offset,'required_frame_flag':1<<int(re.search(r'pub const FRAME_PROJECTION_GEOMETRY: u32 = 1 << (\d+);',flag_source).group(1)),
    'c_view':ctypes.sizeof(view),'c_geometry':ctypes.sizeof(snapshot)}
actual=json.loads(subprocess.check_output([sys.argv[1]],text=True));assert actual==expected,{'Rust':expected,'C++/C':actual}
assert expected['offset']+expected['Extension']==64608 and expected['offset']+expected['Extension']<=65536
print('PASS: independent Rust/C++/C projection geometry ABI and reserved-header bounds',actual)
