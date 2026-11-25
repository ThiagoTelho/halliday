#!/usr/bin/env python3
"""Check that the tested cadence policy remains wired to real source delivery."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
bridge = (root / 'app/Sources/Halliday/GameBridge.swift').read_text()
host = (root / 'app/Sources/Halliday/AppDelegate.swift').read_text()
assert 'updateAutoFrameRate(b, now: now, hostEligible: autoCadenceEligible)' in bridge
assert 'autoFrameRate.observe(now: now, frames: client.frames' in bridge
assert 'autoFrameRate.setMode(mode)' in bridge
assert 'autoFrameRate.resetProducer()' in bridge
assert 'consumerBlocked: reading' in bridge
assert '!paused && !dashboardShown && !suspended' in bridge
assert 'setHalfFrameRateMode(Settings.shared.gameHalfFrameRateMode)' in host
assert 'autoCadenceEligible: onHeadset' in host
assert 'usb?.headset.status?.worn == true' in host
print('PASS: live mode, real producer throughput, pause/loading/focus, capture blocking and physical-headset eligibility wiring')
