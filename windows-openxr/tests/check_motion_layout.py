"""Independent Rust/C/C++ ABI derivation plus the portable HLVM sequence oracle."""
import ctypes
import json
from pathlib import Path
import re
import subprocess
import sys
root=Path(__file__).resolve().parents[2]
source=(root/'core/halliday-bridge/src/motion.rs').read_text()+'\n'+(root/'core/halliday-core/src/ffi.rs').read_text()
source=re.sub(r'//[^\n]*','',source)
types={'f32':ctypes.c_float,'u8':ctypes.c_uint8,'u32':ctypes.c_uint32,'i64':ctypes.c_int64,'AtomicU32':ctypes.c_uint32}
def resolve(name):
    name=name.strip()
    if name in types:return types[name]
    if name.startswith('['):
        item,count=name[1:-1].split(';');return resolve(item)*int(count)
    body=re.search(r'pub struct '+name+r'\s*\{(.*?)\n\}',source,re.S).group(1)
    result=type(name,(ctypes.Structure,),{'_fields_':[(field,resolve(kind)) for field,kind in re.findall(r'pub (\w+):\s*([^,]+),',body)]})
    types[name]=result;return result
extension,pose,motion=map(resolve,['Extension','HallidayHeadPose','HallidayHeadPoseMotion'])
expected={'Extension':ctypes.sizeof(extension),'offset':int(re.search(r'pub const OFFSET: usize = (\d+);',source).group(1)),
 'sequence_offset':extension.state_sequence.offset,'mask_offset':extension.mask.offset,'flags_offset':extension.flags.offset,
 'head_pose':ctypes.sizeof(pose),'head_motion':ctypes.sizeof(motion),'linear_offset':motion.linear_velocity.offset,'motion_flags_offset':motion.motion_flags.offset}
actual=json.loads(subprocess.check_output([sys.argv[1]],text=True));assert actual==expected,{'Rust':expected,'C/C++':actual}
assert expected['offset']>=64608 and expected['offset']+expected['Extension']<=65536
print('PASS: independent HLVM state validity + legacy head/additive-motion C ABI',actual)
