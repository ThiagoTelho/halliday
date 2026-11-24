#!/usr/bin/env python3
"""CPU-only guard: the tested input policy must protect real OS effect callsites."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
app = (root / 'app/Sources/Halliday/AppDelegate.swift').read_text()
owner = (root / 'app/Sources/Halliday/MouseOwner.swift').read_text()
view = (root / 'app/Sources/Halliday/HeadsetView.swift').read_text()
def body(source, signature):
    start = source.index(signature)
    opened = source.index('{', start)
    depth = 1
    for at in range(opened + 1, len(source)):
        depth += (source[at] == '{') - (source[at] == '}')
        if not depth:
            return source[opened + 1:at]
    raise AssertionError('unbalanced source body: ' + signature)
policy = body(app, 'private var controllerPointerPolicy:')
assert 'gamePresenting: game?.isPresenting == true' in policy
assert 'gameActive' not in policy, 'paused dashboard must retain the protection'
for name in ['private func activateSceneApplication()', 'private func raiseSceneWindowForDesktopInput()']:
    source = body(app, name)
    assert source.index('game?.isPresenting != true') < min(
        source.find(effect) for effect in ['NSApp.activate()', 'makeKeyAndOrderFront'] if effect in source)
assert app.count('NSApp.activate()') == 1, 'programmatic app activation must pass the single guard'
clicked = body(app, 'func clickedInView(')
assert clicked.index('panels.first') < clicked.index('allowsNativeControllerEvents') < clicked.index('mouseOwner.start()')
assert 'panel.press(' in clicked, 'VR panels must keep their local dispatch'
assert 'syncControllerDesktopOwnership()' in body(app, 'private func frameTick(')
assert 'self.syncControllerDesktopOwnership()' in app[app.index('game?.onChange ='):]
assert 'force && on' in body(app, 'private func setPointerLock('), 'unlocking an already free mouse is a no-op'
assert '!controllerPointerPolicy.gamePresenting' in body(app, 'private func setPointerLock(')
assert 'gamePresenting: game?.isPresenting == true' in body(app, 'private func keepCursorOffVirtualDisplay()')
physical = app[app.index('final class HeadsetWindow:'):app.index('final class PreviewWindow:')]
assert 'canBecomeKey: Bool { false }' in physical and 'canBecomeMain: Bool { false }' in physical
assert 'owned || window is HeadsetWindow' in body(app, 'func mouseOwnershipChanged(')
for name in ['func controllerMoved()', 'func controllerRelease(', 'func controllerScroll(']:
    source = body(owner, name)
    assert source.index('mayPostControllerEvents') < source.index('CGEvent(')
post = body(owner, 'private func repost(')
assert post.index('eventSequence.accepts(generation)') < post.index('box.event.post(')
raise_body = body(owner, 'private func raise(')
assert raise_body.count('acceptsNativeAction(generation)') >= 3, 'queued native raises must also retire'
stop = body(owner, 'func stop(')
assert 'eventSequence.end()' in stop and 'pressedRightWindow = nil' in stop
assert stop.index('if !preserveCursor') < stop.index('CGWarpMouseCursorPosition')
assert 'if hidesDesktopCursor' in body(view, 'override func resetCursorRects()')
print('PASS: source wiring protects game + dashboard OS event/focus/cursor paths and retains local VR panel dispatch; no app, cursor or HID calls executed')

resume = body(app, 'private func restoreGameFocusAfterResume()')
assert resume.index('GameResumeFocus.shouldActivate') < resume.index('.activate()')
assert 'CGWarp' not in resume and 'setPointerLock' not in resume
away = body(app, 'private func setGameAway(')
assert 'if !on, game.isPresenting { restoreGameFocusAfterResume() }' in away
assert 'if on, let producer = game.focusProducer, gameResumeFocusTarget?.producer != producer' in away
assert 'game.focusProducer == producer' in away and 'gameMenuFocusRevision == focusRevision' in away
assert 'await GameResumeFocus.discover' in away
assert 'request.accepts(producer: currentProducer, revision: self.gameMenuFocusRevision' in resume
assert 'presenting: game.isPresenting, dashboard: self.gameAway' in resume
print('PASS: only central explicit live-game Resume restores a validated game app once; opening VR dashboard performs no activation')

assert 'target?.identity.isAlive != true' not in resume, 'dead cached identity must not trigger a same-lease name lookup'
assert 'GameResumeFocus.preferRemembered' in resume
print('PASS: producer-bound target remains sticky after death/PID reuse; new producer identity alone permits rediscovery')

bridge = (root / 'app/Sources/Halliday/GameBridge.swift').read_text()
tick = body(bridge, 'func tick(head:')
assert tick.index('if let real = realHands[hand]') < tick.index('let input = inputRearm[hand].filter')
assert tick.index('c.axes.2.0 = input.grip') < tick.index('halliday_bridge_publish_frame_with_motion')
assert 'inputRearm[hand].setFocused(!shown)' in body(bridge, 'func setDashboard(')
assert bridge.count('inputRearm = [GameControllerInputRearm(), GameControllerInputRearm()]') == 2
print('PASS: central per-hand rearm filters assembled real/emulated controls before independent publication, follows dashboard focus, and resets for the next producer')
