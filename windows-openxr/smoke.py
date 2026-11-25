#!/usr/bin/env python3
"""Run only the project's isolated CrossOver test bottle; never select a live bottle."""
import argparse
import hashlib
import json
import os
import re
import shlex
import struct
from pathlib import Path
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--abi-only", action="store_true")
parser.add_argument("--api", choices=("d3d11","d3d12"), default="d3d11")
parser.add_argument("--backend-version", help="Optional explicit CrossOver provider version; otherwise preserve its choice")
parser.add_argument("--backend", choices=("default", "d3dmetal", "dxmt", "dxvk"), default="default")
parser.add_argument("--crossover", type=Path, default=Path("/Applications/CrossOver.app"))
parser.add_argument("--runtime", type=Path, help="Explicit immutable runtime DLL for a baseline/candidate test; no registration change")
args = parser.parse_args()
if args.abi_only and args.api != "d3d11": parser.error("--abi-only uses the common D3D11 smoke executable")
tools = args.crossover / "Contents/SharedSupport/CrossOver/bin"
tests = root / "build/tests"
tests.mkdir(parents=True, exist_ok=True)
bottle = tests / "crossover-runtime-smoke"
environment = os.environ.copy()
for name in ("WINEPREFIX", "CX_BOTTLE", "CX_BOTTLE_PATH", "HALLIDAY_BRIDGE", "HALLIDAY_BRIDGE_PATH", "CX_ACTIVE_GRAPHICS_BACKEND"):
    environment.pop(name, None)
environment.update(CX_DEBUGMSG="-all", WINEDEBUG="-all", CX_LOG=str(tests / "runtime-wine.log"))
if args.backend != "default":
    environment["CX_GRAPHICS_BACKEND"] = args.backend
provider_environment = {}
if args.backend != "default": provider_environment["CX_GRAPHICS_BACKEND"] = args.backend
if args.backend_version: provider_environment["CX_GRAPHICS_BACKEND_VERSION"] = args.backend_version
(tests / "runtime-wine.log").write_text("")

def run(command, log):
    result = subprocess.run(command, env=environment, cwd=root,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=90)
    (tests / log).write_text(result.stdout)
    for line in result.stdout.splitlines():
        if "PASS:" in line or "FAIL:" in line or line.startswith("PROVIDER "): print(line)
    if result.returncode:
        print("CrossOver details:", tests / "runtime-wine.log", file=sys.stderr)
        print(result.stdout[-2000:],file=sys.stderr)
        raise SystemExit(result.returncode)
    return result.stdout

if not bottle.exists():
    run([str(tools / "cxbottle"), "--bottle", str(bottle), "--create",
         "--template", "win10_64", "--description", "Disposable Halliday OpenXR runtime test"],
        "create.stdout.log")
elif not (bottle / "user.reg").is_file():
    raise SystemExit("The disposable bottle is incomplete. Move it aside before retrying; it will not be overwritten.")


def fingerprint(path):
    data = path.read_bytes()
    nt = struct.unpack_from("<I",data,0x3c)[0]
    _,section_count,stamp,_,_,optional_size,_ = struct.unpack_from("<HHIIIHH",data,nt+4)
    image = struct.unpack_from("<I",data,nt+24+56)[0]
    for index in range(section_count):
        section = nt+24+optional_size+index*40
        if data[section:section+8].rstrip(b"\0") != b".text": continue
        virtual,_,raw_size,offset = struct.unpack_from("<IIII",data,section+8)
        hashed = 2166136261
        for byte in data[offset:offset+min(virtual,raw_size)]: hashed = ((hashed^byte)*16777619)&0xffffffff
        return tuple(f"{value:08x}" for value in (stamp,image,virtual,hashed))
    raise ValueError("Provider has no .text: " + str(path))

