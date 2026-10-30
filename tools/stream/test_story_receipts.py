#!/usr/bin/env python3
"""Hosts remember capture playback, and revalidate slow work. No network, TTS or live service."""
import copy
from collections import deque
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
import caster
from analyst_board import AnalystBoard
from freshness import stamp, current_analyst, scoped, invalid
from playback_memory import PlaybackMemory
from serve import AudioHub


class Clock:
    def __init__(self): self.t = 1000.0
    def now(self): return self.t
    def sleep(self, seconds): self.t += seconds


def snapshot():
    return {'tick': 6000, 'game_time': '0h01m', 'agents': [{'name': 'sol', 'alive': True}],
            'board': {'plan': {'goals': 'Test the ship', 'doing': [{'name': 'sol', 'text': 'Holding position'}]}},
            'analyst': {'corrections': ['The gun lacked ammunition.']}}


def host(clock, memory=None):
    c = caster.Caster.__new__(caster.Caster)
    c.a = SimpleNamespace(dry_run=False, always=False, run_dir=None, react=1, yield_s=30)
    c.lock = caster.threading.Lock()
    c.source_snap = c.snap = snapshot()
    c.source_received = clock.t
    c._playback = memory or PlaybackMemory()
    c.history, c.recent, c.events = deque(maxlen=4), deque(maxlen=8), deque()
    c.used_points, c.stats, c.records, c.prep = set(), {'skipped_no_listener': 0}, [], []
    c.caster_free = c.agent_free = c.next_gap = 0
    c.tts, c.tts_fallback = SimpleNamespace(backend='stub'), None
    c.breakers = {'tts': SimpleNamespace(ok=lambda: True, good=lambda: None, fail=lambda: None)}
    hub = AudioHub(require_capture=True); hub.listeners = 1
    c.status = hub.status
    c.record = lambda **kw: c.records.append(kw)
    c.push = hub.push
    c.cancel_audio = hub.cancel
    c.speak_clip = lambda *a, **kw: (b'audio', 'audio/mpeg', 2, 0, {'voice': 'stub'})
    c.point_used = lambda pid: c.used_points.add(pid)
    return c, hub


def event(c, clock):
    point = dict(id='p1', topic='ammo', text='The gun lacked ammunition.', **stamp(c.source_snap, clock.t))
    return {'kind': 'analyst', 'prio': 1, 'point': point, '_source': stamp(c.source_snap, clock.t)}


def speak(c, e, clock, lines=None):
    c.speak_lines(lines or [('pbp', 'The gun lacked ammunition.'), ('color', 'That explains the gap.')],
                  e, {'game_time': '1 minute'}, 'stub-writer', None, 0, clock.t)
    return next(reversed(c.playback().groups))


def played(hub, cid, state, clock, **kw):
    hub.played(dict(id=cid, state=state, page='main', session='capture', capture=True, duration=2, **kw), now=clock.t)


def lifecycle(clock):
    c, hub = host(clock)
    e = event(c, clock); gid = speak(c, e, clock)
    rows = c.playback().groups[gid]['lines']
    assert [r['state'] for r in rows] == ['queued', 'queued']
    assert not c.history and not c.used_points and c.playback().held_points() == {'p1'}
    hub.played({'state': 'load', 'page': 'main', 'session': 'capture', 'capture': True}, now=clock.t)
    played(hub, rows[0]['cid'], 'start', clock)
    c.playback_receipts(hub.status())
    assert rows[0]['state'] == 'started' and not c.history
    hub.played({'id': rows[0]['cid'], 'state': 'end', 'played': 2, 'page': 'portrait'}, now=clock.t)
    c.playback_receipts(hub.status()); assert not c.history
    hub.played({'id': rows[0]['cid'], 'state': 'end', 'played': 2, 'page': 'main', 'capture': False}, now=clock.t)
    c.playback_receipts(hub.status()); assert not c.history, 'a browser preview is not the capture'
    played(hub, rows[0]['cid'], 'end', clock, played=2)
    c.playback_receipts(hub.status())
    assert len(c.history) == 1 and not c.used_points
    played(hub, rows[1]['cid'], 'start', clock)
    played(hub, rows[1]['cid'], 'cut', clock, played=.4)
    c.playback_receipts(hub.status())
    assert rows[1]['state'] == 'interrupted' and len(c.history) == 1
    assert not c.playback().held_points() and not c.used_points
    assert c.playback().unfinished() == (gid, [1])
    assert not hub.pending(), 'started/completed clips must not replay on reconnect'
    c.caster_free = 0
    assert c.resume_explanation(hub.status())
    assert rows[0]['state'] == 'completed' and rows[0]['attempt'] == 1 and rows[1]['attempt'] == 2
    played(hub, rows[1]['cid'], 'start', clock)
    played(hub, rows[1]['cid'], 'end', clock, played=2)
    c.playback_receipts(hub.status()); c.playback_receipts(hub.status())
    assert len(c.history) == 2 and c.used_points == {'p1'}
    assert not c.playback().unfinished()
    played(hub, rows[1]['cid'], 'skip', clock, reason='expired')
    c.playback_receipts(hub.status())
    assert len(c.history) == 2 and rows[1]['state'] == 'completed'
    assert all(r.get('page') == 'main' for r in hub.status()['receipts'])
    c, hub = host(clock); gid = speak(c, event(c, clock), clock)
    rows = c.playback().groups[gid]['lines']
    played(hub, rows[0]['cid'], 'start', clock); played(hub, rows[0]['cid'], 'cut', clock, played=.4)
    c.playback_receipts(hub.status())
    assert c.playback().unfinished() == (gid, [0, 1])
    assert not hub.pending(), 'unheard continuation is withdrawn until the interrupted line can finish'


