#!/usr/bin/env python3
"""Receipt-driven ship surveys, with an actuated native/fallback camera and explicit compositor visibility."""
import contextlib
import copy
import io
import math

import camerapath
from director import Director
from onecam import OneCam
from test_platformcam import plat, snap

VIEW = dict(surface='platform-16', hub=dict(x=0, y=0), bounds_source='foundation',
            hull=dict(left=-51, top=-58, right=51, bottom=384),
            machines=[dict(x=0, y=120, w=1)], guns=[])


class Camera:
    def __init__(self, native=True, speed=1, panel=False):
        self.now = 1000.
        self.native, self.speed, self.panel = native, speed, panel
        self.pose = dict(x=0, y=0, zoom=.3)
        self.surface = 'nauvis'
        self.body = {}
        self.move = None
        self.fail = False
        self.calls = []

    def advance(self, now):
        dt = now - self.now
        if self.move:
            x,y,z = camerapath.at(self.move, (now-self.started)*self.speed)
            self.pose = dict(x=x,y=y,zoom=z)
        elif self.body.get('position'):
            for _ in range(round(dt * 60 * self.speed)):
                p=self.body['position'];distance=math.hypot(p['x']-self.pose['x'],p['y']-self.pose['y'])
                k=min(.08,self.body.get('speed', 1e9)/60/max(.001,distance))
                for a in ('x','y'):self.pose[a]+=(p[a]-self.pose[a])*k
                self.pose['zoom']+=(self.body['zoom']-self.pose['zoom'])*.08
        self.now=now

    def __call__(self, body):
        self.calls.append(copy.deepcopy(body))
        if body.get('observe'):
            return dict(ok=True, connected=True, visible=True, speed=self.speed,
                        position={k:self.pose[k] for k in ('x','y')},zoom=self.pose['zoom'],surface=self.surface)
        if self.fail:return dict(ok=False)
        self.body=copy.deepcopy(body);self.move=None
        if body.get('position'):
            self.surface=body['surface']
            if not body.get('smooth'):
                self.pose=dict(body['position'],zoom=body['zoom'])
        if body.get('move') and self.native and not self.panel:
            self.move=body['move'];self.started=self.now
        return dict(ok=True, camera={'move':dict(start_tick=0)} if self.move else {})


def setup(native=True, speed=1, panel=False, visit=False):
    cam=Camera(native,speed,panel)
    slot=dict(slot='main',player=1)
    if panel:slot.update(panel=1,rect=[0,0,400,230],scale=.171)
    d=OneCam([slot],cam,None,auto_feature=False,trio=False,quiet_views=False,tours=False,
             platform_every=0,map_every=0,platform_frac=1894/2880)
    d.watch_platforms(snap([], [plat('Asterion',view=VIEW)]),1000)
    shot=d.visit_target('Asterion',20,1000) if visit else d.platform_target('Asterion','operator',1240,overview=True)
    d.frame_on(slot,shot,'start',{},1000)
    return d,cam,shot


def run(d,cam,start,end,visible=True):
    phases=[]
    for i in range(round(start*2),round(end*2)):
        now=i/2
        cam.advance(now)
        d.on_air=copy.deepcopy(d.state) if visible else dict(main=None)
        d.pan_step(now);d.beat_step(now)
        if d.surveys:phases.append(next(iter(d.surveys.values())).phase)
    return phases


def full():
    for native,panel,speed in [(True,False,1),(True,False,.25),(False,False,1),(False,True,1),(False,True,.25)]:
        d,c,_=setup(native,speed,panel)
        phases=run(d,c,1000,1240)
        q=next(iter(d.surveys.values()))
        assert q.ends=={'bow','stern'},(native,panel,speed,q.public())
        assert all(p in phases for p in ('survey','zoom_in','detail_dwell','pullback','return')),(native,panel,speed,set(phases))
        assert q.coverage==[(-58,384)],q.public()
        assert q.spec['bow']['y']-16.875/.3 < -58-30
        assert q.spec['stern']['y']+16.875/.3 > 384+30
        if panel:assert all('move' not in b for b in c.calls)
        assert all(b.get('speed',0)<=60 for b in c.calls)
    d,c,shot=setup(visit=True)
    run(d,c,1000,shot['until'])
    assert 'stern' in next(iter(d.surveys.values())).ends,shot


def interrupted():
    for at in (1004,1025,1045,1053,1061,1070,1145):
        d,c,shot=setup()
        run(d,c,1000,at)
        q=next(iter(d.surveys.values()));saved=copy.deepcopy(q.public())
        other=dict(position=dict(x=50,y=60),zoom=.8,surface='nauvis',agents=[],subject='@attack',until=at+10)
        d.frame_on(d.slots[0],other,'urgent',{},at)
        run(d,c,at,at+10)
        assert q.phase==saved['phase'] and q.direction==saved['direction'] and q.pose==saved['position']
        d.frame_on(d.slots[0],shot,'resume',{},at+10)
        assert next(iter(d.surveys.values())) is q
        run(d,c,at+10,1240)
        assert q.ends=={'bow','stern'},(at,q.public())
        # The original hold's expiry, not a refreshed target deadline, bounds retention.
        d.frame_on(d.slots[0],dict(shot,until=1500),'later',{},1300)
        new=next(iter(d.surveys.values()))
        assert new is not q and new.phase=='bow_dwell' and new.direction==1 and not new.coverage


