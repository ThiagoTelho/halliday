"""Compare the optional C++ panel ABI against independently derived Rust repr(C) data."""
import ctypes
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
source = (root / 'core/halliday-bridge/src/lib.rs').read_text()
panel_source = (root / 'core/halliday-bridge/src/panels.rs').read_text()
source = re.sub(r'//[^\n]*', '', source)
panel_source = re.sub(r'//[^\n]*', '', panel_source)
types = {'f32': ctypes.c_float, 'u32': ctypes.c_uint32, 'i32': ctypes.c_int32,
         'u64': ctypes.c_uint64, 'u8': ctypes.c_uint8,
         'AtomicU32': ctypes.c_uint32, 'AtomicU64': ctypes.c_uint64}
constants = {'SLOTS': 3, 'OVERLAYS': 8, 'PRESENT_RING': 16}

def resolve(name):
    name = name.strip()
    if name in types:
        return types[name]
    if name.startswith('['):
        depth = 0
        for i, char in enumerate(name[1:-1], 1):
            if char == '[': depth += 1
            if char == ']': depth -= 1
            if char == ';' and depth == 0:
                count = name[i+1:-1].strip()
                return resolve(name[1:i]) * (constants[count] if count in constants else int(count))
        raise AssertionError(name)
    body = re.search(r'pub struct '+name+r'\s*\{(.*?)\n\}', panel_source if name == 'Panel' else source, re.S).group(1)
    fields = re.findall(r'pub (\w+):\s*([^,]+),', body)
    assert fields, name
    result = type(name, (ctypes.Structure,), {'_fields_': [(field, resolve(kind)) for field, kind in fields]})
    types[name] = result
    return result

panel, header, picture = resolve('Panel'), resolve('Header'), resolve('Picture')
focus_source=(root/'core/halliday-bridge/src/focus.rs').read_text()
focus_body=re.search(r'pub struct Extension\s*\{(.*?)\n\}',re.sub(r'//[^\n]*','',focus_source),re.S).group(1)
focus=type('Focus',(ctypes.Structure,),{'_fields_':[(field,resolve(kind)) for field,kind in re.findall(r'pub (\w+):\s*([^,]+),',focus_body)]})
batch_bytes = 32 + 8 * ctypes.sizeof(panel)
expected = {'Panel': ctypes.sizeof(panel), 'Batch': batch_bytes, 'Extension': 16 + 3*batch_bytes,
            'Picture': ctypes.sizeof(picture),
            'panel_offset': int(re.search(r'pub const OFFSET: usize = (\d+);', panel_source).group(1)),
            'picture_metadata_offset': header.overlay_pictures.offset,
            'width_m': panel.width_m.offset, 'eye_visibility': panel.eye_visibility.offset,
            'anchor': panel.anchor.offset}
expected.update(Focus=ctypes.sizeof(focus),focus_offset=int(re.search(r'pub const OFFSET: usize = (\d+);',focus_source).group(1)),
    focus_state=focus.state.offset,focus_producer=focus.producer_epoch.offset,focus_requests=focus.requests.offset)
actual = json.loads(subprocess.check_output([sys.argv[1]], text=True))
assert actual == expected, {'Rust': expected, 'C++': actual}
assert actual['panel_offset'] + actual['Extension'] <= 65536
print('PASS: independent Rust/C++ panel/picture ABI, offsets, atomic batch sizes and reserved-header bounds', actual)
