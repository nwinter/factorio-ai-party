#!/usr/bin/env python3
"""Remote journal destinations and automatic long-run coverage, real director with stub sends."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile

import attention
from featured import Featured, NAME
from model import Model
from onecam import OneCam
from test_onecam import agent
from test_platformcam import plat, snap, VIEW


def director(**cfg):
    sent = []
    d = OneCam([{'slot':'main','player':1}, {'slot':'panel','player':1,'panel':1,
                 'rect':[2388,0,492,277],'scale':.171}],
               lambda b: sent.append(b) or {'ok':True}, None,
               **dict(dict(auto_feature=False, platform_every=0, map_every=0, quiet_story=100000,
                           tours=False, bow=False, trio=False), **cfg))
    return d, sent


def work_shots():
    from work import WorkFeed
    with tempfile.TemporaryDirectory() as tmp:
        p=Path(tmp)/'astra';p.mkdir();journal=p/'journal.jsonl';journal.write_text('')
        feed=WorkFeed(tmp,['astra']);feed.poll()
        m=Model({'agents':{'astra':{}}})
        a=dict(agent('astra',40,10,20),surface='aquilo',active=None)
        ship={'name':'Resolute','at':'aquilo','view':VIEW}
        d,sent=director()
        t=1000
        requests=[('inspect',{'platform':'Resolute','position':{'x':20,'y':-70}}),
                  ('queue_status',{'lane':'platform:Resolute'}),
                  ('platform_endurance',{'platform':'Resolute'}),
                  ('configure',{'surface':'nauvis','position':{'x':300,'y':400}}),
                  ('remote_view',{'surface':'gleba','position':{'x':20,'y':50}}),
                  ('inspect',{'surface':'Resolute'}),
                  ('inspect',{'surface':'platform-1','position':{'x':1,'y':2}})]
        for action,args in requests:
            with journal.open('a') as f:
                f.write(json.dumps({'event':'request','at':'2026-10-30T09:00:00Z',
                                    'request':{'action':action,'args':args}})+'\n')
            feed.poll()
            m.ingest({'agents':[a], 'space':{'platforms':[ship]}, 'attention':feed.take_attention()},t)
            s=m.snapshot(t)
            for now in range(t,t+5):d.step(s,now)
            out=d.public(t+4)['main']
            expected=args.get('surface') if args.get('surface') in ('nauvis','gleba') else 'platform-1'
            assert out['frame']['surface']==expected,(action,out)
            assert 'Astra' in out['work'] and out['agents']==['astra'],out
            assert d.onair_surface({'astra':a})==expected
            t+=10
        assert not any(b.get('follow')=='astra' for b in sent),sent
        # A follow hold and a spoken/segment follow use the same destination resolver.
        d.set_follow('astra',t+100,now=t)
        for now in range(t,t+5):d.step(s,now)
        assert d.public(t+4)['main']['frame']['surface']=='platform-1'
        # Failed destination sends preserve the acknowledged frame and retry unchanged requests.
        old=copy.deepcopy(d.state[d.onair]);d.sender=lambda b:{'ok':False}
        s['agents'][0]['attention'].update(platform=None,surface='gleba',position={'x':90,'y':90})
        for now in range(t+5,t+9):d.step(s,now)
        assert d.state[d.onair]==old
        d.sender=lambda b:sent.append(b) or {'ok':True}
        for now in range(t+9,t+20):d.step(s,now)
        assert d.public(t+19)['main']['frame']['surface']=='gleba'
        # Unknown platform geometry never causes a character send, and resumes when its view arrives.
        s['agents'][0]['attention'].update(platform='Resolute',surface=None)
        s['space']['platforms'][0]['view']=None
        before=len(sent)
        for now in range(t+20,t+25):d.step(s,now)
        assert len(sent)==before
        s['space']['platforms'][0]['view']=VIEW
        for now in range(t+25,t+30):d.step(s,now)
        assert d.public(t+29)['main']['frame']['surface']=='platform-1'
        # Surface-only planetary reads lack a frame position. Keep the last valid view, never the body.
        s['agents'][0]['attention']=dict(attention.point('observe',{'surface':'gleba'}),age_s=0)
        before=len(sent);d.step(s,t+30)
        assert len(sent)==before and not d.state[d.onair].get('follow')
        # A newer local call and an expired remote call release the remote view.
        for att in (dict(attention.point('inspect',{'surface':'aquilo','position':a['position']}),age_s=0),
                    dict(attention.point('platform',{'platform':'Resolute'}),age_s=121)):
            s['agents'][0]['attention']=att
            d.step(s,t+31);assert d.state[d.onair].get('follow')=='astra'


def automatic():
    team=[agent('sol',0,0,5)]
    deep=plat('Resolute','solar-system-edge->shattered-planet 20%',view=VIEW)
    shallow=plat('Courier','nauvis->vulcanus 50%',view=dict(VIEW,surface='platform-2'))
    further=plat('Farther','solar-system-edge->shattered-planet 60%',view=dict(VIEW,surface='platform-3'))
    with tempfile.TemporaryDirectory() as tmp:
        a=Path(tmp)/'a';b=Path(tmp)/'b';a.mkdir();b.mkdir();(b/'resumed-from').write_text('a')
        d,_=director(auto_feature=True);d.featured=Featured(a)
        d.step(snap(team,[shallow]),1000);assert not d.featured.active
        for t in range(1001,1006):d.step(snap(team,[deep,shallow]),t)
        assert d.featured.active['source']=='auto' and d.featured.active['name']=='Resolute'
        assert d.public(1005)['main']['platform']['source']=='auto'
        d.step(snap(team,[deep,shallow,further]),1006);assert d.featured.active['name']=='Farther'
        # An operator's setting wins, including its explicit clear. 'auto' releases that override.
        d.featured.set('Courier',arrival='vulcanus',now=1007)
        d.step(snap(team,[deep,shallow,further]),1007);assert d.featured.active['name']=='Courier'
        d.featured.finish('cleared by operator',1008,cleared=True)
        d.step(snap(team,[deep]),1008);assert not d.featured.active
        d.featured.data={'source':'auto','status':'ended'};d.featured.save()
        d.step(snap(team,[deep]),1009)
        restarted=Featured(b);restarted.load();assert restarted.active['source']=='auto'
        d.featured=restarted
        reverse=plat('Resolute','solar-system-edge->shattered-planet 21%',toward='solar-system-edge',view=VIEW)
        for t in range(1010,1015):d.step(snap(team,[reverse]),t)
        assert not d.featured.active and d.featured.data['auto_blocked']['Resolute']
        restarted=Featured(b);restarted.load();d.featured=restarted
        d.step(snap(team,[reverse]),1016);assert not d.featured.active
        d.step(snap(team,[plat('Resolute','solar-system-edge',view=VIEW)]),1017)
        d.step(snap(team,[deep]),1018);assert d.featured.active
        d.step(snap(team,[plat('Resolute','shattered-planet',view=VIEW)]),1019);assert not d.featured.active
        # A non-deep named connection qualifies by the already-read distance, with a configurable threshold.
        long=plat('Long','nauvis->vulcanus 10%',view=VIEW,len=150000)
        d.step(snap(team,[long]),1020);assert d.featured.active['name']=='Long'
        d2,_=director(auto_feature=True,auto_feature_km=200000)
        d2.step(snap(team,[long]),1020);assert not d2.featured.active
        # The score's raw route facts work before the slower platform detail arrives, in either direction.
        from model import platform_where
        inbound=platform_where({'name':'Inbound','at':'in transit','route':'solar-system-edge->shattered-planet',
                                'to':'solar-system-edge','len':4000000,'km':3000000,'view':VIEW})
        assert inbound['route_ids']==['shattered-planet','solar-system-edge']
        assert inbound['leg_progress_km']==1000000
        d3,_=director(auto_feature=True)
        d3.step(snap(team,[inbound,further]),1020)
        assert d3.featured.active['name']=='Inbound'  # 75% out, even though only 25% into its return leg


def auto_airtime_and_urgent():
    from test_featured import SHIP, TEAM, name
    d,_=director(auto_feature=True)
    rows=[]
    for t in range(1000,2000):rows.append(d.step(snap(copy.deepcopy(TEAM),[SHIP]),t))
    share=sum(name(r)=='Resolute' for r in rows)/len(rows)
    assert .65<share<.85,share
    away=[r for r in rows[10:] if name(r)!='Resolute']
    assert all(name(r,'inset')=='Resolute' for r in away)
    assert {r['main']['platform']['framing'] for r in rows if name(r)=='Resolute'}=={'ship survey'}
    for kind,text in [('attack','Base under attack'),('death','Sol died'),('loss','26 lost near (400, 400): 26 gun turret')]:
        d,_=director(auto_feature=True)
        for t in range(1000,1020):d.step(snap(TEAM,[SHIP]),t)
        alert={'id':kind,'kind':kind,'t':1020,'text':text,'position':{'x':400,'y':400,'surface':'nauvis'}}
        if kind=='death':alert['agent']='sol'
        out=d.step(snap(TEAM,[SHIP],alerts=[alert]),1020)
        assert out['main'].get('alert')==kind,(kind,out)


def recorded_replay():
    from replay_remote_work import metrics, FIXTURE
    result=metrics(json.loads(FIXTURE.read_text()))
    for window in ('02:00-05:00','02:00-03:16:48'):
        before=result['recorded'][window];after=result['remote_and_auto'][window]
        assert after['seconds']==before['seconds']
        assert after['resolute_percent']>before['resolute_percent']+30
        assert after['astra_body_seconds']<before['astra_body_seconds']/10
    assert result['recorded']['02:00-05:00']['resolute_seconds']==5974
    print(json.dumps(result,indent=2))


def rapid_captions():
    from test_onecam import world
    d,_=world(auto_feature=False,platform_every=0,map_every=0)
    a=dict(agent('astra',40,10,20),surface='aquilo')
    for t in range(1000,1005):
        a['attention']=dict(attention.point('platform',{'platform':'Resolute'}),age_s=0,text=f'checking item {t}')
        d.step(snap([a],[plat('Resolute',view=VIEW)]),t)
    assert d.public(1004)['main']['frame']['surface']=='platform-1'
    assert '1004' in d.public(1004)['main']['work']  # captions cannot continually restart standby readiness


if __name__=='__main__':
    with contextlib.redirect_stdout(io.StringIO()):work_shots();automatic();auto_airtime_and_urgent();rapid_captions()
    recorded_replay()
    print('remote work and automatic feature: all passed')