def unheard(clock):
    for outcome in ('no listener', 'tts', 'skip', 'error', 'expired', 'reload', 'no end'):
        c, hub = host(clock); e = event(c, clock)
        if outcome == 'no listener': hub.listeners = 0
        if outcome == 'tts':
            def fail(*a, **kw): raise RuntimeError('synthesis failed')
            c.speak_clip = fail
        gid = speak(c, e, clock, [('pbp', 'The gun lacked ammunition.')])
        row = c.playback().groups[gid]['lines'][0]
        if outcome in ('skip', 'error'):
            played(hub, row['cid'], outcome, clock, reason='expired' if outcome == 'skip' else 'decode')
        elif outcome == 'expired': clock.t += 40
        elif outcome in ('reload', 'no end'):
            played(hub, row['cid'], 'start', clock)
            if outcome == 'reload':
                hub.played({'state': 'load', 'page': 'main', 'session': 'next', 'capture': True}, now=clock.t)
                played(hub, row['cid'], 'end', clock, played=2)  # stale capture session cannot complete it
            else: clock.t += 40
        c.playback_receipts(hub.status())
        assert not c.history and not c.used_points, outcome
        assert not c.playback().held_points(), (outcome, row)
        if outcome in ('reload', 'no end'): assert c.playback().unfinished(), outcome
    # Playback state survives a caster restart, including the completed first line.
    with TemporaryDirectory() as d:
        path = str(Path(d) / 'memory.json')
        c, hub = host(clock, PlaybackMemory(path)); gid = speak(c, event(c, clock), clock)
        rows = c.playback().groups[gid]['lines']
        played(hub, rows[0]['cid'], 'start', clock); played(hub, rows[0]['cid'], 'end', clock, played=2)
        played(hub, rows[1]['cid'], 'start', clock); played(hub, rows[1]['cid'], 'cut', clock, played=.4)
        c.playback_receipts(hub.status())
        restored = PlaybackMemory(path)
        assert restored.unfinished() == (gid, [1])
        assert restored.receipts(hub.status(), clock.t) == []


