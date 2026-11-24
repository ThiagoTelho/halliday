#!/usr/bin/env python3
"""Reproduce Halliday's native Metal port of AMD Optical Flow 1.1.2 (SDK1.1.4).

Only AMD's MIT shader sources are used, never FrameGen/OFXR composition code.
Run with glslc (shaderc/glslang) and SPIRV-Cross; no Windows compiler is needed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import shlex
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REVISION = "c6efa6bf7f2027b3ec94f28578bb5965eabb9e55"
SDK = ROOT / "build/deps/FidelityFX-SDK-v1.1.4"
OUT = ROOT / "app/Resources/amd-optical-flow"
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--sdk", type=Path, default=SDK)
p.add_argument("--glslc", default=shutil.which("glslc") or "/opt/homebrew/bin/glslc")
p.add_argument("--spirv-cross", default=str(ROOT / "build/deps/spirv-cross/spirv-cross"))
p.add_argument("--fetch", action="store_true", help="Fetch original AMD GPU headers/passes at the pinned revision")
a = p.parse_args()
if a.fetch:
    url = f"https://api.github.com/repos/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/git/trees/{REVISION}?recursive=1"
    tree = json.load(urllib.request.urlopen(url, timeout=30))
    assert tree["sha"] == REVISION
    for item in tree["tree"]:
        path = item["path"]
        if item["type"] != "blob" or not (
            path.startswith("sdk/include/FidelityFX/gpu/") and path.endswith(".h")
            or "/dx12/shaders/opticalflow/" in path
        ):
            continue
        target = a.sdk / path
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(urllib.request.urlopen(
                f"https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/{REVISION}/{path}", timeout=30).read())
        assert hashlib.sha1(b"blob " + str(target.stat().st_size).encode() + b"\0" + target.read_bytes()).hexdigest() == item["sha"], path

include = a.sdk / "sdk/include/FidelityFX/gpu"
passes = a.sdk / "sdk/src/backends/dx12/shaders/opticalflow"
assert include.is_dir() and len(list(passes.glob("*.hlsl"))) == 7, "Pass --fetch or supply the original AMD SDKv1.1.4 folder"
OUT.mkdir(parents=True, exist_ok=True)
work = ROOT / "build/deps/amd-of-spv"
work.mkdir(parents=True, exist_ok=True)
notice = (include / "opticalflow/ffx_opticalflow_common.h").read_text().split("#if", 1)[0].strip()
(OUT / "LICENSE-AMD.txt").write_text("\n".join(line[3:] if line.startswith("// ") else "" if line == "//" else line for line in notice.splitlines()).strip() + "\n")
manifest = {"repository": "https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK", "revision": REVISION,
            "sdk_tag": "v1.1.4", "effect_version": "1.1.2", "msl_version": "3.2", "passes": []}
headers = set()
for source in sorted(passes.glob("*.hlsl")):
    name = source.stem.removeprefix("ffx_opticalflow_").removesuffix("_pass").replace("_pass_v5", "_v5")
    spirv = work / (source.stem + ".spv")
    compile_args = [a.glslc, "-x", "hlsl", "-fshader-stage=compute", "-fentry-point=CS", "--target-env=vulkan1.1",
                    "-I" + str(include), "-DFFX_GPU=1", "-DFFX_HLSL=1", "-DFFX_HALF=0", "-O", str(source), "-o", str(spirv)]
    subprocess.run(compile_args, check=True)
    dependencies = subprocess.check_output(compile_args[:-2] + ["-M"], text=True)
    for path in shlex.split(dependencies.split(":", 1)[1].replace("\\\n", " ")):
        if path.endswith(".h"):
            headers.add(Path(path))
    metal = subprocess.check_output([a.spirv_cross, str(spirv), "--msl", "--msl-version", "32000"], text=True)
    target = OUT / (name + ".metal")
    target.write_text(notice + "\n// Generated from AMD SDKv1.1.4; see SOURCE.md.\n" + metal)
    manifest["passes"].append({"name": name, "hlsl": str(source.relative_to(a.sdk)),
        "hlsl_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "metal_sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
    (work / (name + ".json")).write_text(subprocess.check_output([a.spirv_cross, str(spirv), "--reflect"], text=True))
manifest["gpu_header_sha256"] = {str(path.relative_to(a.sdk)): hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in sorted(headers)}
(OUT / "PROVENANCE.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Generated seven authentic AMD Metal passes; MIT license and pinned provenance retained.")
