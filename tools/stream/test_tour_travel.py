#!/usr/bin/env python3
"""Quiet travel and fresh train coverage through the actual director, without a game connection."""
import contextlib
import copy
import io
import math

import basetour
import camerapath
from test_freshcam import chart_dir, world, agent, snap
from test_ship_survey import Camera


def machinery():
    tours = basetour.Tours(chart_dir())
    memory = basetour.Memory()
    for i in range(6):
        shot = basetour.choose(tours, memory, 1000 + i*700)
        route = shot['scene']['route']
        assert len(route) == 2 and math.dist(tuple(route[0]['position'].values()), tuple(route[1]['position'].values())) >= 32
        assert all('iron gear wheel' == r['label'] for r in route)
        rests = [0, 0]
        for tick in range(round(shot['seconds']*10)):
            x,y,z = camerapath.at(shot['move'], tick/10)
            assert basetour.frame_ok('nauvis', x, y, z, 1, basetour.index_charted(tours.out_dir))
            for k,r in enumerate(route):
                if math.hypot(x-r['position']['x'], y-r['position']['y']) < .01 and z >= .74:
                    rests[k] += .1
        assert min(rests) >= 7.9, rests
        memory.seen(shot['scene'], 1000+i*700)
    # A dense compact factory gets a stable detail, never an invented pan off its machines.
    pts = [(x, y) for x in range(4) for y in range(4)]
    c = dict(position=dict(x=1,y=1), region='nauvis:0:0')
    shot = basetour.varied_plan('nauvis', '', lambda *args: True, 1, pts, c, 0)
    assert len(shot['scene']['route']) == 1 and 'closeup' in shot['label']
    assert len({camerapath.at(shot['move'], t)[:2] for t in range(29)}) == 1
    assert basetour.varied_plan('nauvis', '', lambda *args: False, 1, pts, c, 0) is None


def train(t, speed=0, y=100):
    return dict(id='fulgora:15', number=15, surface='fulgora', position=dict(x=-43.,y=y),
                speed=speed, t=t, stop='Scrap North', cargo='scrap 2700', label='Train 15 · at Scrap North · scrap 2700')


def quiet_world(cams=1):
    d,_ = world(cams, auto_feature=False, tour_every=0)
    camera = Camera()
    d.sender = camera
    d.started = 1000
    team = [agent('luna',0,0,3,activity='thinking',active=False)]
    for t in range(1000,1065):
        tick(d,camera,snap(team),t)
    return d,camera,team


def tick(d,camera,s,t):
    camera.advance(t)
    d.on_air = copy.deepcopy(d.state)
    return d.step(s,t)


def train_program():
    d,c,team = quiet_world()
    d.set_tours(basetour.Tours(chart_dir()))
    # A train shown in a prior quiet slot still wins over a never-shown reusable tour.
    d.quiet_shown['train'] = 500
    s=snap(team);s['trains']=[train(1065)]
    public=tick(d,c,s,1065)
    assert 'Train 15' in public['main']['look']['label'] and 'live' in public['main']['look']['label']
    assert d.state[d.onair].get('train') and not d.state[d.onair].get('tour')
    assert public['main']['zoom'] == .8, 'stationary rolling stock should be readable in the program'
    until=d.state[d.onair]['until']
    for t in range(1066,1078):
        public=tick(d,c,s,t)
        assert d.state[d.onair].get('train'), (t,d.cuts)
        assert d.state[d.onair]['until']==until
    tick(d,c,s,1078)
    assert not d.state[d.onair].get('train'), 'expiry releases immediately; ordinary dwell must not retain stale trains'
    assert d.train_shown['fulgora:15']==1065

    # Moving train updates glide rather than repeating the opening jump; they never renew the shot deadline.
    d,c,team=quiet_world()
    for t in range(1065,1090):
        s=snap(team);s['trains']=[train(t,72,100+5*(t-1065))]
        tick(d,c,s,t)
        if t < 1089:
            assert d.state[d.onair].get('train')
            assert 'settle' not in d.state[d.onair]
    assert not d.state[d.onair].get('train'), '24-second maximum survives continuous fresh replies'
    moves=[r for r in c.calls if r.get('surface')=='fulgora' and r.get('position')]
    assert not moves[0]['smooth'] and all(r['smooth'] and r['speed']==40 for r in moves[1:])
    d,c,team=quiet_world()
    s=snap(team);s['trains']=[train(1065,72)]
    tick(d,c,s,1065)
    tick(d,c,s,1069)
    assert not d.state[d.onair].get('train'), 'a lone moving receipt cannot promise eight seconds'


