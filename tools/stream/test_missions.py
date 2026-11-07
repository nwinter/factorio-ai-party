#!/usr/bin/env python3
"""Mission speech freshness, coalescing, receipts, lineage, offscreen telemetry and camera replay. Offline."""
import contextlib
import copy
import io
import json
import os
import tempfile
from unittest.mock import patch

import caster
import commentary_freshness
import missions
from missions_replay import snapshot, replay, START
from platformmetrics import Metrics
from test_platformmetrics import snapshot as camera_snapshot, raw


def complete(m, e, now):
    m.completed(e, now, e['lines'][0][1])


def send_guards():
    """Expire during TTS, or deliver urgent news during TTS: neither may post mission audio."""
    for cause in ('age', 'urgent', 'changed'):
        with tempfile.TemporaryDirectory() as root:
            clock = [START]
            with patch('time.time', lambda: clock[0]), patch('time.sleep', lambda dt: clock.__setitem__(0, clock[0] + dt)):
                a = caster.parser().parse_args(['--writer', 'template', '--run-dir', root, '--log-dir', root, '--always'])
                c = caster.Caster(a)
                c.snap = c.source_snap = snapshot(START)
                c.source_received = START
                c.status = lambda: {'listeners': 1}
                c.tts = type('FakeTTS', (), {'backend': 'offline'})()
                pushed = []
                c.push = lambda *args: pushed.append(args)
                def synth(*args, **kwargs):
                    if cause == 'age':
                        clock[0] = START + 46
                    elif cause == 'changed':
                        c.source_snap['mission_metrics']['leg']['pct'] = 50
                    else:
                        clock[0] = START + 1
                        c.events.append({'kind': 'death', 'prio': 10, 't': START + 1})
                    return b'offline', 'audio/wav', 2, 0, {}
                c.speak_clip = synth
                event = c.missions.event(c.snap, START)
                c.say_exchange(event, c.snap, 'pbp', 2)
                assert not pushed, cause
                assert not c.missions.heard, cause
                assert all(r['state'] == 'cancelled' for g in c.playback().groups.values() for r in g['lines'])
                gid = c.playback().generated(event['lines'], event, caster.facts_for(event, c.snap), 'mission-facts', START)
                c.playback().queued(gid, 0, {'id': 'queued', 'duration': 2, 'expires': START + 45})
                withdrawn = []
                c.cancel_audio = lambda cid: withdrawn.append(cid) or True
                clock[0] = START + 46
                c.playback_receipts({})
                assert withdrawn == ['queued']
                assert not c.missions.heard


