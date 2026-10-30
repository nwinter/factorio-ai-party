#!/usr/bin/env python3
"""Featured platform: real director, stub sends, simulated clocks; no game or OBS access."""
import contextlib
import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from featured import Featured, NAME, MAIN_S, CONTEXT_S
from onecam import OneCam
from test_onecam import world, agent
from test_platformcam import plat, snap
from test_bowcam import BOW_VIEW

TEAM = [agent('sol', 0, 0, 5), agent('astra', 400, 0, 20)]
SHIP = plat('Resolute', at='solar-system-edge->shattered-planet 20%', view=BOW_VIEW)


def setup(slots=None, path=None):
    cfg = dict(platform_every=0, map_every=0, bow=False, quiet_views=False, tours=False, trio=False)
    if slots:
        sent = []
        d = OneCam(slots, lambda b: sent.append(b) or {'ok': True}, None, **cfg)
    else:
        d, sent = world(**cfg)
    d.featured = Featured(path)
    d.featured.set('Resolute', arrival='shattered-planet', attempt_end=True, now=1000)
    return d, sent


def run(d, first, end, ship=SHIP, **extra):
    rows = []
    for t in range(first, end):
        s = snap(copy.deepcopy(TEAM), [copy.deepcopy(ship)] if ship else [], **extra)
        rows.append((t, copy.deepcopy(d.step(s, t))))
    return rows


def name(row, key='main'):
    return ((row.get(key) or {}).get('platform') or {}).get('name')


def share_dwell_inset():
    for slots in (None, [{'slot': 'main', 'player': 3}, {'slot': 'panel', 'player': 3, 'panel': 1, 'rect': [2388, 0, 492, 277], 'scale': 0.171}],
                  [{'slot': 'main', 'player': 3}]):
        d, sent = setup(slots)
        rows = run(d, 1000, 2000)
        share = sum(name(r) == 'Resolute' for _, r in rows) / len(rows)
        assert .65 < share < .85, share
        spans, start = [], None
        for t, r in rows:
            if name(r) == 'Resolute' and start is None:
                start = t
            elif name(r) != 'Resolute' and start is not None:
                spans.append(t - start); start = None
        assert spans and min(spans) >= MAIN_S + CONTEXT_S, spans
        frames = {(r['main']['platform']['framing']) for _, r in rows if name(r) == 'Resolute'}
        assert frames == {'bow defense', 'whole ship'}, frames
        away = [(t, r) for t, r in rows if t > 1010 and name(r) != 'Resolute']
        if slots is None or len(slots) > 1:
            assert all(name(r, 'inset') == 'Resolute' for t, r in away), away[:3]
        else:
            assert all('inset' not in r for _, r in rows)
        # Ground-based remote work never changes the featured shot into the engineer's body.
        assert all(r['main']['frame'].get('surface') == BOW_VIEW['surface'] for _, r in rows if name(r) == 'Resolute')
        assert any(b.get('surface') == BOW_VIEW['surface'] for b in sent)
        print('featured share',round(share,3),'uninterrupted ship spans',spans)


def urgent_and_news():
    for kind,text in [('attack','Base under attack'),('death','Sol died'),('loss','26 lost near (400, 400): 26 gun turret')]:
        d,_ = setup()
        run(d,1000,1020)
        alert={'id':kind,'kind':kind,'t':1020,'text':text,'position':{'x':400,'y':400,'surface':'nauvis'}}
        if kind=='death': alert['agent']='sol'
        rows=run(d,1020,1025,alerts=[alert])
        assert any((r.get('main') or {}).get('alert')==kind for _,r in rows),(kind,rows)
        assert any(name(r,'inset')=='Resolute' for _,r in rows),kind
        rows=run(d,1025,1100)
        assert any(name(r)=='Resolute' for _,r in rows),kind
    d,_=setup(); run(d,1000,1250)
    assert name(d.public(1249)) != 'Resolute'
    rows=run(d,1250,1256,work=[{'id':'repair-1','t':1250,'agent':'sol','platform':'Resolute',
                               'kind':'repair','label':'Sol repairing on Resolute','view':BOW_VIEW}])
    assert name(rows[-1][1])=='Resolute'
    assert rows[-1][1]['main']['frame'].get('surface')==BOW_VIEW['surface']
    # Busy insets and operator pins remain available; the preference is not an exclusive hold.
    d,_=setup();run(d,1000,1004);d.set_follow('sol',1200,now=1004)
    rows=run(d,1004,1010)
    assert rows[-1][1]['main']['agents']==['sol'] and name(rows[-1][1],'inset')=='Resolute'
    for kind in ('encounter','milestone'):
        d,_=setup();run(d,1000,1250)
        ship=copy.deepcopy(SHIP)
        if kind=='encounter':
            ship['danger']={'kind':'fire','last':1250,'reason':'Resolute under fire','level':2}
        for t in range(1250,1256):
            s=snap(TEAM,[ship])
            if kind=='milestone':
                s['space']['moments']=[{'id':'m1','t':1250,'facts':{'platform':'Resolute'},'text':'new distance milestone'}]
            d.step(s,t)
        assert name(d.public(1255))=='Resolute',kind


