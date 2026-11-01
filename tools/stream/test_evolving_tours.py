#!/usr/bin/env python3
"""Evolving quiet scenes: real planner/director, journal ingestion and camera receipts, offline only."""
import contextlib
import copy
import io
import json
from datetime import datetime, timezone
from pathlib import Path

import basetour
import camerapath
from test_freshcam import chart_dir, world, agent, snap
from test_ship_survey import setup, run
from work import WorkFeed
from model import Model


def regions_and_composition():
    tours = basetour.Tours(chart_dir())
    memory = basetour.Memory()
    plans = []
    for now in (1000, 1060, 1120, 1180):
        p = basetour.choose(tours, memory, now)
        assert p and p['seconds'] >= 30
        before = copy.deepcopy(p)
        memory.seen(p['scene'], now)
        plans.append(p)
        memory.note('nauvis', dict(x=200, y=10), 'recent build', 'once', 1000, now)
        assert p == before, 'observations never mutate a selected shot'
    assert len({p['scene']['region'] for p in plans}) >= 3
    assert len({p['zoom'] for p in plans}) >= 2
    assert len({p['seconds'] for p in plans}) >= 2
    for p in plans:
        for t in range(int(p['seconds'])+1):
            x, y, z = camerapath.at(p['move'], t)
            assert basetour.frame_ok('nauvis', x, y, z, 1, basetour.index_charted(tours.out_dir))
    # A repeated fact does not grow younger on every poll; a changed layout does, without an index update.
    memory = basetour.Memory()
    p = basetour.choose(tours, memory, 2000)
    memory.note('nauvis', dict(x=200, y=10), 'recent build', 'build1', 2000, 2000)
    fresh = basetour.choose(tours, memory, 2001)
    assert 'recent build' in fresh['label'] and fresh['scene']['position']['x'] == 200
    memory.seen(fresh['scene'], 2001)
    memory.note('nauvis', dict(x=200, y=10), 'recent build', 'build1', 2020, 2020)
    assert memory.events[fresh['scene']['region']]['t'] == 2000
    other = basetour.choose(tours, memory, 2020)
    assert other['scene']['region'] != fresh['scene']['region']
    path = Path(tours.out_dir)/'nauvis/0_0.labels.json'
    data = json.loads(path.read_text());data['recipes'][0][2] = 'copper-cable';path.write_text(json.dumps(data))
    changed = basetour.choose(tours, memory, 2021)
    assert 'production layout changed' in changed['label']
    # Every region recently shown, no news: let the ordinary calm fallback run.
    memory.events.clear()
    for x in (20, 80, 150, 210):
        memory.seen(dict(region=basetour.region('nauvis', dict(x=x,y=10))), 2100)
    assert basetour.choose(tours, memory, 2101) is None
    # No route across uncharted ground, including the interpolated frames.
    class Uncharted:
        def known(self, surface): return []
    tours.chart = Uncharted()
    assert basetour.choose(tours, basetour.Memory(), 3000) is None


def fresh_facts():
    m = basetour.Memory()
    ship = dict(name='S', where='Nauvis', view=dict(surface='platform-1', hub=dict(x=0,y=0), machines=[]))
    s = dict(agents=[], space=dict(platforms=[ship]))
    m.observe(s, 1000)
    assert not m.events, 'first read is not a change'
    ship['where'] = 'Gleba';m.observe(s, 1010)
    assert next(iter(m.events.values()))['why'] == 'recent arrival'
    original_memory=m
    m=basetour.Memory()
    ship['view']['machines'] = [dict(x=0,y=130,w=0),dict(x=4,y=130,w=0)]
    m.observe(s,1010)
    ship['view']['machines'][0]['w'] = 1;m.observe(s,1011);m.observe(s,1040)
    assert 'platform-1:0:2' not in m.events
    m.observe(s,1041)
    assert 'production changed' in m.events['platform-1:0:2']['why']
    s['work']=[dict(action='inspect',surface='nauvis',position=dict(x=999,y=999),t=1041)]
    m.observe(s,1041)
    assert 'nauvis:15:15' not in m.events, 'repeated reads are not fresh work'
    m=original_memory
    s['work']=[]
    s['agents'] = [dict(name='a', surface='nauvis', position=dict(x=100,y=100), active='repair')]
    m.observe(s, 1011);m.observe(s, 1020)
    repair = m.events['nauvis:1:1'];assert repair['t'] == 1011
    s['fights'] = [dict(key='f', first=1021, last=1022, losses=[1021], position=dict(x=400,y=100,surface='nauvis'))]
    m.observe(s, 1022)
    assert m.events['nauvis:6:1']['why'] == 'recent damage'
    s['fights'][0]['last'] = 1050;m.observe(s, 1050)
    assert m.events['nauvis:6:1']['t'] == 1021
    m.observe(dict(agents=[]), 2000);assert not m.events
    for i in range(800):
        m.note('nauvis', dict(x=i*64,y=0), 'work', i, 2000, 2000)
        m.seen(dict(region=f'nauvis:{i}:0'), 2000)
    m.observe(dict(agents=[]), 2000)
    assert len(m.events)<=256 and len(m.shown)<=512


