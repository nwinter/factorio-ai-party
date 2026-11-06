#!/usr/bin/env python3
"""Visible identity, ordinary arrival/dwell, urgent resumption and flight action; entirely offline."""
import contextlib
import copy
import io

from onecam import OneCam, CameraPending
from platformmetrics import selected
from test_onecam import agent
from test_platformcam import plat, snap, VIEW
from test_ship_survey import Camera
from test_bowcam import BOW_VIEW


def director(camera=None):
    camera = camera or Camera()
    d = OneCam([dict(slot='main', player=1)], camera, None, auto_feature=False,
               trio=False, quiet_views=False, tours=False, platform_every=0, map_every=0, bow=False)
    d.onair_since = 1000
    return d, camera


def identity():
    d, _ = director()
    ships = [plat('Asterion'), plat('Resolute', view=dict(VIEW, surface='platform-2'))]
    d.watch_platforms(snap([], ships), 1000)
    shot = d.platform_target('Asterion', 'work', 1100, agent='sol')
    # Stale ownership metadata cannot name a different ship than the acknowledged surface.
    shot.update(surface='platform-2', work='Sol checking Asterion', remote_work=True)
    d.frame_on(d.slots[0], shot, 'fixture', {}, 1000)
    main = d.public(1000)['main']
    assert main['ship']['name'] == main['platform']['name'] == 'Resolute'
    assert 'Asterion' not in main['work'] and main['owner'] == 'sol' and not main['body_visible']
    state = snap([], ships)
    state.update(cameras={'main': main}, onair={'platform': {'name': 'Asterion'}},
                 featured_platform={'name': 'Asterion', 'status': 'active'}, replay={'playing': False})
    assert selected(state)['name'] == 'Resolute'
    for main in ({}, {'map': 'Nauvis'}, {'frame': {'surface': 'nauvis'}}):
        state['cameras']['main'] = main
        assert selected(state) is None


def closeup():
    d, camera = director(Camera(speed=.05))
    d.watch_platforms(snap([], [plat('Asterion')]), 1000)
    target = d.platform_target('Asterion', 'work', 1200, agent='sol')
    target.update(build=True, closeup=dict(position=dict(x=40, y=50), zoom=.9, caption='Sol repairing the guns'))
    d.frame_on(d.slots[0], target, 'work', {}, 1000)
    old = copy.deepcopy(d.state)
    camera.fail = True
    try:
        d.closeup_step(1008)
        assert False, 'failed send must stop before committing closeup'
    except CameraPending:
        pass
    assert d.state == old and not d.state['main']['closeup'].get('done')
    # A late successful retry starts its own arrival clock, not the failed request's clock.
    camera.fail = False
    camera.advance(1060)
    d.retry_sends(1060)
    assert d.state['main']['settle']['sent'] == 1060
    assert d.state['main']['closeup']['done'] == 1060
    arrived = None
    for t in range(1060, 1100):
        camera.advance(t)
        # Hidden/compositor-old frames cannot earn dwell.
        d.on_air = dict(main=None) if t < 1063 else copy.deepcopy(d.state)
        d.arrival_step(t)
        at = d.state['main']['settle']['arrived']
        if at is not None and arrived is None:
            arrived = at
        if arrived is None or t < arrived + 8:
            assert d.ordinary_busy(t)
            assert d.cue_decision('sol', t, {}, None)[0] != 'cut'
        if arrived is not None and t >= arrived + 8:
            assert not d.ordinary_busy(t)
            break
    assert arrived is not None and arrived > 1063, arrived
    # An arrival near the missing-receipt timeout still earns the entire dwell.
    d.state['main']['settle'] = dict(sent=1060, arrived=1104)
    assert d.ordinary_busy(1111) and not d.ordinary_busy(1112)
    d.state['main']['settle'] = dict(sent=1060, arrived=None)
    assert d.ordinary_busy(1104) and not d.ordinary_busy(1105)
    # Urgency bypasses the hold, then the useful work resumes using the existing resume slot.
    d, camera = director()
    d.watch_platforms(snap([], [plat('Asterion')]), 1000)
    d.frame_on(d.slots[0], target, 'work', {}, 1000)
    urgent = dict(agents=[], subject='@attack', position=dict(x=100, y=100),
                  surface='nauvis', zoom=.7, until=1005)
    d.urgent(urgent, 'urgent loss', {}, 1002)
    assert d.state['main']['subject'] == '@attack' and d.resume['shot']['closeup']
    d.direct({}, {}, [], 1006)
    assert d.state['main']['platform']['name'] == 'Asterion' and d.resume is None
    assert d.ordinary_busy(1006)


