"""Independently derive the Rust repr(C) prefix layout and compare the C++ ABI.

The parser fails on unfamiliar types/fields rather than silently accepting ABI
drift. It deliberately excludes Header's unused suffix after _pad2.
"""
import ctypes
import json
import re
import subprocess
import sys

source = open(sys.argv[2]).read()
source = re.sub(r"//[^\n]*", "", source)
types = {"f32": ctypes.c_float, "u32": ctypes.c_uint32, "i32": ctypes.c_int32,
         "u64": ctypes.c_uint64, "u8": ctypes.c_uint8,
         "AtomicU32": ctypes.c_uint32, "AtomicU64": ctypes.c_uint64}
constants = {"SLOTS": 3}

def resolve(name):
    name = name.strip()
    if name in types:
        return types[name]
    if name.startswith("["):
        depth = 0
        for i, character in enumerate(name[1:-1], 1):
            if character == "[": depth += 1
            if character == "]": depth -= 1
            if character == ";" and depth == 0:
                count = name[i + 1:-1].strip()
                return resolve(name[1:i]) * (constants[count] if count in constants else int(count))
        raise AssertionError("Unknown Rust array: " + name)
    body = re.search(r"pub struct " + name + r"\s*\{(.*?)\n\}", source, re.S).group(1)
    if name == "Header": body = body[:body.index("pub _pad2:")] + "pub _pad2: u32,"
    fields = re.findall(r"pub (\w+):\s*([^,]+),", body)
    assert fields, name
    result = type(name, (ctypes.Structure,), {"_fields_": [(field, resolve(kind)) for field, kind in fields]})
    types[name] = result
    return result

expected = {name: ctypes.sizeof(resolve(name)) for name in ("Pose", "Controller", "State", "Frame")}
header = resolve("Header")
for field in ("state", "client_frames", "frames", "frame_interval_ns", "client_heartbeat", "scene_seq"):
    expected[field] = getattr(header, field).offset
actual = json.loads(subprocess.check_output([sys.argv[1]], text=True))
assert actual == expected, {"Rust source": expected, "C++": actual}
assert re.search(r"pub const VERSION:\s*u32\s*=\s*6;", source), "Bridge version changed"
print("PASS: C++ bridge layout matches Rust v6 source", actual)
