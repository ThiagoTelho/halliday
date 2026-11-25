"""Source contract checks supplement executed policy/cadence scenarios."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
bridge = (root / "app/Sources/Halliday/GameBridge.swift").read_text()
app = (root / "app/Sources/Halliday/AppDelegate.swift").read_text()
renderer = (root / "app/Sources/Halliday/Renderer.swift").read_text()
settings = (root / "app/Sources/Halliday/Settings.swift").read_text()
tick = bridge[bridge.index("func tick(head:"):bridge.index("private var lastScene:")]
assert tick.index("updateAutoFrameRate(") < tick.index("halliday_bridge_publish_frame_with_controller_frames(")
policy = bridge[bridge.index("private func updateAutoFrameRate("):bridge.index("/// Changes only the game's wake cadence")]
for gate in ["frames: client.frames", "producerState.revision", "!dashboardShown", "!paused", "!suspended", "&& projection", "supportsLiveDisplayRate", "consumerBlocked: consumerBlocked"]:
    assert gate in policy, gate
assert "physicalHz: Double(frameCadence.physicalHz)" in policy
assert "setHalfFrameRateMode(" not in policy  # direct live actuator fixture keeps its override
assert "game.setHalfFrameRateMode(Settings.shared.gameHalfFrameRateMode)" in app
assert "lastScene?.0.grid ?? 0" in policy and "lastScene?.0.suspended ?? 0" in policy
finish = bridge[bridge.index("private func finishPresentation()"):bridge.index("/// Asks the active runtime to quit")]
assert "if dashboardShown { setDashboard(false) }" in finish
assert "dashboardShown = false" not in finish
assert "dashboardShown = shown" in bridge and "autoFrameRate.resetProducer()" in bridge
assert "autoCadenceEligible: onHeadset" in app and "status?.worn == true" in app
assert "allowImageAcquisition: renderer.sceneImageAcquisitionAllowed" in app
assert "consumerBlocked: !allowImageAcquisition" in tick
assert app.count("game.halfFrameRate != game.requestedHalfFrameRate") == 2
assert "original.gameHalfRate" in renderer
assert "mode == .on || gameSpacewarpEnabled" not in settings
print("PASS source publication order, eligibility, effective cadence, FG gating and no recreation reset")
