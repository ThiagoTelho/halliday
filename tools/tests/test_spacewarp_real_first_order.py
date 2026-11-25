#!/usr/bin/env python3
"""CPU source contract: real scene completion must not include flow preparation.

This checks production wiring, not GPU duration, image quality, or headset latency.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
text = (ROOT / "app/Sources/Halliday/Renderer.swift").read_text()


def section(start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


source = section("case .source(let reset):", "case .predict(let phase):")
commit = section("private func commitSceneAndPrepareSpacewarp(", "private struct GameImageKey:")
normal = section("func render(head: HeadPose, calibration: [Float], into target:", "private func drawScene(")
latched = section("func renderLatched(", "func makePresentationLens(")
reset = section("private func resetSpacewarp()", "private func spacewarpProjection(")

checks = {
    "source_records_owned_texture_and_exact_metadata": all(s in source for s in (
        "PendingSpacewarpSource(processor: processor", "texture: original.texture",
        "sequence: original.imageSequence", "descriptor: descriptor")),
    "no_flow_preparation_in_real_scene_encoding": ".prepare(" not in source,
    "real_commit_precedes_separate_flow_encoding_and_commit":
        commit.index("scene.commit()") < commit.index("queue.makeCommandBuffer()")
        < commit.index("processor.prepare(") < commit.index("flow.commit()"),
    "pending_consumed_once_and_checked_against_current_source": all(s in commit for s in (
        "pendingSpacewarpSource = nil", "spacewarpSourcePose?.sequence == pending.sequence",
        "processor === pending.processor", "Settings.shared.gameSpacewarpEnabled")),
    "reset_cancels_unsubmitted_source": "pendingSpacewarpSource = nil" in reset,
    "both_real_render_paths_use_real_first_commit":
        normal.count("commitSceneAndPrepareSpacewarp(cb)") == 1
        and latched.count("commitSceneAndPrepareSpacewarp(cb)") == 1
        and "cb.commit()" not in normal and "cb.commit()" not in latched,
    "latched_lens_completion_registered_before_real_commit":
        latched.index("cb.addCompletedHandler") < latched.index("commitSceneAndPrepareSpacewarp(cb)"),
    "production_does_not_wait_for_flow": "waitUntilCompleted" not in commit
        and "waitUntilCompleted" not in latched,
    "synchronous_snapshot_protects_cpu_replaced_source": bool(re.search(
        r"if drawable == nil\s*\{\s*cb\.waitUntilCompleted\(\).*?flow\?\.waitUntilCompleted\(\)",
        normal, re.S)),
    "flow_alignment_rotation_only_scene_depth_unchanged":
        "reprojectionDepth: 0" in source
        and "projShift: submittedEye.map { SIMD4(projectionOrigin - $0.position, Self.reprojectionDepth) }" in text,
}
presenter = (ROOT / "app/Sources/Halliday/IndependentLensPresenter.swift").read_text()
checks["prediction_result_bound_to_completed_scene_sequence"] = all(value in presenter for value in (
    "predictionGuard.sequence == nativeSequence", "!predictionGuard.hasPredictionAfterGPUCompletion", "value.generated = false"))
checks["renderer_binds_ticket_without_waiting"] = all(value in text for value in (
    "scenePredictionGuard = processor.currentPredictionGuard", "predictionGuard: scenePredictionGuard", "completedScene.ending(at: cb.gpuEndTime)"))
result = {"scope": "CPU production source-order contract; no GPU, game, or headset measurement",
          "checks": checks, "passed": all(checks.values())}
if len(sys.argv) > 1:
    Path(sys.argv[1]).write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
raise SystemExit(0 if result["passed"] else 1)