def survey_details():
    d, c, _ = setup()
    q = next(iter(d.surveys.values()))
    d.tour_memory.note('platform-16', dict(x=5,y=220), 'recent repairs', 'r1', 1000, 1000)
    for i in range(200):
        run(d,c,1000+i*.5,1000+(i+1)*.5)
        if q.phase == 'detail_dwell':break
    assert q.active_detail['identity'] == 'r1', q.public()
    goal, detail = copy.deepcopy(q.goal), copy.deepcopy(q.active_detail)
    d.tour_memory.note('platform-16', dict(x=20,y=300), 'recent damage', 'd1', c.now, c.now)
    run(d,c,c.now,c.now+3)
    assert q.goal == goal and q.active_detail['label'] == detail['label']
    assert 'recent repairs' in d.state['main']['platform']['label']
    from featured import Featured
    fresh=d.platform_target('Asterion','operator',1240,overview=True)
    Featured.refresh(d,d.slot('main'),d.state['main'],fresh,{},c.now)
    assert 'recent repairs' in d.state['main']['platform']['label'], 'refresh without a receipt keeps detail caption'
    d.platform_direct(fresh,{},c.now)
    assert 'recent repairs' in d.state['main']['platform']['label']
    assert d.tour_memory.shown, 'a visible settled detail earns credit'
    run(d,c,c.now,1240)
    assert q.coverage == [(-58,384)] and q.ends == {'bow','stern'}
    spec = copy.deepcopy(q.spec);spec['reverse'] = True
    reverse = camerapath.Survey(spec,2000,2240)
    assert reverse.phase == 'stern_dwell' and reverse.direction == -1


def train_rows():
    f = basetour.Trains()
    def ingest(t, pos, speed=0):
        stamp = datetime.fromtimestamp(t, timezone.utc).isoformat()
        f.ingest('a',dict(event='request',request=dict(id='r',action='train')))
        f.ingest('a',dict(event='response',at=stamp,response=dict(id='r',ok=True,result=dict(
            id=15,front=dict(surface='fulgora',position=pos),speed_kmh=speed,
            heading_to=dict(stop='Scrap South'),cargo='scrap 2700'))))
    ingest(1000,dict(x=-43,y=100))
    row = f.current(1000)[0]
    assert row['stop']=='Scrap South' and row['cargo']=='scrap 2700'
    assert not f.current(1013) and not f.current(999)
    ingest(1014,dict(x=-43,y=120),74)
    assert not f.current(1018)
    d, sent = world(1, auto_feature=False, tour_every=0)
    d.train_rows = f.current(1014)
    shot = d.train_target(1014);assert shot and shot['until'] == 1038
    d.apply(d.slot(d.onair),shot,'train',{},1014)
    ingest(1016,dict(x=-40,y=130),74);d.train_rows=f.current(1016)
    d.train_step(1016)
    assert d.state[d.onair]['position'] == dict(x=-40,y=130)
    assert d.state[d.onair]['until']==1038 and d.state[d.onair]['zoom']==.5
    assert d.state[d.onair]['look']['label']==shot['look']['label']
    d.train_rows=[];d.train_step(1020);assert d.state[d.onair]['until']==1020
    # Failed camera sends don't earn shown credit or replace the last acknowledged view.
    d.sender=lambda b: dict(ok=False)
    old=copy.deepcopy(d.state[d.onair])
    from onecam import CameraPending
    try: d.apply(d.slot(d.onair),shot,'train',{},1020)
    except CameraPending: pass
    assert d.state[d.onair]==old and not d.train_shown
    d.sender=lambda b: sent.append(b) or dict(ok=True)
    n=len(sent);d.retry_sends(1025)
    assert len(sent)==n and not d.send_pending, 'expired train sends are not retried'
    return row


def priorities_and_feed():
    row=train_rows()
    for override in ('host','operator','urgent'):
        d,sent=world(1,auto_feature=False,tour_every=0)
        team=[agent('luna',0,0,3,activity='thinking',active=False)]
        for t in range(1000,1060):d.step(snap(team),t)
        s=snap(team);s['trains']=[dict(row,t=1060)]
        if override=='host': d.set_host({'until':1100,'by':'host','label':'host'},1060)
        elif override=='operator':
            from lookcam import LookControl
            from test_look import Chart
            LookControl(d,None,Chart()).request(dict(surface='nauvis',x=0,y=0,seconds=30),1060)
        else:
            s['fights']=[dict(key='loss',kind='loss',first=1060,last=1060,losses=[1060],
                               text='4 assembling machines destroyed',position=dict(x=150,y=0,surface='nauvis'))]
        d.step(s,1060)
        assert not (d.state[d.onair] or {}).get('train'), override
    # The actual WorkFeed -> live observation -> Model -> director snapshot path, not an invented input field.
    import tempfile
    with tempfile.TemporaryDirectory() as root:
        path=Path(root)/'a';path.mkdir();journal=path/'journal.jsonl'
        wf=WorkFeed(root,['a']);journal.write_text('');wf.poll()
        rows=[dict(event='request',request=dict(id='r',action='train')),
              dict(event='response',at='2026-01-01T00:00:00Z',response=dict(id='r',ok=True,result=dict(
                  id=15,front=dict(surface='fulgora',position=dict(x=0,y=0)),cargo='scrap 100')))]
        journal.write_text(''.join(json.dumps(r)+'\n' for r in rows));wf.poll()
        t=datetime(2026,1,1,tzinfo=timezone.utc).timestamp()
        trains=wf.trains.current(t);assert trains
        m=Model({});m.ingest(dict(agents=[],trains=trains),t)
        assert m.snapshot(now=t)['trains']==trains


if __name__ == '__main__':
    with contextlib.redirect_stdout(io.StringIO()):
        regions_and_composition();fresh_facts();survey_details();priorities_and_feed()
    print('evolving tours: regions, facts, composition, survey receipts, train feed/freshness and priorities passed')
