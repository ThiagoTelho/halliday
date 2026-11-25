#!/usr/bin/env python3
"""Source contracts supplement the executed fake-clock and real C-ABI fixtures."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
controller = (root/'app/Sources/Halliday/SenseControllers.swift').read_text()
bridge = (root/'app/Sources/Halliday/GameBridge.swift').read_text()
policy = (root/'app/Sources/Halliday/SenseOutputPolicy.swift').read_text()
native = (root/'core/halliday-openxr/src/session.rs').read_text()
windows = (root/'windows-openxr/src/control.cpp').read_text()
for forbidden in ['pcmPlayback', 'SensePendingPCM', 'playPCM(', 'setPCMEnabled(']:
    assert forbidden not in controller, forbidden
assert 'pcmEnabled' not in policy
assert controller.count('hapticRequestCurrent(token, hand: command.hand)') == 1
assert controller.count('self.ledReportID(target)') == 3
assert 'hapticScheduler.nextReport(' in controller
assert 'hapticScheduler.nextDeadline' in controller
assert 'purpose: "vibration"' in controller and 'purpose: "LED"' in controller
assert 'self.devices[target.hand]?.generation == target.generation' in controller
assert 'sense.0' not in (root/'core/halliday-core/src/sense_output_ffi.rs').read_text()
assert 'c.touched = touch.bridgeTouched' in bridge and 'c.axes.3 = (touch.proximity.x, touch.proximity.y)' in bridge
assert 'controllerHapticsFocused: Bool { !paused && !dashboardShown }' in bridge
for path in ['input/trigger/touch', 'input/thumbstick/touch', 'input/a/touch', 'input/b/touch']:
    assert path in native, path
assert 'Part::TriggerTouch => [f32::from(u8::from(c.touched & BIT_TRIGGER != 0))' in native
assert 'touch(33)' in windows and 'touch(32)' in windows and 'touch(7)' in windows and 'touch(1)' in windows
print('PASS wiring: classic output tokens, shared LED serialization, current-generation guards and native/Windows contact routes; experimental PCM absent')
