#!/usr/bin/env python3
"""Every ordinary camera command stays rendered; explicit map shots may zoom out. Stub sends only."""
import contextlib
import copy
import io
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import camerapath
from director import Director, WORLD_ZOOM_MIN, PANEL_ZOOM_MIN
from test_featured import setup, run, SHIP

SLOTS = [{'slot': 'main', 'player': 3},
         {'slot': 'panel', 'player': 3, 'panel': 1, 'rect': [2388, 0, 492, 277], 'scale': .171}]


def commands():
    sent = []
    d = Director(SLOTS, lambda b: sent.append(copy.deepcopy(b)) or {'ok': True}, None)
    base = dict(position={'x': 0, 'y': 0}, surface='platform-22', agents=[], subject='@platform', since=0)
    for slot in SLOTS:
        floor = PANEL_ZOOM_MIN if slot.get('panel') else WORLD_ZOOM_MIN
        for exact in (False, True):
            for z in (.001, .03, .05, .3, 1):
                assert d.apply(slot, dict(base, zoom=z, exact_zoom=exact), 'test', {}, 10)
                assert sent[-1]['zoom'] >= floor, sent[-1]
                assert d.state[slot['slot']]['game_zoom'] == sent[-1]['zoom']
        assert d.apply(slot, dict(base, zoom=.02, exact_zoom=True, map=True), 'map', {}, 11)
        assert sent[-1]['zoom'] < floor, sent[-1]
        assert bool(sent[-1].get('map')) == (not bool(slot.get('panel')))
    move = {'segments': [{'pts': [{'x': 0, 'y': 0, 'zoom': .03}, {'x': 40, 'y': 0, 'zoom': .04},
                                  {'x': 40, 'y': 80, 'zoom': .8}], 't0': 0, 't1': 10, 'ease': 'inout'}]}
    original = copy.deepcopy(move)
    assert d.apply(SLOTS[0], dict(base, zoom=.03, exact_zoom=True, move=move), 'pan', {}, 12)
    actual = sent[-1]['move']
    assert move == original  # neither a caller's path nor another camera is mutated
    assert all(p['zoom'] >= WORLD_ZOOM_MIN for p in camerapath.points(actual))
    assert d.state['main']['move'] == actual
    assert all(camerapath.at(actual, t / 10)[2] >= WORLD_ZOOM_MIN for t in range(101))
    # Failed sends and unchanged retries use the same capped geometry.
    d.sender = lambda b: sent.append(copy.deepcopy(b)) or {'ok': False}
    assert not d.apply(SLOTS[1], dict(base, zoom=.01), 'pending', {}, 13)
    failed = sent[-1]
    d.sender = lambda b: sent.append(copy.deepcopy(b)) or {'ok': True}
    d.retry_sends(14)
    assert sent[-1] == failed and sent[-1]['zoom'] >= PANEL_ZOOM_MIN


def real_shots():
    d, sent = setup(SLOTS)
    ship = copy.deepcopy(SHIP)
    ship['view'].update(left=-600, right=600, top=-1000, bottom=1000)
    rows = run(d, 1000, 1500, ship=ship)
    assert any((r.get('inset') or {}).get('platform') for _, r in rows)
    assert {'bow defense', 'whole ship'} <= {
        (r.get('main', {}).get('platform') or {}).get('framing') for _, r in rows}
    assert any(b.get('panel') for b in sent)
    for b in sent:
        if not b.get('map') and 'zoom' in b:
            floor = PANEL_ZOOM_MIN if b.get('panel') else WORLD_ZOOM_MIN
            assert b['zoom'] >= floor, b
            if b.get('move'):
                assert all(p['zoom'] >= floor for p in camerapath.points(b['move']))


if __name__ == '__main__':
    with contextlib.redirect_stdout(io.StringIO()):
        commands(); real_shots()
    print('zoom floor: ok (main, panel scale, exact fits, whole ship, pan interpolation, retry, explicit map)')