def stories():
    d, camera = director()
    d.watch_platforms(snap([], [plat('Asterion')]), 1000)
    state = dict(stories=[dict(key='qualification', platform='Asterion', caption='Asterion qualification', agent='sol')])
    camera.fail = True
    try:
        d.maybe_story(state, {}, {}, 1000)
        assert False
    except CameraPending:
        pass
    assert 'qualification' not in d.stories_shown
    camera.fail = False
    d.maybe_story(state, {}, {}, 1001)
    d.maybe_story(state, {}, {}, 1002)
    d.urgent(dict(agents=[], subject='@attack', position=dict(x=0,y=0), surface='nauvis', zoom=.7,
                  until=1007), 'loss', {}, 1003)
    d.maybe_story(state, {}, {}, 1004)
    assert 'qualification' not in d.stories_shown
    d.maybe_story(state, {}, {}, 1008)
    assert d.state['main']['platform']['story'] == 'qualification'


def busy_and_quiet():
    d, camera = director()
    a = dict(agent('sol', 0, 0, 20), surface='nauvis')
    changes = []
    previous = None
    # The real director receives a new remote destination every two seconds.
    # Keep the latest one, without an A-B-C sequence of unreadable frames.
    for t in range(1000, 1064):
        surface = ('gleba', 'vulcanus', 'fulgora')[(t // 2) % 3]
        a['attention'] = dict(surface=surface, position=dict(x=50,y=50), kind='building',
                              text='building on '+surface, age_s=0)
        camera.advance(t)
        d.on_air = copy.deepcopy(d.state)
        d.step(snap([a]), t)
        current = d.public(t)['main']['frame']['surface']
        if current != previous:
            changes.append(t)
            previous = current
    assert len(changes) >= 4 and all(b-a >= 8 for a,b in zip(changes,changes[1:])), changes
    before = len([c for c in camera.calls if not c.get('observe')])
    for t in range(1064, 1110):
        a['attention']['text'] = 'building on '+surface+' item '+str(t)
        camera.advance(t)
        d.on_air = copy.deepcopy(d.state)
        d.step(snap([a]), t)
    after = len([c for c in camera.calls if not c.get('observe')])
    assert after - before <= 1, (before, after)


def flight():
    d, camera = director()
    view = dict(copy.deepcopy(BOW_VIEW), guns=[dict(x=-20,y=-45,range=35),dict(x=20,y=-45,range=35)],
                machines=[dict(x=0,y=100,w=1)])
    ship = plat('Asterion', 'solar-system-edge->shattered-planet 20%', view=view)
    d.featured.set('Asterion', arrival='shattered-planet', now=1000)
    frames = set()
    for t in range(1000, 1240):
        camera.advance(t)
        d.on_air = copy.deepcopy(d.state)
        d.step(snap([], [ship]), t)
        cur = d.state['main']
        frames.add(cur['platform']['framing'])
        assert not cur.get('survey')
    assert {'bow and approaching asteroids','bow guns','working production'} <= frames, frames
    d.featured.started = 1000
    d.ship_metrics = (1120, dict(platform='Asterion', kills_min=60, age_s=0))
    d.watch_platforms(snap([], [ship]), 1120)
    assert d.featured.news(d, {}, 'Asterion', 1120) == 'shooting'
    assert d.featured.shot(d, 'Asterion', 1120)['platform']['framing'] != 'working production'
    d.ship_metrics = (1090, dict(platform='Asterion', kills_min=60, age_s=0))
    assert d.featured.shot(d, 'Asterion', 1090)['platform']['framing'] == 'guns in action'
    d.ship_metrics = (0, {})
    work = dict(agent='sol', position=dict(x=10,y=90), action='repair', verb='repairing')
    assert d.featured.shot(d, 'Asterion', 1120, work=work)['platform']['framing'] == 'repair/build detail'
    ship['danger'] = dict(kind='fire', last=1120)
    assert d.featured.shot(d, 'Asterion', 1120, work=work)['platform']['framing'] != 'repair/build detail'
    ship.pop('danger')
    # Damage elsewhere is urgent even while the feature owns the main camera.
    other = plat('Courier', view=dict(VIEW, surface='platform-9'))
    other['danger'] = dict(kind='fire', last=1241, level=1000, reason='Courier lost a turret')
    d.step(snap([], [ship, other]), 1241)
    assert d.state['main']['platform']['name'] == 'Courier'
    assert d.state['main']['platform']['why'] == 'danger'


if __name__ == '__main__':
    with contextlib.redirect_stdout(io.StringIO()):
        identity(); closeup(); stories(); busy_and_quiet(); flight()
    print('camera polish: visible identity; failed/slow/hidden closeup; cue dwell; urgent resume; story retry; flight action passed')
