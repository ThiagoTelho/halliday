#!/usr/bin/env python3
"""Official Windows loader test. Registry changes are limited to a disposable project bottle.

The ActiveRuntime value is journalled, read back, and restored even when a test fails. The
runner refuses existing user bottles outside the project's ignored test directories. It never
launches a game. First initialize a disposable bottle; this script does not create/upgrade one.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import uuid


def windows_path(path):
    return "Z:" + str(path).replace("/", "\\")


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bottle", type=Path, default=repo / "windows-openxr/build/tests/crossover-runtime-smoke")
    parser.add_argument("--crossover", type=Path, default=Path("/Applications/CrossOver.app"))
    parser.add_argument("--run", action="store_true", help="Explicitly execute Wine in the marked disposable test bottle")
    args = parser.parse_args()
    if not args.run:
        parser.error("No Wine command was started; use --run with a marked disposable test bottle.")
    bottle = args.bottle.resolve(strict=True)
    allowed = [repo / "windows-openxr/build/tests", repo / "build/validation"]
    if not any(bottle.is_relative_to(root.resolve()) for root in allowed) or not (bottle / "cxbottle.conf").is_file():
        parser.error("Only a newly created disposable bottle inside this project's test directories is allowed")
    marker = bottle / ".halliday-disposable-openxr-test"
    if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 64 or marker.read_bytes() != b"halliday-openxr-disposable-v1\n":
        parser.error("The disposable bottle must carry the explicit fixture ownership marker.")
    wine = args.crossover / "Contents/SharedSupport/CrossOver/bin/wine"
    helper = repo / "build/halliday-xr-registry.exe"
    smoke = repo / "build/openxr-loader-smoke/bin/openxr-loader-smoke.exe"
    manifest = repo / "windows-openxr/build/windows/bin/halliday_openxr.json"
    for file in [wine, helper, smoke, manifest]:
        if not file.is_file():
            parser.error(f"Missing required test artifact: {file}")
    nonce = uuid.uuid4().hex[:12]
    output = repo / "build/tests" / f"official-loader-{nonce}"
    output.mkdir(parents=True)
    environment = os.environ.copy()
    for key in ["CX_LOG", "WINEPREFIX", "CX_BOTTLE", "XR_RUNTIME_JSON"]:
        environment.pop(key, None)
    environment["CX_DEBUGMSG"] = "-all"
    environment["WINEDEBUG"] = "-all"
    command = [str(wine), "--bottle", str(bottle), "--no-update", "--no-gui",
               "--env", "CX_GRAPHICS_BACKEND=d3dmetal"]
    invocation = 0

    def invoke(arguments, data=None):
        nonlocal invocation
        invocation += 1
        result = subprocess.run(command + list(map(str, arguments)), input=data,
                                capture_output=True, env=environment, timeout=60)
        (output / f"{invocation:02d}.log").write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Isolated test command failed ({result.returncode}); see {output / f'{invocation:02d}.log'}")
        return result.stdout

    def registry(arguments, data=None):
        raw = invoke([helper] + arguments, data)
        responses = []
        for line in raw.decode("utf-8", errors="replace").splitlines():
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "present" in value:
                responses.append(value)
        if not responses:
            raise RuntimeError(f"Missing registry helper response; see {output}")
        return responses[-1]

    original = registry(["query"])
    (output / "registry-before.json").write_text(json.dumps(original, indent=2) + "\n")
    installed = {"present": True, "type": 1, "data": (windows_path(manifest) + "\0").encode("utf-16-le").hex()}
    (output / "registry-installed.json").write_text(json.dumps(installed, indent=2) + "\n")
    bridge_paths = []
    try:
        actual = registry(["write", "1"], installed["data"].encode())
        if actual != installed:
            raise RuntimeError("Disposable runtime registration did not match its readback")
        for with_host in [False, True]:
            bridge = repo / "windows-openxr/build/tests" / f"official-loader-{nonce}-{'host' if with_host else 'absent'}.shm"
            if bridge.exists():
                raise RuntimeError("Refusing an existing bridge fixture")
            bridge_paths.append(bridge)
            options = [smoke, windows_path(manifest), windows_path(bridge)]
            if with_host:
                options.append("--with-host")
            raw = invoke(options)
            print(raw.decode("utf-8", errors="replace").strip())
    finally:
        # Refuse to overwrite a third party change, even in this disposable fixture.
        current = registry(["query"])
        if current == installed:
            if original["present"]:
                restored = registry(["write", str(original["type"])], original["data"].encode())
            else:
                restored = registry(["delete"])
            if restored != original:
                raise RuntimeError(f"Registry restore mismatch; original receipt is in {output}")
        elif current != original:
            raise RuntimeError(f"Disposable registry changed independently; original receipt is in {output}")
        for bridge in bridge_paths:
            if bridge.exists():
                bridge.unlink()
    print(f"PASS: original disposable-bottle ActiveRuntime restored exactly; logs: {output}")


if __name__ == "__main__":
    main()
