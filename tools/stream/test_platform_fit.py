#!/usr/bin/env python3
"""Foundation fits through actual 2880x1620 crops, refit freshness and cold-start publication. Offline."""
import json, math, random
from pathlib import Path
from unittest.mock import patch
import cuts, harness, model
from live import LiveSource

HERE = Path(__file__).resolve().parent
FIXTURE = json.loads((HERE / 'fixtures/d30-platform-framing.json').read_text())
LAYOUTS = [json.loads((HERE / 'static' / n).read_text()) for n in ('layout.json', 'layout-portrait.json')]
FRAC = cuts.platform_view_frac(LAYOUTS, FIXTURE['capture'])


def edges(shot, bounds, layout):
    cw, ch = FIXTURE['capture']
    _, _, w, h = layout['cams']['main']
    crop = cuts.crop_for(cw, ch, w, h)
    vw, vh = cw - crop['cropLeft'] - crop['cropRight'], ch - crop['cropTop'] - crop['cropBottom']
    scale = min(w / vw, h / vh)
    ox, oy = (w - vw * scale) / 2, (h - vh * scale) / 2
    pixels = 32 * shot['zoom'] * ch / 1080
    x, y = shot['position']['x'], shot['position']['y']
    return (ox + (cw / 2 + (bounds['left'] - x) * pixels - crop['cropLeft']) * scale,
            oy + (ch / 2 + (bounds['top'] - y) * pixels - crop['cropTop']) * scale,
            ox + (cw / 2 + (bounds['right'] - x) * pixels - crop['cropLeft']) * scale,
            oy + (ch / 2 + (bounds['bottom'] - y) * pixels - crop['cropTop']) * scale)


def real_ships():
    assert FRAC == 1894 / 2880
    for row in FIXTURE['ships']:
        b = row['hull']
        view = dict(row['before_view'], hull=b, bounds_source='foundation')
        sh = model.platform_shot(view, frac=FRAC, overview=True)
        assert sh['position'] == dict(x=(b['left']+b['right'])/2, y=(b['top']+b['bottom'])/2)
        assert sh['zoom'] >= .3
        for lay in LAYOUTS:
            l,t,r,bt = edges(sh,b,lay); _,_,w,h=lay['cams']['main']
            assert l > 0 and r < w and abs(l-(w-r)) < .01, (row['name'],l,r,w)
            if 'pan' not in sh:
                assert t > 0 and bt < h and abs(t-(h-bt)) < .01
            else:
                assert row['name']=='Asterion' and sh['zoom']==.3 and sh['platform_frame']['limited']
                bow=edges(dict(sh,position=dict(sh['position'],y=sh['pan']['y0'])),b,lay)
                stern=edges(dict(sh,position=dict(sh['position'],y=sh['pan']['y1'])),b,lay)
                assert bow[1] > 38 and h-stern[3] > 38  # five-tile margins at each sweep endpoint
        if row['name']=='Asterion':
            assert row['entity_count'] > 4000 and b['right']==51 and row['before_view']['bounds']['right']==6
            baseline=row['ack']['row']['cmd']
            assert edges(baseline,b,LAYOUTS[0])[2] > LAYOUTS[0]['cams']['main'][2]
    print('three recorded hulls: centred, clear edges, zoom floor and full-length sweep')


def fit_properties():
    rng=random.Random(387)
    for _ in range(500):
        x,y=rng.randrange(-200,200),rng.randrange(-200,200)
        w,h=rng.randrange(1,110),rng.randrange(1,100)
        b=dict(left=x,top=y,right=x+w,bottom=y+h)
        sh=model.platform_shot(dict(surface='platform-test',hull=b),frac=FRAC,overview=True)
        assert not sh.get('pan')
        for lay in LAYOUTS:
            l,t,r,bt=edges(sh,b,lay);_,_,pw,ph=lay['cams']['main']
            px=32*sh['zoom']*FIXTURE['capture'][1]/1080*pw/(FIXTURE['capture'][0]-2*cuts.crop_for(*FIXTURE['capture'],pw,ph)['cropLeft'])
            assert min(l,t,pw-r,ph-bt) >= 4.99*px, (b,sh,(l,t,r,bt))
    # A wide ship is width-constrained by the pane; a 35x160 refit still needs a vertical sweep at .3.
    wide=model.platform_shot(dict(surface='s',hull=dict(left=-50,top=-5,right=50,bottom=5)),frac=FRAC,overview=True)
    assert wide['zoom']==.35
    tall=model.platform_shot(dict(surface='s',hull=dict(left=0,top=0,right=35,bottom=160)),frac=FRAC,overview=True)
    assert tall['zoom']==.3 and tall['pan']['y1']>tall['pan']['y0']
    # Explicit context ignores the off-centre turret reach and flight detail; intentional flight detail remains.
    v=dict(surface='s',hull=dict(left=-15,top=-20,right=15,bottom=20),guns=[dict(x=10,y=-18,range=40)])
    assert model.platform_shot(v,frac=FRAC,travelling=True,overview=True)['position']==dict(x=0,y=0)
    assert model.platform_shot(v,frac=FRAC,travelling=True)['position']!=dict(x=0,y=0)
    print('500 deterministic asymmetric boxes: >= five tiles of margin in both native crops')


