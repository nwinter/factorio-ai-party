#!/usr/bin/env python3
"""CJ: unchanged remote destinations survive pans, including the d30 10:02-10:11 log cadence.

All camera sends are local stubs. The fixture retains the recorded times and captions of each
continuous Asterion remote-work shot, with geometry reconstructed from its centre and pan ends.
It replays refresh_remote + pan_step, not unrelated director selection or the live game.
"""
import contextlib
import copy
import io
import json
from pathlib import Path

import remotework
from featured import Featured
from onecam import OneCam
from test_onecam import agent
from test_platformcam import plat, snap

FIXTURE = Path(__file__).with_name('fixtures') / 'd30-remote-pan.json'
VIEW = dict(surface='platform-16', hub=dict(x=0, y=0),
            bounds=dict(left=-51.5, right=9, top=-56.5, bottom=255.5))
SLOTS = [dict(slot='main', player=1), dict(slot='standby', player=2),
         dict(slot='panel', player=1, panel=1, rect=[0, 0, 492, 277], scale=.171)]


def setup(slots=None):
    sent = []
    d = OneCam(slots or SLOTS, lambda b: sent.append(copy.deepcopy(b)) or {'ok': True}, None,
               auto_feature=False, platform_every=0, map_every=0, quiet_views=False, tours=False, trio=False)
    a = dict(agent('astra', 40, 10, 20), surface='aquilo',
             attention=dict(platform='Asterion', kind='scanning', text='scanning on Asterion', age_s=0, far=True))
    d.agents_now = {'astra': a}
    d.watch_platforms(snap([a], [plat('Asterion', view=copy.deepcopy(VIEW))]), 1000)
    return d, a, sent


def no_refresh_cuts():
    d, a, sent = setup()
    for slot in d.slots:
        d.frame_on(slot, remotework.shot(d, a, 1000)[1], 'initial remote work', {}, 1000)
    for i in range(1, 201):
        now = 1000 + i * 1.3
        a['attention']['text'] = f'inspecting item {i} on Asterion'
        d.refresh_remote(d.agents_now, now)
        d.pan_step(now)
    cuts = [b for b in sent if not b['smooth']]
    assert len(cuts) == len(d.slots), f'{len(cuts)} cuts for {len(d.slots)} unchanged destinations'
    for slot in d.slots:
        t = d.state[slot['slot']]
        assert t['framed'] == t['since'] == 1000 and d.ready(slot['slot'], now)
        assert 'item 200' in t['work'] and t['sent'] > 1250  # fresh work keeps panning past the first 120 s
    glides = [b for b in sent if b['smooth']]
    assert glides and all(0 < b['speed'] <= 60 for b in glides)
    assert max(b['speed'] for b in glides) < 10, max(b['speed'] for b in glides)


def destination_changes():
    d, a, sent = setup([SLOTS[0]])
    d.frame_on(d.slots[0], remotework.shot(d, a, 1000)[1], 'initial', {}, 1000)
    d.pan_step(1015)
    original = copy.deepcopy(d.state['main'])
    assert remotework.same(original, remotework.shot(d, a, 1016)[1])
    # A request elsewhere on the same whole-ship view is metadata, not a new camera destination.
    a['attention']['position'] = dict(x=1, y=2)
    before = len(sent)
    d.refresh_remote(d.agents_now, 1016)
    assert len(sent) == before and d.state['main']['position'] == original['position']
    original = copy.deepcopy(d.state['main'])
    changed = copy.deepcopy(a)
    changed['attention']['platform'] = 'Other'
    d.plat_rows['Other'] = copy.deepcopy(d.plat_rows['Asterion'])
    assert not remotework.same(original, remotework.shot(d, changed, 1016)[1])
    for field, value in [('surface', 'platform-99'), ('zoom', .5), ('remote_work', False)]:
        changed = copy.deepcopy(remotework.shot(d, a, 1016)[1])
        changed[field] = value
        assert not remotework.same(original, changed), field
    a['attention'] = dict(surface='gleba', position=dict(x=50, y=60), kind='scanning', text='scanning on Gleba')
    d.sender = lambda b: {'ok': False}
    d.refresh_remote(d.agents_now, 1017)
    assert d.state['main'] == original  # failed new destinations cannot be marked acknowledged
    d.sender = lambda b: sent.append(copy.deepcopy(b)) or {'ok': True}
    d.refresh_remote(d.agents_now, 1018)
    assert d.state['main']['surface'] == 'gleba' and not sent[-1]['smooth']
    before = len(sent)
    d.refresh_remote(d.agents_now, 1019)
    assert len(sent) == before
    a['attention']['position'] = dict(x=150, y=160)
    d.refresh_remote(d.agents_now, 1020)
    assert len(sent) == before + 1 and not sent[-1]['smooth']
    a['attention']['position']['x'] = 250  # mutating the input must not mutate the acknowledged destination
    d.refresh_remote(d.agents_now, 1021)
    assert len(sent) == before + 2 and sent[-1]['position']['x'] == 250
    # Returning to a ship from an old story starts a new, slow pan on its bow.
    a['attention'] = dict(platform='Asterion', kind='scanning', text='scanning on Asterion')
    d.refresh_remote(d.agents_now, 1400)
    t = d.state['main']
    assert t['since'] == 1000 and t['position']['y'] == -5.2
    d.pan_step(1401)
    assert d.state['main']['position']['y'] == -5.2


