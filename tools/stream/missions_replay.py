#!/usr/bin/env python3
"""Ten-minute synthetic aired sample through the real caster, receipt memory and speech-camera resolver.
No model/TTS/network calls; fake audio duration and capture receipts, explicitly NOT a live recording.
Run with no arguments. The recovery sequence is injected, not an observation of the live Asterion.
"""
import copy
import json
import tempfile
import contextlib
import io
from collections import Counter
from unittest.mock import patch

import caster
from missions import Missions
from test_speechframe import director, team, warm, main_subj
from test_platformcam import plat

START = 1_800_000_000.0


def snapshot(now, offset=0):
    p = plat('Asterion', 'solar-system-edge->shattered-planet 10%')
    p.update(name='Asterion', route_ids=['solar-system-edge', 'shattered-planet'])
    if 180 <= offset < 390:
        p['danger'] = {'kind': 'fire', 'last': now, 'level': 1, 'reason': 'Asterion under asteroid fire'}
    m = {'platform': 'Asterion', 'sample_t': now, 'tick': 100000 + offset * 60,
         'leg': {'from': 'solar-system-edge', 'to': 'shattered-planet', 'start_tick': 90000,
                 'pct': 9.9 + offset / 1200}, 'speed_kms': 25.6, 'losses_leg': 0,
         'hits_min': 2 if 180 <= offset < 390 else 0, 'damage_taken': 20 if 180 <= offset < 390 else 0,
         'kills_min': 4500, 'repair_packs': 629, 'turrets': {},
         'ammo': [{'name': 'railgun-ammo', 'net_min': -10 if 180 <= offset < 390 else 13}]}
    return {'tick': m['tick'], 'agents': team(), 'chat': [], 'alerts': [], 'game_time': '580h00m',
            'board': {'plan': {'goals': 'Advance as far toward Shattered Planet as Asterion can survive.', 'doing': []}},
            'run_target': {'goal': 'as far toward Shattered Planet as Asterion can fly'},
            'space': {'platforms': [p]}, 'featured_platform': {'status': 'active', 'name': 'Asterion', 'id': 'attempt'},
            'mission_metrics': m, 'work': [{'platform': 'Asterion', 'kind': 'repair', 't': now}] if 180 <= offset < 390 else []}


def replay(enabled=True):
    with tempfile.TemporaryDirectory() as root:
        clock = [START]
        def sleep(dt):
            clock[0] += dt
        with patch('time.time', lambda: clock[0]), patch('time.sleep', sleep):
            a = caster.parser().parse_args(['--writer', 'template', '--run-dir', root, '--log-dir', root, '--always', '--seed', '460'])
            c = caster.Caster(a)
            if not enabled:
                c.missions = None
            c.plain = None
            c.next_gap = 0
            c.request_segment = lambda *a, **k: None
            c.previous = lambda: None
            c.tts = type('FakeTTS', (), {'backend': 'offline'})()
            c.speak_clip = lambda *a, **k: (b'offline', 'audio/wav', 2, 0, {'voice': 'offline'})
            receipts, aired = [], []
            d = director(auto_feature=False)
            warm(d, team())
            def status():
                return {'listeners': 1, 'receipts': [r for r in receipts if r['t'] <= clock[0]]}
            c.status = status
            def push(meta, audio, ctype):
                cid = 'sample-' + str(len(aired))
                speech = dict(meta, id=cid, started=clock[0])
                snap = copy.deepcopy(c.snap)
                snap['speech'] = [speech]
                d.step(snap, clock[0])
                row = {'at': round(clock[0] - START, 1), 'speaker': meta['speaker'], 'text': meta['text'],
                       'subjects': meta['subjects'], 'camera': main_subj(d), 'rank': meta['rank'],
                       'camera_platform': ((d.state.get(d.onair) or {}).get('platform') or {}).get('name')}
                aired.append(row)
                receipts.append({'id': cid, 't': clock[0] + 2, 'state': 'end', 'completed': True})
                return dict(meta, id=cid, expires=clock[0] + meta['expires_in'])
            c.push = push
            for offset in range(0, 601, 20):
                clock[0] = START + offset
                s = snapshot(clock[0], offset)
                c.on_snapshot(s)
                d.step(s, clock[0])
                if offset % 100 == 60:
                    c.events.append({'kind': 'research', 'prio': 7, 't': clock[0], 'text': 'Research completed'})
                if offset == 180:
                    c.events.append({'kind': 'attack', 'prio': 9, 't': clock[0],
                                     'text': 'Asteroids are hitting Asterion', 'surface': 'platform-1',
                                     'facts': {'platform': 'Asterion'}})
                c.caster_tick(clock[0], status())
            clock[0] += 40
            c.playback_receipts(status())
            counts = Counter(g['event']['kind'] for g in c.playback().groups.values()
                             if any(r['state'] == 'completed' for r in g['lines']))
            missions = [g for g in c.playback().groups.values() if g['event']['kind'] == 'mission']
            assert all(g['backend'] == 'mission-facts' for g in missions)
            if enabled:
                assert any('Repair or construction' in r['text'] for r in aired), aired
                assert any('keeping up' in r['text'] or 'no new hits' in r['text'] for r in aired), aired
                assert counts['research'] and counts['mission'] >= 3, counts
                assert any(r['rank'] == 'urgent' and r['camera_platform'] == 'Asterion' for r in aired), aired
            for r in aired:
                if {'platform': 'Asterion'} in r['subjects']:
                    assert r['camera_platform'] == 'Asterion', r
            return {'mode': 'synthetic offline capture receipts; no live audio', 'seconds': 600,
                    'completed_exchanges': dict(counts), 'lines': aired,
                    'heard_milestones': Missions(root).heard, 'additional_host_writing_calls': 0}


if __name__ == '__main__':
    with contextlib.redirect_stdout(io.StringIO()):
        result = replay()
        baseline = replay(False)
    result['same_trace_without_missions'] = {'completed_exchanges': baseline['completed_exchanges'],
                                            'lines': baseline['lines']}
    print(json.dumps(result, indent=2))