def tour_program():
    for native in (True, False):
        d,c,team=quiet_world()
        c.native=native
        d.set_tours(basetour.Tours(chart_dir()))
        tick(d,c,snap(team),1065)
        shot=copy.deepcopy(d.state[d.onair])
        assert shot.get('tour') and shot['move_ok']==native
        rests=[0,0]
        for i in range(2131,round(2*shot['until'])):
            t=i/2
            tick(d,c,snap(team),t)
            assert d.state[d.onair].get('tour'), (native,t,d.cuts)
            for k,r in enumerate(shot['tour']['scene']['route']):
                if math.hypot(c.pose['x']-r['position']['x'],c.pose['y']-r['position']['y']) < .2 and c.pose['zoom'] >= .74:
                    rests[k]+=.5
        assert min(rests)>=7.5,(native,rests)
        assert not any(b.get('map') for b in c.calls)
        assert all(b.get('zoom',1)>=.3 for b in c.calls)
        tick(d,c,snap(team),shot['until']+1)
        assert not d.state[d.onair].get('tour')
    # Slow native movement receives its full final readable dwell after observed arrival.
    d,c,team=quiet_world();c.speed=.5;d.set_tours(basetour.Tours(chart_dir()))
    tick(d,c,snap(team),1065)
    shot=copy.deepcopy(d.state[d.onair]);arrived=None
    for i in range(2131,2340):
        t=i/2;tick(d,c,snap(team),t)
        cur=d.state[d.onair]
        if cur.get('tour_arrived') is not None:arrived=cur['tour_arrived']
        if not cur.get('tour'):
            assert arrived and t-arrived>=8 and arrived>shot['until'],(arrived,t,shot['until'])
            break
    else:assert False,'slow tour never released'
    # An unavailable receipt does not turn the tour into an unbounded hold.
    d,c,team=quiet_world();d.set_tours(basetour.Tours(chart_dir()))
    tick(d,c,snap(team),1065);shot=copy.deepcopy(d.state[d.onair])
    send=d.sender;d.sender=lambda body: dict(ok=False) if body.get('observe') else send(body)
    for i in range(2131,round(2*(shot['until']+47))):tick(d,c,snap(team),i/2)
    assert not d.state[d.onair].get('tour')


def eligibility():
    d,c,team=quiet_world()
    for row in (train(1060), train(1066), dict(train(1065), speed=float('nan')), dict(train(1065), position=None)):
        d.train_rows=[row]
        assert d.train_target(1065) is None
    d.train_rows=[train(1061)]
    assert d.train_target(1065), 'exactly eight seconds of stationary freshness remains'
    # Standby delay cannot consume all of the reserved dwell or air an expired moving receipt.
    d,c,team=quiet_world(3)
    d.train_rows=[train(1061)]
    assert d.train_target(1065) is None
    s=snap(team);s['trains']=[train(1065,72)]
    tick(d,c,s,1065)
    assert d.pending
    tick(d,c,s,1069)
    assert not d.pending and not d.state[d.onair].get('train')
    # Host/operator/segment/fight and fresh busy work remain ahead of quiet train selection.
    for mode in ('host','operator','segment','fight','busy'):
        d,c,team=quiet_world()
        s=snap(team);s['trains']=[train(1065)]
        segment=None
        if mode=='host':d.set_host(dict(until=1100,by='host',label='host'),1065)
        elif mode=='operator':d.set_follow('luna',1100,now=1065)
        elif mode=='segment':segment=dict(id='piece',label='Piece',position=dict(x=0,y=0),surface='nauvis',zoom=.7,until=1100)
        elif mode=='fight':s['fights']=[dict(key='loss',kind='loss',first=1065,last=1065,losses=[1065],text='4 machines destroyed',position=dict(x=150,y=0,surface='nauvis'))]
        else:team[0].update(active='mine',activity='mining',plan=dict(kind='mine'))
        c.advance(1065);d.step(s,1065,segment)
        assert not d.state[d.onair].get('train'), mode
    d,c,team=quiet_world()
    c.fail=True
    s=snap(team);s['trains']=[train(1065)]
    tick(d,c,s,1065)
    assert d.send_pending and not d.train_shown and d.last_quiet < 0
    c.fail=False
    team[0].update(active='mine',activity='mining',plan=dict(kind='mine'))
    tick(d,c,s,1066)
    assert not d.state[d.onair].get('train') and not d.send_pending


def wide_ship_context():
    from test_platformcam import plat
    from test_ship_survey import VIEW
    d,c,team=quiet_world()
    s=snap(team);s['space']=dict(platforms=[plat('Asterion',view=VIEW)])
    d.watch_platforms(s,1065);d.step_t=1065
    target=d.visit_target('Asterion',25,1065)
    assert target.get('wide_context') and target.get('survey')
    d.urgent(target,'private quiet visit',{'luna':1},1065)
    for t in range(1065,1073):
        public=tick(d,c,s,t)
        assert 'wide ship overview' in public['main']['platform']['label']
    tick(d,c,s,1073)
    cur=d.state[d.onair]
    assert cur.get('quiet_detail') and cur['zoom']>=.7 and not cur.get('survey') and not cur.get('wide_context')
    assert cur['until'] <= 1073+d.cfg['quiet_platform_hold'], 'no leftover long survey hold'
    assert 'machinery closeup' in d.public(1073)['main']['platform']['label']
    d.step_t=1200
    assert d.platform_target('Asterion','featured',1300,overview=True).get('quiet_detail')
    assert d.platform_target('Asterion','operator',1300,overview=True).get('survey'), 'manual survey remains available'
    d.step_t=1666
    assert d.platform_target('Asterion','visit',1800,overview=True).get('wide_context')
    assert not any(b.get('map') for b in c.calls)

    # A calm featured stint also leaves its wide opening, then changes detail instead of freezing for four minutes.
    d,c,team=quiet_world()
    d.featured.set('Asterion',at=1400,now=1065)
    frames=[]
    for t in range(1065,1140):
        public=tick(d,c,s,t)
        cur=d.state[d.onair]
        frames.append((t,cur.get('wide_context'),cur.get('zoom'),cur.get('position')))
        if t>=1074:
            assert not cur.get('wide_context') and cur['zoom']>=.7,(t,cur)
    assert any(r[1] for r in frames), 'featured opening is explicitly wide'
    assert len({str(r[3]) for r in frames if r[0]>=1074})>=2, 'featured details change'


if __name__=='__main__':
    with contextlib.redirect_stdout(io.StringIO()):
        machinery();train_program();tour_program();eligibility();wide_ship_context()
    print('tour travel: machinery routes, closeup dwells, chart envelope; train program, expiry, glide, deadline, priorities and retries passed')