def eased_return():
    d, a, _ = setup()
    t = dict(remotework.shot(d, a, 1000)[1], since=1000)
    ys = [d.pan_y(t, 1000 + i / 10) for i in range(1801)]
    assert min(ys) == -5.2 and max(ys) == 204.2
    deltas = [b - a for a, b in zip(ys, ys[1:])]
    assert min(deltas) < 0 < max(deltas) and max(abs(v) for v in deltas) <= .9
    for end in (-5.2, 204.2):
        assert all(abs(delta) <= .2 for y, delta in zip(ys, deltas) if y == end)
    # After a long scheduling gap, a catch-up glide must still satisfy cameras.lua's API limit.
    d.frame_on(d.slots[0], t, 'initial', {}, 1000)
    d.pan_step(1040)
    assert d.state['main']['glide'] == 60


def other_refreshes():
    # Attention keeps its destination in inset metadata, independently of the animated frame.
    d, a, sent = setup()
    d.state['main'] = dict(subject='astra', agents=['astra'], follow='astra', zoom=.75, since=1000)
    d.show_attention('panel', 'astra', a, a['attention'], {}, 1000)
    d.pan_step(1010)
    before = len(sent)
    d.maybe_attention(d.agents_now, {'astra': 1}, 1011)
    assert len(sent) == before and d.inset['moved'] == 1000
    # Featured whole-ship refresh and operator/aboard follow already preserve an unchanged pan's position.
    for mode in ('featured', 'operator', 'follow'):
        d, a, sent = setup([SLOTS[0]])
        shot = d.platform_target('Asterion', mode, 1300, agent='astra' if mode == 'follow' else None)
        d.frame_on(d.slots[0], shot, 'initial', {}, 1000)
        d.pan_step(1015)
        before = len(sent)
        current = copy.deepcopy(d.state['main']['position'])
        fresh = d.platform_target('Asterion', mode, 1300, agent='astra' if mode == 'follow' else None)
        if mode == 'featured':
            Featured.refresh(d, d.slots[0], d.state['main'], fresh, {}, 1016)
        else:
            d.platform_direct(fresh, {}, 1016)
        assert len(sent) == before and d.state['main']['position'] == current, mode
    # An operator's remote-work follow runs the full step path, not just refresh_remote.
    d, a, sent = setup([SLOTS[0]])
    d.set_follow('astra', 1400, now=1000)
    for i in range(120):
        d.step(snap([a], [plat('Asterion', view=VIEW)]), 1000 + i * 1.3)
    assert len(sent) > 100 and all(b['smooth'] for b in sent[1:])
    assert sum('speed' not in b for b in sent) == 1  # initial follow, then only glides


def replay():
    fixture = json.loads(FIXTURE.read_text())
    cuts = glides = 0
    max_speed = 0
    for segment in fixture['segments']:
        d, a, sent = setup([SLOTS[0]])
        a['name'] = segment['agent']
        a['display_name'] = segment['agent'].title()
        d.agents_now = {a['name']: a}
        start = segment['start']
        d.frame_on(d.slots[0], remotework.shot(d, a, start)[1], 'recorded entry', {}, start)
        for now, caption in segment['steps']:
            a['attention']['text'] = caption
            before = len(sent)
            d.refresh_remote(d.agents_now, now)
            d.pan_step(now)
            if fixture['start'] <= now < fixture['end']:
                emitted = sent[before:]
                cuts += sum(not b['smooth'] for b in emitted)
                glides += sum(b['smooth'] for b in emitted)
                max_speed = max(max_speed, max((b.get('speed', 0) for b in emitted), default=0))
    return dict(recorded=fixture['recorded'], replay=dict(segments=len(fixture['segments']),
                refresh_cutbacks=cuts, glides=glides, max_speed=max_speed))


if __name__ == '__main__':
    with contextlib.redirect_stdout(io.StringIO()):
        no_refresh_cuts()
        destination_changes()
        eased_return()
        other_refreshes()
        result = replay()
    assert result['replay']['refresh_cutbacks'] == 0, result
    assert result['replay']['glides'] > 100 and result['replay']['max_speed'] <= 60, result
    print(json.dumps(result, indent=2))
    print('remote pan: all passed')