def receipts_and_failure():
    d,c,shot=setup()
    run(d,c,1000,1010,visible=False)
    q=next(iter(d.surveys.values()));assert not q.coverage and not q.ends and q.dwell==0
    c.fail=True
    run(d,c,1010,1040)
    assert q.phase=='survey' and q.pose==q.spec['bow'] and 'stern' not in q.ends
    assert q.coverage[0][1]<VIEW['hull']['bottom']
    c.fail=False
    run(d,c,1040,1240)
    assert q.ends=={'bow','stern'},q.public()
    # A success acknowledgement without observed view is never arrival/coverage.
    d,c,_=setup();d.sender=lambda b:dict(ok=True)
    run(d,c,1000,1230)
    assert not next(iter(d.surveys.values())).coverage


def selection_resume():
    d,c,shot=setup(visit=True)
    run(d,c,1000,1025)
    q=d.surveys[d.state['main']['survey_key']]
    d.frame_on(d.slots[0],dict(subject='@attack',agents=[],position=dict(x=20,y=30),surface='nauvis',
                             zoom=.8,until=1030),'urgent',{},1025)
    saved=q.public()
    d.resume_survey({}, {}, 1026)
    assert d.state['main']['subject']=='@attack'
    d.builds_waiting=[dict(agent='astra')]
    d.resume_survey({}, {}, 1031)
    assert d.state['main']['subject']=='@attack'
    d.builds_waiting=[]
    d.resume_survey({}, {}, 1032)
    assert d.state['main'].get('survey') and q.phase==saved['phase'] and q.direction==saved['direction']
    run(d,c,1032,shot['until'])
    assert q.coverage == [(-58, 384)] and (q.phase == 'stern_dwell' or 'stern' in q.ends),q.public()


def hidden_and_refit():
    from featured import Featured
    d,c,shot=setup()
    run(d,c,1000,1025)
    q=d.surveys[d.state['main']['survey_key']];saved=copy.deepcopy(q.public())
    # A failed off-air freeze lets the native game move run, but never earns invisible coverage.
    d.hold_layout=True;c.fail=True
    run(d,c,1025,1050)
    assert q.public()==saved
    d.hold_layout=False;c.fail=False
    run(d,c,1050,1050.5)
    assert c.pose==saved['position'] and q.phase==saved['phase']
    # Section metadata changes cannot restart a live native path.
    run(d,c,1050.5,1055)
    old=d.state['main'];fresh=copy.deepcopy(shot)
    fresh['survey']['details'][0]['position']['y']+=10
    count=len(c.calls);Featured.refresh(d,d.slots[0],old,fresh,{},1055)
    assert len(c.calls)==count and q.spec['details']==fresh['survey']['details']
    # A failed hull refit keeps both the acknowledged frame and its controller.
    fresh=copy.deepcopy(shot);fresh['survey']['bounds']['right']+=10;fresh['survey']['bow']['x']+=5
    fresh['survey']['stern']['x']+=5
    old=copy.deepcopy(d.state['main']);c.fail=True
    assert not Director.apply(d,d.slots[0],fresh,'refit',{},1056)
    assert d.state['main']==old and d.surveys[old['survey_key']] is q
    c.fail=False
    assert Director.apply(d,d.slots[0],fresh,'refit',{},1057)
    assert d.surveys[d.state['main']['survey_key']] is not q
    # Operator refresh also notices a changed hull at the same zoom and vertical pan endpoints.
    d,c,_=setup();run(d,c,1000,1020)
    old=copy.deepcopy(d.state['main']);q=d.surveys[old['survey_key']]
    view=copy.deepcopy(VIEW);view['hull']['right']+=10
    d.watch_platforms(snap([], [plat('Asterion',view=view)]),1020)
    fresh=d.platform_target('Asterion','operator',1240,overview=True)
    from onecam import CameraPending
    c.fail=True
    try:d.platform_direct(fresh,{},1020)
    except CameraPending:pass
    assert d.state['main']==old and d.surveys[old['survey_key']] is q
    c.fail=False;d.platform_direct(fresh,{},1021)
    assert d.state['main']['position']['x']==5


def independent_dwell():
    arrival=[]
    for dwell in (5,25):
        d,c,_=setup();q=d.surveys[d.state['main']['survey_key']];q.DETAIL_S=dwell
        for k in range(480):
            run(d,c,1000+k*.5,1000+(k+1)*.5)
            if q.phase=='stern_dwell':
                arrival.append(k*.5);break
        assert q.coverage==[(-58,384)]
    assert abs(arrival[1]-arrival[0]-20)<=1,arrival


def receipt_logging():
    import json,tempfile,pathlib
    from airtime import program
    with tempfile.TemporaryDirectory() as tmp:
        d,c,_=setup();d.log_path=str(pathlib.Path(tmp)/'director.jsonl')
        shot=d.platform_target('Asterion','operator',1240,overview=True)
        d.frame_on(d.slots[0],shot,'platform operator: Asterion',{},1000)
        run(d,c,1000,1010)
        rows=[json.loads(line) for line in pathlib.Path(d.log_path).read_text().splitlines()]
        assert any(r.get('event')=='survey_receipt' for r in rows)
        timeline,cuts=program(rows)
        assert all(r['reason']=='platform operator: Asterion' for _,r in timeline) and not cuts


if __name__=='__main__':
    with contextlib.redirect_stdout(io.StringIO()):
        full();interrupted();receipts_and_failure();selection_resume();hidden_and_refit();independent_dwell();receipt_logging()
    print('ship survey: native, panel, slow game, tall visit, interruptions, failures and visible receipts passed')