def main():
    s = snapshot(START)
    m = missions.Missions()
    e = m.event(s, START)
    assert e['milestone'] == 'progress' and '9.9 percent' in e['lines'][0][1]
    assert caster.subjects_of(caster.facts_for(e, s), e) == [{'platform': 'Asterion'}]
    assert caster.clip_rank(e) == 'banter'
    for bad in (46, -2):
        old = copy.deepcopy(s)
        old['mission_metrics']['sample_t'] = START - bad
        assert m.event(old, START) is None
    for key in ('paused', 'platform_paused'):
        paused = copy.deepcopy(s)
        paused['mission_metrics'][key] = True
        assert m.event(paused, START) is None
    old = copy.deepcopy(s)
    del old['mission_metrics']['sample_t']
    assert m.event(old, START) is None
    assert m.event(dict(s, space={'platforms': []}), START) is None
    changed = copy.deepcopy(s)
    changed['space']['platforms'][0]['route_ids'].reverse()
    assert m.event(changed, START) is None
    assert m.invalid(e, s, START + 46)
    changed = snapshot(START + 10, 10)
    changed['mission_metrics']['leg']['pct'] = 12
    assert m.invalid(e, changed, START + 10)
    # A completed Rook line must NOT invalidate its queued Vale explanation.
    complete(m, e, START + 2)
    assert m.invalid(e, s, START + 3) is None
    assert m.event(snapshot(START + 100, 100), START + 100) is None
    unchanged = snapshot(START + 200)
    assert m.event(unchanged, START + 200) is None, 'no new facts, no repeat'
    # A queued/generated/skipped line is not heard: no state changes before the receipt callback.
    with tempfile.TemporaryDirectory() as root:
        first = os.path.join(root, 'shift1')
        second = os.path.join(root, 'shift2')
        os.mkdir(first); os.mkdir(second)
        with open(os.path.join(second, 'resumed-from'), 'w') as f:
            f.write('shift1')
        mem = missions.Missions(first)
        p = snapshot(START)
        p['mission_metrics']['leg']['pct'] = 10.2
        initial = mem.event(p, START)
        assert not mem.rows
        complete(mem, initial, START + 2)
        assert initial['milestone'] == 'progress:10'
        p['mission_metrics']['sample_t'] = START + 200
        assert mem.event(p, START + 200) is None
        inherited = missions.Missions(second)
        p['mission_metrics']['sample_t'] = START + 400
        assert inherited.event(p, START + 400) is None
        # Playback restoration is idempotent, even if it visits earlier completed groups.
        complete(inherited, initial, START + 2)
        assert len(inherited.heard) == 1
        assert inherited.rows == mem.rows
        independent = missions.Missions(os.path.join(root, 'unrelated'))
        assert independent.rows == {}
        import hourly
        material = hourly.gather(first, START, START + 600, logs_dir=root)
        assert any(r['kind'] == 'mission' and 'sample tick' in r['text'] for r in material.rows)
        assert any(t['target'] == {'platform': 'Asterion'} for t in material.targets)
        p['mission_metrics']['leg']['start_tick'] += 100
        assert inherited.event(p, START + 400), 'a new voyage may have its own milestones'
    # Damage -> recovery; unknown readings never become an all-clear.
    m = missions.Missions()
    damaged = snapshot(START, 200)
    damaged['work'] = []
    e = m.event(damaged, START)
    assert e['milestone'] == 'damage'
    complete(m, e, START + 2)
    clean = snapshot(START + 200, 400)
    recovered = m.event(clean, START + 200)
    assert recovered['milestone'] == 'recovery'
    complete(m, recovered, START + 202)
    # A new negative phase is not announced over and over; milestone memory is by mission.
    damaged['mission_metrics']['sample_t'] = START + 400
    loss = copy.deepcopy(damaged)
    loss['mission_metrics']['losses_leg'] = 1
    lost = m.event(loss, START + 400)
    assert lost['milestone'] == 'first-loss' and 'structure' in lost['lines'][0][1]
    complete(m, lost, START + 402)
    clean = snapshot(START + 600, 600)
    assert m.event(clean, START + 600)['milestone'] != 'recovery', 'heard recovery is not repeated'
    unknown = copy.deepcopy(clean)
    unknown['mission_metrics'].pop('hits_min')
    assert m.event(unknown, START + 600)['milestone'] != 'recovery'
    # Offscreen collection stays one global read, never publishes an offscreen overlay card.
    metrics = Metrics()
    s = camera_snapshot()
    s['onair'] = {'host': {'label': 'Host'}}
    reads = []
    def read(name, args):
        reads.append((name, args))
        return raw(), 0
    assert metrics.step(s, read, START) is None
    cached = metrics.mission_sample(s, START)
    assert cached['platform'] == 'Resolute' and cached['sample_t'] == START and 'asteroids' not in cached
    metrics.step(s, read, START + 10)
    assert len(reads) == 1
    assert metrics.mission_sample(s, START + 46) is None
    # Analyst telemetry claims expire and invalidate on changed numbers; ordinary research is unaffected.
    s = snapshot(START)
    src = {'mission_source': missions.analyst_source(s, START)}
    assert caster.mission_deadline({'kind': 'analyst', 'point': src}) == START + 45
    assert caster.mission_deadline({'kind': 'research'}) is None
    assert commentary_freshness.invalid(src, s, START + 1) is None
    assert commentary_freshness.invalid(src, s, START + 46)
    newer = snapshot(START + 20, 20)
    assert commentary_freshness.invalid(src, newer, START + 20)
    assert commentary_freshness.invalid({}, newer, START + 20) is None
    assert 'mission_source' not in commentary_freshness.scoped(src, 'Research finished')
    assert 'mission_source' in commentary_freshness.scoped(src, 'Asterion continues')
    assert 'mission_source' in commentary_freshness.scoped(src, 'The ship has flown 10 percent of this leg')
    ctx = missions.context(s, START)
    assert ctx['goals'] and ctx['voyage_sample']
    assert 'voyage_sample' not in missions.context(s, START + 46)
    assert len(missions.digest_context(s, START)) <= 6000
    with contextlib.redirect_stdout(io.StringIO()):
        send_guards()
    # Exercise real caster queue selection, real speech pushing and completed capture receipts, with camera subjects.
    with contextlib.redirect_stdout(io.StringIO()):
        result = replay()
    assert result['completed_exchanges']['mission'] == 3
    assert result['completed_exchanges']['research'] >= 2
    print('missions: freshness, unknowns, lineage, receipt idempotence, offscreen budget, analyst provenance, ten-minute aired replay: ok')


if __name__ == '__main__':
    main()