def lifecycle():
    with tempfile.TemporaryDirectory() as tmp:
        root=Path(tmp);a=root/'shiftA';b=root/'shiftB';c=root/'shiftC'
        for p in (a,b,c):p.mkdir()
        (b/'resumed-from').write_text('shiftA\n');(c/'resumed-from').write_text('shiftB\n')
        d,_=setup(path=a);run(d,1000,1004)
        d2,_=world(platform_every=0,map_every=0);d2.featured=Featured(b)
        run(d2,1010,1014)
        assert d2.featured.active and (b/NAME).exists()
        assert d2.featured.active['observed']['departed']
        arrived=plat('Resolute',at='shattered-planet',view=BOW_VIEW)
        rows=run(d2,1020,1026,ship=arrived)
        assert not d2.featured.active and name(rows[-1][1]) != 'Resolute'
        assert d2.featured.data['reason']=='arrived at shattered-planet'
        f=Featured(c);f.load();assert not f.active and f.data['status']=='ended'
        d3,_=setup(path=c);run(d3,1030,1034)
        d3.featured.finish('cleared by operator',1034,cleared=True)
        run(d3,1034,1038);assert name(d3.public(1037)) != 'Resolute'
        f=Featured(c);f.load();assert not f.active
        # Unknown/missing telemetry is not destruction and does not revive the ended ancestor.
        d3.featured.set('Resolute',attempt_end=True,now=1040)
        run(d3,1040,1044);run(d3,1044,1050,ship=None);assert d3.featured.active
        reverse=plat('Resolute',at='solar-system-edge->shattered-planet 20%',toward='solar-system-edge',view=BOW_VIEW)
        run(d3,1050,1054,ship=reverse)
        assert d3.featured.data['reason']=='attempt ended: turned back'
        d3.featured.set('Resolute',at=1060,now=1055);run(d3,1055,1065)
        assert d3.featured.data['reason']=='time expired'
        d3.featured.set('Resolute',attempt_end=True,now=1070);run(d3,1070,1074)
        s=snap(TEAM,[]);s['space']['lost']=[{'name':'Resolute','t':1075}]
        d3.step(s,1075);assert d3.featured.data['reason']=='platform lost'
        # Malformed edits fail closed without crashing or reviving an old shift's setting.
        for bad in ([],{'status':'active'},dict(status='active',name='Resolute',id='x',created=1,until={'at':'bad'})):
            (c/NAME).write_text(json.dumps(bad));d3.step(snap(TEAM,[SHIP]),1080);assert not d3.featured.active
        # Independent runs cannot inherit by directory recency alone.
        other=root/'other';other.mkdir();f=Featured(other);f.load();assert not f.active
        cmd=[sys.executable,str(HERE/'featured.py'),'--run-dir',str(other)]
        r=subprocess.run(cmd+['set','Resolute','--arrival','shattered-planet','--attempt-end'],capture_output=True,text=True)
        assert r.returncode==0,r.stderr
        data=json.loads((other/NAME).read_text());assert data['until']=={'arrival':'shattered-planet','attempt_end':True}
        assert subprocess.run(cmd+['clear'],capture_output=True).returncode==0
        assert json.loads((other/NAME).read_text())['status']=='cleared'
        for args in (['set','Resolute'],['set','Resolute','--at','2026-10-30T00:00:00']):
            assert subprocess.run(cmd+args,capture_output=True).returncode!=0