configuration = bottle / "cxbottle.conf"
original_configuration = configuration.read_text() if args.backend != "default" else None
runtime = (args.runtime or root / "build/windows/bin/halliday_openxr.dll").resolve(strict=True)
runtime_sha = hashlib.sha256(runtime.read_bytes()).hexdigest()
report_name = args.api + "-" + args.backend + ("-" + args.backend_version if args.backend_version else "")
output = ""
try:
    if args.backend != "default":
        # Backend selection belongs only to this script's disposable prefix.
        configuration = bottle / "cxbottle.conf"
        content = original_configuration
        match = re.search(r"(?ms)^\[EnvironmentVariables\]\s*\n(.*?)(?=^\[|\Z)", content)
        setting = '"CX_GRAPHICS_BACKEND" = "' + args.backend + '"\n'
        if match:
            section = re.sub(r'(?m)^"CX_GRAPHICS_BACKEND"\s*=.*\n?', '', match.group(1))
            content = content[:match.start(1)] + setting + section + content[match.end(1):]
        else:
            content += "\n[EnvironmentVariables]\n" + setting
        configuration.write_text(content)

    windows = lambda path: "Z:" + str(path).replace("/", "\\")
    executable = "runtime_d3d12_smoke.exe" if args.api == "d3d12" else "runtime_smoke.exe"
    command = [str(tools / "wine"), "--bottle", str(bottle), "--no-update", "--no-gui",
               "--debugmsg", "+cxcompatdb,+loaddll", "--start", str(root / "build/windows/bin" / executable),
               windows(runtime)]
    if provider_environment:
        command[1:1] = ["--env", " ".join(key + "=" + shlex.quote(value) for key,value in provider_environment.items())]

    if not args.abi_only:
        command.append(windows(tests / ("bridge-" + uuid.uuid4().hex + ".shm")))
    output = run(command, "runtime.stdout.log")
    log = (tests / "runtime-wine.log").read_text(errors="replace")
    expected = "PASS: Windows runtime ABI" if args.abi_only else "PASS: real " + args.api.upper()
    if expected not in output + log:
        raise SystemExit("The Windows child did not report a successful test; inspect " + str(tests / "runtime-wine.log"))
    for line in log.splitlines():
        if "using " in line and "graphics backend" in line or line.startswith("PROVIDER ") or expected in line:
            print(line.strip())

    report = {"passed": True,"api": args.api,"requested_backend": args.backend,
        "backend_version": args.backend_version,"physical_headset": False,
        "runtime_dll_sha256": runtime_sha,"launch_route": "CrossOver native --start",
        "provider_fingerprints": [line.strip() for line in (output+log).splitlines() if line.startswith("PROVIDER ")]}


    if not args.abi_only and args.api == "d3d11" and args.backend != "default":
        match = re.search(r"PROVIDER d3d11 timestamp=(\w+) image=(\w+) text=(\w+) hash=(\w+)",output+log)
        if not match: raise SystemExit("The child did not report a loaded D3D11 provider fingerprint.")
        engine = tools.parent / "lib"
        if args.backend == "d3dmetal":
            candidates = [engine/name/"wine/x86_64-windows/d3d11.dll" for name in ("apple_gptk","apple_gptk3")]
        else: candidates = [engine/args.backend/"x86_64-windows/d3d11.dll"]
        matching = [path for path in candidates if path.is_file() and fingerprint(path) == match.groups()]
        if not matching: raise SystemExit("The loaded graphics provider does not match the requested backend's code.")
        print("Verified provider:", matching[0])
        report["verified_provider"] = str(matching[0])
    (tests / (report_name + ".wine.log")).write_text(log)
    (tests / (report_name + ".stdout.log")).write_text(output)
    (tests / (report_name + ".json")).write_text(json.dumps(report,indent=2)+"\n")
except BaseException as failure:
    log = (tests / "runtime-wine.log").read_text(errors="replace")
    (tests / (report_name + ".wine.log")).write_text(log)
    if not output and (tests / "runtime.stdout.log").exists():
        output = (tests / "runtime.stdout.log").read_text(errors="replace")
    (tests / (report_name + ".stdout.log")).write_text(output)
    failed_report = {"passed": False,"api": args.api,"requested_backend": args.backend,
        "error": str(failure),"runtime_dll_sha256": runtime_sha,
        "launch_route": "CrossOver native --start","physical_headset": False,
        "provider_fingerprints": [line.strip() for line in (output+log).splitlines() if line.startswith("PROVIDER ")],
        "failure_lines": [line.strip() for line in (output+log).splitlines()
            if any(term in line.lower() for term in ("fail:","geometryshader","requested feature level"))]}
    match = re.search(r"PROVIDER d3d11 timestamp=(\w+) image=(\w+) text=(\w+) hash=(\w+)",output+log)
    if match and args.backend in ("dxmt","dxvk"):
        candidate = tools.parent / "lib" / args.backend / "x86_64-windows/d3d11.dll"
        failed_report["provider_routing_verified"] = candidate.exists() and fingerprint(candidate) == match.groups()
        failed_report["provider_candidate"] = str(candidate)
    (tests / (report_name + ".json")).write_text(json.dumps(failed_report,indent=2)+"\n")
    raise
finally:
    if original_configuration is not None: configuration.write_text(original_configuration)