def freshness(clock):
    import analyst
    import json
    source_time = clock.t
    def stalled(*a):
        clock.t += 301
        return json.dumps({'headline': 'The ship is safe', 'corrections': ['The gun lacked ammunition.']}), {}
    with patch.object(analyst, 'fetch_feed', lambda base: snapshot()), patch.object(analyst, 'run_claude', stalled):
        reply, _, _ = analyst.cycle(SimpleNamespace(feed='stub', dry_run=True),
            SimpleNamespace(build=lambda *a: ('digest', {'game_minute': 1}, snapshot())), None, None)
    assert reply['source_t'] == source_time and reply['t'] == clock.t and reply['source_tick'] == 6000
    stalled_board = AnalystBoard(); stalled_board.post(reply, now=clock.t)
    assert 'headline' not in stalled_board.public(clock.t) and 'corrections' not in stalled_board.public(clock.t)
    s = snapshot(); board = AnalystBoard()
    cycle = dict(stamp(s, clock.t), headline='The ship is safe', next={'text': 'The edge is next'},
                 corrections=['All guns have ammunition'], talking_points=[{'topic': 'safe', 'text': 'Safe', 'ttl_s': 300}])
    board.post(cycle, now=clock.t + 301)  # stalled analyst: receive time must not renew the source
    public = board.public(clock.t + 301)
    assert not public['talking_points'] and all(k not in public for k in ('headline', 'next', 'corrections'))
    board.post(cycle, now=clock.t + 1)
    fresh = board.public(clock.t + 2)
    assert all(fresh[k] for k in ('headline', 'next', 'corrections'))
    assert fresh['source_tick'] == 6000 and fresh['subject_revision']
    changed = copy.deepcopy(s); changed['board']['plan']['goals'] = 'Retreat for repairs'
    assert 'corrections' not in current_analyst(fresh, changed, clock.t + 3)
    subjects = snapshot()
    subjects['agents'].append({'name': 'luna', 'alive': True})
    source = scoped(stamp(subjects, clock.t), 'Sol holds position.', ['sol'])
    subjects['agents'][1]['last_said'] = {'text': 'A new unrelated job'}
    assert invalid(source, subjects, clock.t + 1) is None
    subjects['agents'][0]['last_said'] = {'text': 'Retreating now'}
    assert invalid(source, subjects, clock.t + 1) == 'subject or plan revised'
    # Each change occurs DURING synthesis; no first line reaches the queue.
    for change in ('loss', 'retreat', 'correction', 'point revision', 'expiry'):
        c, hub = host(clock); e = event(c, clock)
        e['_analyst_source'] = dict(stamp(c.source_snap, clock.t),
            correction_revision=__import__('freshness').fingerprint(c.source_snap['analyst']['corrections']))
        def slow(*a, **kw):
            if change == 'loss': c.source_snap['alerts'] = [{'kind': 'loss', 'id': 'new-loss'}]
            if change == 'retreat': c.source_snap['board']['plan']['goals'] = 'Retreat for repairs'
            if change == 'correction': c.source_snap['analyst']['corrections'] = ['The belt, not the gun, was damaged.']
            if change == 'point revision': c.source_snap['analyst']['talking_points'] = [
                {'id': 'p2', 'topic': 'ammo', 'text': 'The feed belt was destroyed.'}]
            if change == 'expiry': clock.t += 301
            return b'audio', 'audio/mpeg', 2, 0, {'voice': 'stub'}
        c.speak_clip = slow
        gid = speak(c, e, clock, [('pbp', 'The ship is safe.')])
        assert not hub.clips and not c.history and not c.used_points, change
        assert c.playback().groups[gid]['lines'][0]['state'] == 'cancelled', change
    # An urgent loss first seen during synthesis is checked even before line zero.
    c, hub = host(clock); e = event(c, clock)
    def loss(*a, **kw):
        c.events.append({'kind': 'loss', 'prio': caster.URGENT, 't': clock.t + 1})
        return b'audio', 'audio/mpeg', 2, 0, {'voice': 'stub'}
    c.speak_clip = loss; speak(c, e, clock)
    assert not hub.clips


def writing_and_history(clock):
    """Exercise say_exchange as well as the synthesis path: the writer may itself stall."""
    import random
    from contextlib import ExitStack
    for mode in ('writer stall', 'writer correction', 'dated history'):
        c, hub = host(clock)
        c.a.gap = (0, 0)
        c.rng, c.fast = random.Random(1), None
        c.base_for, c.deadline, c.shift = lambda s: None, lambda: None, lambda: None
        c.names, c.live_segment = lambda s: {}, lambda *a, **k: None
        c.repeat_fault, c.used_framings = lambda s: None, lambda: []
        c.breakers['writer'] = SimpleNamespace(ok=lambda: True, good=lambda: None, fail=lambda: None)
        c.stats['caster_lines'] = 0
        def write(*a, **kw):
            if mode == 'writer stall': clock.t += 301
            if mode == 'writer correction': c.source_snap['board']['plan']['goals'] = 'Retreat for repairs'
            return [('pbp', 'The gun lacked ammunition.')]
        c.writer = SimpleNamespace(name='writer', exchange=write)
        c.main_writer = lambda: c.writer
        e = {'kind': 'analyst', 'prio': 1, 'point': dict(id='p1', text='The gun lacked ammunition.',
                                                     **stamp(c.source_snap, clock.t))}
        if mode == 'dated history': e.update(history=True, source_tick=3600)
        with ExitStack() as stack:
            stack.enter_context(patch.object(caster, 'facts_for', lambda *a, **k: {'text': 'The gun lacked ammunition.', 'game_time': '1 minute'}))
            stack.enter_context(patch.object(caster, 'story_facts', lambda *a, **k: None))
            stack.enter_context(patch.object(caster, 'check_line', lambda *a, **k: None))
            stack.enter_context(patch.object(caster.pollstrip, 'host_facts', lambda *a, **k: None))
            stack.enter_context(patch.object(caster.run_target, 'fact', lambda *a, **k: None))
            c.say_exchange(e, copy.deepcopy(c.snap), 'pbp', 1)
        if mode == 'dated history':
            assert len(hub.clips) == 1
            assert next(iter(hub.clips.values()))[2]['text'].startswith('Earlier, at 1 minute:')
            assert not c.history, 'even intentional history is unheard until completed'
        else:
            assert not hub.clips and not c.history and not c.playback().held_points(), mode


def main():
    clock = Clock()
    with patch('time.time', clock.now), patch('time.sleep', clock.sleep):
        lifecycle(clock); unheard(clock); freshness(clock); writing_and_history(clock)
    print('story receipts: ok (capture start/end/skip/error, expiry, reconnect/resume, no unheard memory, stale analyst and slow TTS races)')


if __name__ == '__main__': main()
