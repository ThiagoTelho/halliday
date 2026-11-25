#!/usr/bin/env python3
"""CPU source-boundary guard; no controller, camera, HID or application calls."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
app = (root / 'app/Sources/Halliday/AppDelegate.swift').read_text()
sense_swift = (root / 'app/Sources/Halliday/SenseControllers.swift').read_text()
sense = (root / 'core/halliday-core/src/sense.rs').read_text()
history = (root / 'core/halliday-core/src/sense_orientation_history.rs').read_text()
camera = (root / 'core/halliday-core/src/session.rs').read_text()
clock = (root / 'core/halliday-core/src/time.rs').read_text()
start = app.index('let orientations = SenseControllers.Hand.allCases.compactMap')
end = app.index('let frame = HandTrackingWorker.Frame', start)
collector = app[start:end]
assert 'sense.orientation(hand, atHostNs: l.exposureHostNs)' in collector
assert 'let q = state.orientation' not in collector
assert 'halliday_sense_orientation_at(core, exposure, &q)' in sense_swift
feed = sense[sense.index('fn feed_place('):sense.index('pub fn set_room_yaw(')]
assert feed.index('crate::time::host_time_ns()') < feed.index('self.clock_offset = Some(kept)')
assert feed.index('push_device_time') < feed.index('let (Some(yaw), true)')
assert 'exposure_host_ns.checked_sub(current_offset_ns)' in history
assert 'self.samples[at].0 == target' in history
assert 'MAX_BRACKET_DISTANCE_NS' in history
assert 'clock_offset_ns().map_or(0' in camera
assert 'crate::time::host_time_ns()' in camera
assert 'CLOCK_UPTIME_RAW' in clock
assert 'sampleHostNs: state.sampleHostNs' in app and 'predicted.targetHostNs' in app and 'poseFrame: .senseAim' in app
assert 'handExposureStaging.insert(frame, expected: expected, nowNs: nowNs)' in app
assert 'handExposureStaging.ready(nowNs: nowNs' in app
assert 'halliday_sense_state_timed' in sense_swift
print('PASS: optical solver uses exact exposure lookup; history works before optical yaw; raw device times rebase with current native host offset; common sensor target, pending exact-exposure brackets and fixed mount remain')

# A source can disconnect while pending brackets exist but no worker exists yet.
clear = app[app.index('private func clearOpticalHandHistory()'):app.index('private func trackHands(')]
assert 'handExposureStaging.reset()' in clear
