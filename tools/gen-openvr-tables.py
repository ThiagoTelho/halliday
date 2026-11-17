#!/usr/bin/env python3
"""Generates core/halliday-vrclient/src/iface/tables.rs: the method tables of every OpenVR
interface version Halliday's runtime answers, in the order of Valve's openvr.h, as C++ interfaces
(a table behind an object, methods taking `this`) and as the C API's function tables
(`FnTable:IVRSystem_020`, the same methods without `this`).

Each method `IVRSystem::GetRecommendedRenderTargetSize` is the Rust function
`iface::system::get_recommended_render_target_size(this, …)`, if it exists; otherwise the slot is
a stand-in that logs its first call and returns 0. A method returning a struct takes the result
pointer after `this` (MSVC's member convention) and returns it; its C wrapper returns the struct
by value.

Needs reference/openvr (tools/fetch-reference.sh). Run from the repository root:
    tools/gen-openvr-tables.py            # writes tables.rs
    tools/gen-openvr-tables.py --check    # fails if tables.rs is out of date
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IFACE = os.path.join(ROOT, "core/halliday-vrclient/src/iface")
OUT = os.path.join(IFACE, "tables.rs")

# (interface, version, openvr tag, Rust module or None for stand-ins only)
VERSIONS = [
    ("IVRSystem", "017", "v1.0.10", "system"),
    ("IVRSystem", "019", "v1.0.12", "system"),
    ("IVRSystem", "020", "v1.7.15", "system"),
    ("IVRCompositor", "021", "v1.0.10", "compositor"),
    # 022 in v1.7.15 is 1.0.12's with three methods added at the end: one table serves both.
    ("IVRCompositor", "022", "v1.7.15", "compositor"),
    ("IVRChaperone", "003", "v1.7.15", "chaperone"),
    ("IVRSettings", "002", "v1.7.15", "settings"),
    ("IVRApplications", "006", "v1.7.15", "applications"),
    ("IVRRenderModels", "005", "v1.0.10", "render_models"),
    ("IVRRenderModels", "006", "v1.7.15", "render_models"),
    # 006 (Unreal 4's SteamVR Input plugin, the Unreal game) is 007 without GetActionBindingInfo.
    ("IVRInput", "006", "v1.4.18", "input"),
    ("IVRInput", "007", "v1.7.15", "input"),
    ("IVROverlay", "016", "v1.0.10", "overlay"),
    ("IVROverlay", "018", "v1.0.12", "overlay"),
    ("IVROverlay", "020", "v1.7.15", "overlay"),
    ("IVRChaperoneSetup", "005", "v1.0.10", None),
    ("IVRChaperoneSetup", "006", "v1.7.15", None),
    ("IVRScreenshots", "001", "v1.7.15", None),
    ("IVRExtendedDisplay", "001", "v1.7.15", "extended_display"),
    ("IVRTrackedCamera", "003", "v1.0.10", None),
    ("IVRTrackedCamera", "006", "v1.7.15", None),
    ("IVRResources", "001", "v1.7.15", None),
    ("IVRDriverManager", "001", "v1.7.15", None),
    ("IVRNotifications", "002", "v1.7.15", None),
    ("IVRIOBuffer", "002", "v1.7.15", None),
    ("IVRSpatialAnchors", "001", "v1.7.15", None),
    ("IVRDebug", "001", "v1.7.15", None),
]


def header(tag, cache={}):
    if tag not in cache:
        cache[tag] = subprocess.run(
            ["git", "-C", os.path.join(ROOT, "reference/openvr"), "show", f"{tag}:headers/openvr.h"],
            check=True, capture_output=True, text=True,
        ).stdout
    return cache[tag]


def methods(tag, cls):
    src = header(tag)
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    m = re.search(r"\bclass\s+" + cls + r"\s*\{", src)
    if not m:
        sys.exit(f"{cls} not in openvr.h {tag}")
    i, depth = m.end(), 1
    j = i
    while depth:
        depth += {"{": 1, "}": -1}.get(src[j], 0)
        j += 1
    sigs = re.findall(r"virtual\s+([^;]*?)\s*=\s*0\s*;", src[i : j - 1], re.S)
    return [re.search(r"(\w+)\s*\(", " ".join(s.split())).group(1) for s in sigs]


def snake(name):
    out = ""
    for i, c in enumerate(name):
        if c == "_":
            if not out.endswith("_"):
                out += "_"
            continue
        if c.isupper() and i > 0 and not out.endswith("_"):
            prev, nxt = name[i - 1], name[i + 1] if i + 1 < len(name) else ""
            if prev.islower() or ((prev.isupper() or prev.isdigit()) and nxt.islower()):
                out += "_"
        out += c.lower()
    return out


def split_args(s):
    parts, depth, cur = [], 0, ""
    for c in s:
        if c in "[(<":
            depth += 1
        elif c in "])>":
            depth -= 1
        if c == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += c
    if cur.strip():
        parts.append(cur.strip())
    return parts


def rust_functions(module):
    """name -> (argument types after `this`, return type or None, struct-returning?)"""
    path = os.path.join(IFACE, module + ".rs")
    src = open(path).read()
    found = {}
    for m in re.finditer(r'pub unsafe extern "C" fn (\w+)\s*\((.*?)\)\s*(?:->\s*([^{]+?))?\s*\{', src, re.S):
        name, args, ret = m.group(1), split_args(m.group(2)), (m.group(3) or "").strip() or None
        if not args or not re.match(r"_?\w*\s*:\s*This$", args[0]):
            continue
        types = [a.split(":", 1)[1].strip() for a in args[1:]]
        by_value = bool(ret and types and args[1].split(":")[0].strip() == "out" and types[0] == ret)
        found[name] = (types, ret, by_value)
    return found


def main():
    check = "--check" in sys.argv
    modules = {v[3] for v in VERSIONS if v[3]}
    funcs = {m: rust_functions(m) for m in modules}
    lines = [
        "// @generated by tools/gen-openvr-tables.py from Valve's openvr.h (v1.0.10, v1.0.12, v1.4.18, v1.7.15)",
        "// and the functions in this folder. Don't edit: change those and run the script.",
        "",
        "#![allow(clippy::all, unused_imports)]",
        "",
        "use crate::ovr::{self, *};",
        "use crate::{Iface, VTable, slot};",
        "use core::ffi::{c_char, c_void};",
        "",
    ]
    names, used = [], {m: set() for m in modules}
    # C wrappers (no `this`) for every function a table uses.
    wrappers = {m: [] for m in modules}
    tables = []
    for idx, (cls, ver, tag, module) in enumerate(VERSIONS):
        full = f"{cls}_{ver}"
        names.append(full)
        ms = methods(tag, cls)
        cxx, c = [], []
        for s, meth in enumerate(ms):
            fn = snake(meth)
            if module and fn in funcs[module]:
                used[module].add(fn)
                cxx.append(f"slot!(super::{module}::{fn})")
                c.append(f"slot!(c_{module}::{fn})")
            else:
                stand = f"slot!(crate::stand_in::<{idx}, {s}>)"
                cxx.append(stand)
                c.append(stand)
        const = re.sub(r"(?<!^)(?=[A-Z])", "_", cls[3:]).upper()
        tables.append((full, const, ver, len(ms), cxx, c))
    for full, const, ver, n, cxx, c in tables:
        lines.append(f"pub static {const}_{ver}: VTable<{n}> = VTable([")
        lines += [f"    {x}," for x in cxx]
        lines.append("]);")
        lines.append(f"pub static FN_{const}_{ver}: VTable<{n}> = VTable([")
        lines += [f"    {x}," for x in c]
        lines.append("]);")
        lines.append(f"static {const}_{ver}_OBJECT: Iface = Iface::new(&{const}_{ver});")
        lines.append("")
    for module in sorted(modules):
        lines.append(f"/// `{module}`'s methods without `this`, for the function tables.")
        lines.append(f"mod c_{module} {{")
        lines.append("    use super::*;")
        for fn in sorted(used[module]):
            types, ret, by_value = funcs[module][fn]
            if by_value:
                params = ", ".join(f"a{i}: {t}" for i, t in enumerate(types[1:]))
                call = ", ".join(["core::ptr::null_mut()", "r.as_mut_ptr()"] + [f"a{i}" for i in range(len(types) - 1)])
                value = ret.removeprefix("*mut ").strip()
                lines.append(f"    pub unsafe extern \"C\" fn {fn}({params}) -> {value} {{")
                lines.append(f"        let mut r = core::mem::MaybeUninit::<{value}>::uninit();")
                lines.append(f"        // SAFETY: the method fills its result.")
                lines.append(f"        unsafe {{ super::super::{module}::{fn}({call}); r.assume_init() }}")
                lines.append("    }")
            else:
                params = ", ".join(f"a{i}: {t}" for i, t in enumerate(types))
                call = ", ".join(["core::ptr::null_mut()"] + [f"a{i}" for i in range(len(types))])
                arrow = f" -> {ret}" if ret else ""
                lines.append(f"    pub unsafe extern \"C\" fn {fn}({params}){arrow} {{")
                lines.append(f"        // SAFETY: the caller's arguments, passed on.")
                lines.append(f"        unsafe {{ super::super::{module}::{fn}({call}) }}")
                lines.append("    }")
        lines.append("}")
        lines.append("")
    lines.append("/// Every interface version, for the stand-ins' log.")
    lines.append(f"pub const NAMES: [&str; {len(names)}] = [")
    lines += [f'    "{n}",' for n in names]
    lines.append("];")
    lines.append("")
    lines.append("/// An interface by its versioned name: a C++ object, or with `FnTable:` a C function table.")
    lines.append("pub fn lookup(name: &[u8]) -> Option<*const c_void> {")
    lines.append("    Some(match name {")
    for full, const, ver, n, cxx, c in tables:
        lines.append(f'        b"{full}" => &{const}_{ver}_OBJECT as *const Iface as *const c_void,')
        lines.append(f'        b"FnTable:{full}" => &FN_{const}_{ver} as *const VTable<{n}> as *const c_void,')
    lines.append("        _ => return None,")
    lines.append("    })")
    lines.append("}")
    text = "\n".join(lines) + "\n"
    report = []
    for full, const, ver, n, cxx, c in tables:
        stand = sum("stand_in" in x for x in cxx)
        report.append(f"{full}: {n - stand}/{n} written")
    if check:
        if open(OUT).read() != text:
            sys.exit("tables.rs is out of date: run tools/gen-openvr-tables.py")
        return
    open(OUT, "w").write(text)
    print("\n".join(report))


if __name__ == "__main__":
    main()
