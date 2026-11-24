#!/usr/bin/env python3
"""CPU source-boundary guard; no app, native events, graphics or HID calls."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
app = (root / "app/Sources/Halliday/AppDelegate.swift").read_text()
bridge = (root / "app/Sources/Halliday/GameBridge.swift").read_text()
alignment = (root / "app/Sources/Halliday/GameControllerAlignment.swift").read_text()
native = (root / "core/halliday-openxr/src/session.rs").read_text()
windows = (root / "windows-openxr/src/control.cpp").read_text()
space = (root / "windows-openxr/src/space.cpp").read_text()

assert app.count("poseFrame: .senseAim") == 1
assert "orientation: GameControllerAlignment.senseOrientation(senseAim(hand, sensePredicted(state)), pointerMountRadians: senseTilt[hand] ?? SenseAimDefaults.tilt)" in " ".join(app.split())
assert "senseGameMountDegrees: Float = 50.2703 + 39 - 39.4" in alignment
assert "var poseFrame: GameControllerPoseFrame = .legacy" in bridge
assert "var controllerFrames = [GameControllerPoseFrame.legacy, .legacy]" in bridge
assert "let hand = i == 1 ? 0 : 1" in bridge
assert "controllerFrames[i] = real.poseFrame" in bridge
assert "controllerFrames[0].rawValue, controllerFrames[1].rawValue" in bridge
assert "controller_frames: bridge::controller_frames::LEGACY" in native
assert "controller_action_pose(sample, hand, source.kinds[hand].unwrap())" in native
assert "controller_action_pose(sample, hand, part)" in native
assert "sample.controllerFrames" in windows and "gHaveLocalOrigin,mask,frames" in windows.replace(" ", "")
assert "Target::OpenXrGrip,out.poseInLocal" in windows
assert "Target::OpenXrAim,out.aimPoseInLocal" in windows
assert space.count("aim ? input.controllers[hand].aimPoseInLocal : input.controllers[hand].poseInLocal") == 3
print("PASS: only physical Sense source is declared; existing host pose/pointer preserved; left/right mapping explicit; mouse/legacy default; cached native+Windows declarations feed separate grip/aim and application-offset motion")