def sustained_encounter():
    d,_=setup();frames=set()
    for t in range(1000,1400):
        ship=copy.deepcopy(SHIP)
        ship['danger']={'kind':'fire','last':t,'level':2,'reason':'Resolute under fire'}
        d.step(snap(TEAM,[ship]),t)
        frames.add((d.public(t).get('main',{}).get('platform') or {}).get('framing'))
    assert 'bow defense' in frames and 'whole ship' in frames, frames


def failures():
    d,sent=setup();run(d,1000,1004)
    d.featured.finish('off',1004,cleared=True);run(d,1004,1010)
    before=copy.deepcopy(d.state[d.onair])
    d.featured.set('Resolute',arrival='shattered-planet',now=1010)
    d.sender=lambda b:{'ok':False,'error':'offline'}
    run(d,1010,1020)
    assert d.state[d.onair]==before and d.featured.started is None
    d.sender=lambda b:{'ok':True}
    rows=run(d,1020,1035)
    assert name(rows[-1][1])=='Resolute'
    # Missing view clears an old feature target, but preference resumes once the view returns.
    rows=run(d,1035,1040,ship=plat('Resolute',at='in transit',view=None))
    assert name(rows[-1][1]) != 'Resolute'
    rows=run(d,1040,1046);assert name(rows[-1][1])=='Resolute'
    # Hull changes reframe the real surface, and a failed reframe preserves the acknowledged geometry.
    expanded=copy.deepcopy(SHIP);expanded['view']['bow']['right']+=80
    old=copy.deepcopy(d.state[d.onair]);d.sender=lambda b:{'ok':False}
    run(d,1046,1048,ship=expanded)
    assert d.state[d.onair]['position']==old['position'] and d.state[d.onair]['zoom']==old['zoom']
    d.sender=lambda b:{'ok':True};run(d,1048,1058,ship=expanded)
    assert d.state[d.onair]['position']!=old['position']
    # The preference never covers a replay or Nick's explicit host view.
    d.hold_layout=True
    old=copy.deepcopy(d.state[d.onair]);run(d,1058,1065)
    assert d.state[d.onair]['position']==old['position']


def model_contract():
    from model import Model
    m=Model({'agents':{'sol':{}}})
    m.ingest({'tick':100,'agents':[dict(TEAM[0],surface='nauvis')],
              'space':{'platforms':[{'name':'Resolute','at':'solar-system-edge->shattered-planet 20%',
                                    'state':'on_the_path','view':BOW_VIEW}]}},1200)
    m._ingest_work({'agent':'sol','action':'place_ghosts','verb':'building','platform':'Resolute','at':'1250'},1250)
    d,_=setup();d.watch_platforms(m.snapshot(1250),1250)
    assert d.featured.news(d,m.snapshot(1250),'Resolute',1250)=='repair/build'
    m.platform_history={'Resolute':{'created':100,'by':'sol','at':'solar-system-edge','left':[]}}
    m.ingest({'tick':200,'agents':[], 'chronicle':{'entries':[], 'events':[
        {'type':'event','kind':'platform_left','platform':'Resolute','tick':200,'id':8,
         'at':'solar-system-edge','to':'shattered-planet'}]}},1251)
    assert m.moments and m.moments[-1]['facts']['platform']=='Resolute'
    assert d.featured.news(d,m.snapshot(1251),'Resolute',1251)=='milestone'
    s=m.snapshot(1252);s['agents'][0].update(active='repair',surface=BOW_VIEW['surface'],alive=True)
    assert d.featured.news(d,s,'Resolute',1252)=='repair'
    assert d.featured.news(d,s,'Resolute',1253) is None
    # Log the feature's name for operators even when no agent is aboard.
    with tempfile.TemporaryDirectory() as tmp:
        d,_=setup();d.log_path=str(Path(tmp)/'director.jsonl');run(d,1000,1004)
        logs=[json.loads(x) for x in Path(d.log_path).read_text().splitlines()]
        assert any('featured platform Resolute' in r['reason'] for r in logs)


if __name__=='__main__':
    with contextlib.redirect_stdout(io.StringIO()) as captured:
        share_dwell_inset();urgent_and_news();lifecycle();failures();model_contract();sustained_encounter()
    print('featured: ok (share, dwell, framing, inset, urgent, repair, arrival, loss, reversal, time, restart, carry, clear, CLI, send failure)')
