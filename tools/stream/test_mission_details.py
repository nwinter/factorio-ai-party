#!/usr/bin/env python3
"""Routine ammo, dated trials, queue guards and narrator receipt regression; offline."""
import copy
import contextlib
import io
import json
import tempfile
from missions import Missions, ammo_lines, reports
from missions_replay import snapshot, START
import hourly


def main():
    s = snapshot(START)
    s['mission_metrics']['ammo'] = [dict(name='railgun-ammo', made_min=283, used_min=239,
                                       hub=4969, turrets=489, net_min=44),
                                  dict(name='rocket', made_min=478, used_min=578,
                                       hub=25443, turrets=495, net_min=-99, buffer_min=262)]
    s['agents'][0]['last_said'] = dict(t=START-20, tick=s['tick']-1200,
        text='Asterion rail targeting trial failed. Iron feed refit is next.')
    with tempfile.TemporaryDirectory() as root:
        m = Missions(root)
        # Existing negative milestone already aired; repeated goal no longer crowds out detail.
        from missions import identity
        m.rows[identity(s['mission_metrics'])] = {'milestones': ['negative:rocket'], 'pct': 9.9}
        e = m.event(s, START)
        assert e['milestone'] == 'ammo:rocket'
        assert '478' in e['lines'][0][1] and '578' in e['lines'][0][1]
        assert '25,443' in e['lines'][1][1] and '495' in e['lines'][1][1]
        assert 'goal' not in str(e['lines'])
        assert not m.heard
        assert m.invalid(json.loads(json.dumps(e)), s, START+1) is None
        for key in ('made_min', 'used_min', 'hub', 'turrets'):
            changed = copy.deepcopy(s)
            changed['mission_metrics']['ammo'][1][key] += 5
            assert m.invalid(e, changed, START+1) == 'mission observation changed'
        changed = copy.deepcopy(s)
        changed['mission_metrics']['leg']['pct'] += .01
        assert m.invalid(e, changed, START+1) is None
        assert m.invalid(e, s, START+46)
        m.completed(e, START+2, e['lines'][0][1])
        material = hourly.gather(root, START, START+600, logs_dir=root)
        assert not any('25,443' in r['text'] for r in material.rows), 'unheard Vale reserve must not reach narrator'
        m.completed(e, START+8, e['lines'][1][1], 'color')
        m.completed(e, START+8, e['lines'][1][1], 'color')
        assert len(m.heard) == 2
        material = hourly.gather(root, START, START+600, logs_dir=root)
        assert any('25,443' in r['text'] and 'then-current' in r['text'] for r in material.rows)
        s['mission_metrics']['sample_t'] = START+200
        e2 = m.event(s, START+200)
        assert e2['milestone'].startswith('report:')
        assert 'reported:' in e2['lines'][0][1] and 'trial failed' in e2['lines'][0][1]
        assert 'dated agent report' in e2['lines'][1][1]
        changed = copy.deepcopy(s)
        changed['agents'][0]['last_said']['text'] = 'Asterion trial succeeded.'
        assert m.invalid(e2, changed, START+201)
        m.completed(e2, START+202, e2['lines'][0][1])
        s['mission_metrics']['sample_t'] = START+400
        e3 = Missions(root).event(s, START+400)
        assert e3['milestone'] == 'ammo:railgun-ammo', 'rotate through ammo, persist heard reports'
        # Missing/nonfinite telemetry is unknown, never zero. Undated/future/old reports fail closed.
        for value in (None, float('nan'), float('inf'), -1):
            bad = copy.deepcopy(s['mission_metrics']); bad['ammo'][0]['hub'] = value
            assert ammo_lines(bad, 'railgun-ammo') is None
        for tick in (None, s['tick']+1, s['tick']-216001):
            bad = copy.deepcopy(s); bad['agents'][0]['last_said']['tick'] = tick
            assert not reports(bad, bad['mission_metrics'], START+400)
    # Real scheduler, TTS push and capture receipt path on a quiet ten-minute voyage.
    import missions_replay
    def detailed(now, offset=0):
        snap = snapshot(now)
        snap['mission_metrics']['ammo'] = [dict(name='railgun-ammo', made_min=283, used_min=239,
                                                hub=4969, turrets=489, net_min=44)]
        snap['agents'][0]['last_said'] = dict(t=START-20, tick=snap['tick']-1200,
            text='Asterion rail targeting trial failed. Iron feed refit is next.')
        return snap
    with contextlib.redirect_stdout(io.StringIO()):
        trace = missions_replay.replay(snapshot_factory=detailed)
    lines = str(trace)
    assert 'made 283, used 239' in lines and '4,969' in lines and 'trial failed' in lines
    print('mission details: ammo rotation, dated refit/test/next report, freshness, changed facts, completed-only narrator: ok')


if __name__ == '__main__':
    main()
