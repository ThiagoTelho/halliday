#!/usr/bin/env python3
"""Offline provenance/notice verification for the seven translated AMD shaders."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
folder = root / "app/Resources/amd-optical-flow"
manifest = json.loads((folder / "PROVENANCE.json").read_text())
assert manifest["revision"] == "c6efa6bf7f2027b3ec94f28578bb5965eabb9e55"
assert manifest["sdk_tag"] == "v1.1.4" and manifest["effect_version"] == "1.1.2"
assert manifest["msl_version"] == "3.2"
expected = {"prepare_luma", "compute_luminance_pyramid", "generate_scd_histogram",
            "compute_scd_divergence", "compute_optical_flow_advanced_v5",
            "filter_optical_flow_v5", "scale_optical_flow_advanced_v5"}
assert {entry["name"] for entry in manifest["passes"]} == expected
assert len(manifest["passes"]) == 7
notice = (folder / "LICENSE-AMD.txt").read_text()
assert "Advanced Micro Devices" in notice and "Permission is hereby granted" in notice
for entry in manifest["passes"]:
    data = (folder / (entry["name"] + ".metal")).read_bytes()
    assert hashlib.sha256(data).hexdigest() == entry["metal_sha256"], entry["name"]
    text = data.decode()
    assert "Copyright (C) 2024 Advanced Micro Devices" in text
    assert "Permission is hereby granted" in text and "THE SOFTWARE IS PROVIDED" in text
    assert len(entry["hlsl_sha256"]) == 64 and entry["hlsl"].startswith("sdk/src/backends/dx12/shaders/opticalflow/")
assert manifest["gpu_header_sha256"] and all(len(value) == 64 for value in manifest["gpu_header_sha256"].values())
print("PASS: seven AMD Metal output hashes, pinned Optical Flow 1.1.2 / SDK 1.1.4 provenance and retained MIT notices (offline)")
