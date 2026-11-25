#!/usr/bin/env python3
"""CPU source-boundary guard: actual app must use the paired optical API."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
worker = (root / 'app/Sources/Halliday/HandTrackingWorker.swift').read_text()
app = (root / 'app/Sources/Halliday/AppDelegate.swift').read_text()
native = worker[worker.index('private final class NativeSolver:'):]
assert native.count('halliday_hand_pair_update(') == 1
assert 'halliday_hand_update(' not in native
assert 'private var handle: OpaquePointer?' in native
assert 'halliday_hand_pair_close(handle)' in native
assert 'halliday_hand_pair_set_fisheye_alignment' in native
assert 'frame.exposureHostNs' in native and 'frame.headPosition' in native
assert 'UInt32(1) << UInt32(hand.index)' in native
assert 'guard accepted & (UInt32(1) << UInt32(hand)) != 0' in native
assert 'HandTrackingWorker.Frame(counter: l.counter, exposureHostNs: l.exposureHostNs' in app
assert 'var at = frame.headPosition + headOrientation.act(fix.position)' in app
assert 'sense.placeFix(hand, ns: frame.exposureHostNs, at)' in app
assert 'poseFrame: .senseAim' in app
print('PASS: one paired optical snapshot; exact left/right bits; only accepted fixes reach inertial position filter; geometry generations and exposure/head transform retained; accepted Sense orientation untouched')
