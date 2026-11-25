#!/usr/bin/env python3
"""Explicit disposable-bottle benchmark; registry selection is restored in finally.

This never accepts a normal CrossOver bottle. GPU work is limited to uniform
512/1024-pixel eye textures, nominal 72 Hz, without games or video encoders.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--wine", type=Path, required=True)
parser.add_argument("--bottle", type=Path, required=True)
parser.add_argument("--helper", type=Path, required=True)
parser.add_argument("--loader", type=Path, required=True)
parser.add_argument("--exe", type=Path, required=True)
parser.add_argument("--baseline", type=Path, required=True, help="immutable directory with runtime DLL + manifest")
parser.add_argument("--candidate", type=Path, help="optional candidate directory; requires private counters")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--api", choices=("d3d11", "d3d12", "both"), default="both")
parser.add_argument("--rounds", type=int, choices=(1, 2), default=1, help="2 uses ABBA order for a paired comparison")
args = parser.parse_args()
prefix = args.bottle.resolve()
if not any(prefix.is_relative_to(parent) for parent in (ROOT / "build/validation", ROOT / "windows-openxr/build/tests")):
    parser.error("--bottle must be an explicit disposable prefix inside this repository's build/tests or build/validation")
if not (prefix / "cxbottle.conf").is_file():
    parser.error("the disposable CrossOver bottle does not exist")
if not args.output.resolve().is_relative_to(ROOT / "build"):
    parser.error("--output must stay in this repository's build directory")
args.output.mkdir(parents=True, exist_ok=True)
winpath = lambda path: "Z:" + str(path.resolve()).replace("/", "\\")
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
snapshot = ROOT / "windows-openxr/build/tests" / ("transfer-benchmark-" + uuid.uuid4().hex)
snapshot.mkdir()
shutil.copy2(args.exe, snapshot / "runtime_transfer_benchmark.exe")
exe = snapshot / "runtime_transfer_benchmark.exe"
env = dict(os.environ)
for key in ("CX_ROOT", "CX_BOTTLE", "WINEPREFIX", "WINEDLLPATH", "CX_APPLEGPTK_LIBD3DSHARED_PATH",
            "CX_ACTIVE_GRAPHICS_BACKEND", "CX_GRAPHICS_BACKEND_VERSION", "CX_LOG", "CX_DEBUGMSG",
            "XR_RUNTIME_JSON", "XR_RUNTIME_JSON_64", "HALLIDAY_EXPERIMENTAL_D3D12"):
    env.pop(key, None)
env["WINEDEBUG"] = "-all"
report = {"metric": "CPU wall time inside xrEndFrame, including GPU readback and shared-file publication",
          "excludes": "game render time, video encoding, headset/display latency",
          "bottle": str(prefix), "snapshot": str(snapshot), "exe_sha256": sha(exe),
          "configuration_sha256": sha(prefix / "cxbottle.conf"), "operations": [], "runs": [], "passed": False}
receipt = args.output / "results.json"


def save():
    receipt.write_text(json.dumps(report, indent=2))


def execute(label, arguments, input_bytes=None):
    started = time.monotonic()
    process = subprocess.run([str(args.wine), "--bottle", str(prefix), "--no-update"] + arguments,
                             input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=90)
    stdout = process.stdout.decode("utf8", errors="replace")
    stderr = process.stderr.decode("utf8", errors="replace")
    (args.output / (label + ".stdout.log")).write_text(stdout)
    (args.output / (label + ".stderr.log")).write_text(stderr)
    item = {"label": label, "exit_code": process.returncode, "seconds": round(time.monotonic() - started, 3)}
    report["operations"].append(item)
    save()
    if process.returncode:
        raise RuntimeError(label + ": " + stdout[-1500:] + stderr[-1500:])
    return stdout


def registry(label, operation, data=None):
    return json.loads(execute(label, [str(args.helper)] + operation, data))


def file_identity(path):
    b = path.read_bytes()
    pe = struct.unpack_from("<I", b, 0x3c)[0]
    stamp = struct.unpack_from("<I", b, pe + 8)[0]
    image = struct.unpack_from("<I", b, pe + 24 + 56)[0]
    optional = struct.unpack_from("<H", b, pe + 20)[0]
    for i in range(struct.unpack_from("<H", b, pe + 6)[0]):
        at = pe + 24 + optional + i * 40
        if b[at:at + 8].split(b"\0")[0] == b".text":
            size, _, raw_size, raw_at = struct.unpack_from("<IIII", b, at + 8)
            code = b[raw_at:raw_at + min(size, raw_size)] + bytes(max(0, size - raw_size))
            value = 14695981039346656037
            for byte in code:
                value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
            return [f"{stamp:08x}", f"{image:08x}", f"{size:08x}", f"{value:016x}"]
    raise RuntimeError("no .text section in " + str(path))


engine = args.wine.resolve().parent.parent
providers = {}
for api in (11, 12):
    for name, folder in (("Apple D3DMetal 4", "apple_gptk/wine"), ("Apple D3DMetal 3", "apple_gptk3/wine"),
                         ("DXMT", "dxmt"), ("DXVK", "dxvk"), ("Wine builtin", "wine")):
        path = engine / "lib" / folder / "x86_64-windows" / f"d3d{api}.dll"
        if path.is_file():
            providers[(api, tuple(file_identity(path)))] = name

variants = [("baseline", args.baseline.resolve())]
if args.candidate:
    variants.append(("candidate", args.candidate.resolve()))
if args.rounds == 2:
    variants = variants + list(reversed(variants))
apis = ["d3d11", "d3d12"] if args.api == "both" else [args.api]
original = installed = None
try:
    original = registry("registry-before", ["query"])
    report["original_registry"] = original
    for number, (variant, source) in enumerate(variants):
        frozen = snapshot / (str(number) + "-" + variant)
        frozen.mkdir()
        for name in ("halliday_openxr.dll", "halliday_openxr.json"):
            shutil.copy2(source / name, frozen / name)
        manifest = frozen / "halliday_openxr.json"
        raw = (winpath(manifest) + "\0").encode("utf-16-le")
        installed = {"present": True, "type": 1, "data": raw.hex()}
        assert registry(f"registry-install-{number}", ["write", "1"], raw.hex().encode()) == installed
        for api in apis:
            label = f"{number}-{variant}-{api}"
            fixture = snapshot / (label + ".shm")
            command = ["--start", str(exe), winpath(args.loader), winpath(frozen / "halliday_openxr.dll"), winpath(fixture), api]
            if variant == "candidate":
                command.append("--require-stats")
            stdout = execute(label, command)
            assert "PASS:" in stdout, label + " has no successful final marker"
            phases = [json.loads(line[7:]) for line in stdout.splitlines() if line.startswith("RESULT ")]
            assert len(phases) == 4, label + " has incomplete phase data"
            matches = re.search(r"PROVIDER d3d\d+.dll stamp=(\w+) image=(\w+) text_bytes=(\w+) text_fnv64=(\w+)", stdout)
            assert matches, label + " did not identify the loaded graphics provider"
            fingerprint = list(matches.groups())
            provider = providers.get((int(api[3:]), tuple(fingerprint)), "unmatched")
            assert provider == "Apple D3DMetal 4", label + " used unexpected or unproved graphics provider: " + provider
            teardowns = [json.loads(line[9:]) for line in stdout.splitlines() if line.startswith("TEARDOWN ")]
            report["runs"].append({"label": label, "variant": variant, "api": api, "runtime_sha256": sha(frozen / "halliday_openxr.dll"),
                                   "provider": provider, "provider_fingerprint": fingerprint, "phases": phases, "teardowns": teardowns})
            save()
            print(label + ": PASS", flush=True)
    report["passed"] = True
except Exception as error:
    report["error"] = str(error)
    print("FAIL:", error, flush=True)
finally:
    if original is not None and installed is not None:
        try:
            current = registry("registry-before-restore", ["query"])
            assert current == installed or current == original, "unexpected external registry change; refusing to overwrite it"
            if current != original:
                if original["present"]:
                    current = registry("registry-restore", ["write", str(original["type"])], original["data"].encode())
                else:
                    current = registry("registry-restore", ["delete"])
            report["registry_restored"] = current == original
            assert report["registry_restored"], "previous registry value was not restored"
        except Exception as error:
            report["passed"] = False
            report["restore_error"] = str(error)
    report["configuration_unchanged"] = sha(prefix / "cxbottle.conf") == report["configuration_sha256"]
    report["passed"] &= report["configuration_unchanged"]
    save()
print("Final:", "PASS" if report["passed"] else "FAIL", flush=True)
raise SystemExit(0 if report["passed"] else 1)