def freshness():
    h=harness.Harness.__new__(harness.Harness); calls=[]
    names=[f'Ship-{n:02d}' for n in range(21)]
    def lua(src):
        picked=[n for n in names if f'[ [[{n}]] ] = true' in src]
        assert len(picked)==1
        calls.extend(picked)
        return {'hulls':[dict(name=picked[0],surface='s',hull=dict(left=0,top=0,right=10,bottom=10))]}
    h.lua=lua
    for n in range(84):h.platform_hulls(names,now=1000+3*n)
    assert all(calls.count(n)==4 for n in names),calls
    assert 'limit = 4000' not in harness.PLATFORM_LUA and '--' not in harness.PLATFORM_HULL_LUA
    # No obsolete foundation survives a shrinking refit or removal; no hub-only shot before first survey.
    src=LiveSource.__new__(LiveSource);src.next_platforms=math.inf;src.platform_detail={}
    src.platform_views={'Test':dict(surface='s',hub=dict(x=0,y=0),bounds_source='pending')}
    h.platform_hulls=lambda names:{};src.h=h
    with patch('live.time.time',return_value=1000):
        space={'platforms':[dict(name='Test',at='nauvis')]};src.observe_platforms(space,{})
        assert 'view' not in space['platforms'][0]
        for box in (dict(left=-50,top=-50,right=50,bottom=50),dict(left=0,top=0,right=10,bottom=10),None):
            h.platform_hulls=lambda names:{'Test':dict(surface='s',hull=box)}
            space={'platforms':[dict(name='Test',at='nauvis')]};src.observe_platforms(space,{})
            v=space['platforms'][0]['view']
            assert v['hull']==box
            assert v['bounds']==(box or dict(left=-6,top=-6,right=6,bottom=6))
    print('one hull read per poll, all ships refreshed fairly, cold start and shrinking/empty refits')


def overview_paths():
    from onecam import OneCam
    from test_onecam import world
    from test_platformcam import plat, snap, team
    d, _ = world(platform_frac=FRAC, auto_feature=False, map_every=0)
    ships=[plat(r['name'],at='nauvis->vulcanus 20%',view=dict(r['before_view'],hull=r['hull'])) for r in FIXTURE['ships']]
    snapshot=snap(team(),ships)
    d.watch_platforms(snapshot,1000)
    for row in FIXTURE['ships']:
        name=row['name'];b=row['hull'];cx=(b['left']+b['right'])/2
        visit=d.visit_target(name,40,1000)
        assert visit['position']['x']==cx and not (visit.get('pan') or {}).get('detail')
        d.platform_follow=dict(name=name,until=1200,by='operator');d.plat=name
        hold=d.operator_platform_target({},1000)
        assert hold['position']['x']==cx and hold['zoom']==visit['zoom']
        d.featured.data=dict(id='test',status='active')
        context=d.featured.shot(d,name,1000,context=True)
        assert context['position']['x']==cx and context['zoom']==visit['zoom']
    sent=[]
    d=OneCam([dict(slot='main',player=1)],lambda body:sent.append(body) or {'ok':True},None,
             auto_feature=False,map_every=0,platform_every=0,platform_frac=FRAC)
    r=FIXTURE['ships'][0]
    segment=dict(model.platform_shot(dict(r['before_view'],hull=r['hull']),frac=FRAC,overview=True),
                 id='space-fit',label='Space progress',until=1100)
    for now in range(1000,1045):
        d.step(snapshot,now,segment)
    assert d.state['main']['pan']==segment['pan']
    assert d.state['main']['platform_frame']['source']=='foundation'
    glides=[b for b in sent if b.get('speed')]
    assert glides and all(b['position']['x']==0 and 0<b['speed']<=60 for b in glides)
    assert any(b['position']['y']==segment['pan']['y1'] for b in sent)
    print('in-flight visit/hold/context are hull overviews; space segment retains the full sweep')


if __name__=='__main__':
    real_ships();fit_properties();freshness();overview_paths()
