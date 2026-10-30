#!/usr/bin/env python3
"""Offline policy replay of shift104's recorded main-camera decisions, route reads and Astra's journal attention.

This holds other editorial choices at their recorded destinations, then applies the real remote-work resolver
and featured policy. It is a counterfactual airtime comparison, not a reconstruction of unlogged model inputs
or capture pixels. No live services are contacted. The fixture records its source files and extraction rules.
"""
import argparse
import contextlib
import copy
import io
import json
from pathlib import Path

import attention
from model import platform_where
from onecam import OneCam, CameraPending

FIXTURE = Path(__file__).with_name('fixtures') / 'shift104-remote-work.json'


def replay(data, automatic=False, remote=False):
    d=OneCam([{'slot':'main','player':1}], lambda b:{'ok':True}, None)
    # Geometry is a stub: the recording supplies the actual surface. This replay measures time, not framing.
    a=dict(name='astra',display_name='Astra',alive=True,position={'x':40.40625,'y':9.91796875},
           surface='aquilo',active=None,interest=20,activity='acting')
    d.agents_now={'astra':a}
    offsets=dict.fromkeys(('shots','attention','routes'),0)
    current={};last_attention=None;rows=[];samples=[]
    start,end=data['start'],data['end']
    for t in range(start,end):
        for key in offsets:
            records=data[key]
            while offsets[key]<len(records) and records[offsets[key]]['t']<=t:
                row=records[offsets[key]];offsets[key]+=1
                if key=='shots':current=copy.deepcopy(row['target'])
                elif key=='attention':last_attention=row
                else:rows=copy.deepcopy(row['platforms'])
        if not current:continue
        if last_attention:
            att=copy.deepcopy(last_attention['point'])
            att.update(age_s=t-last_attention['t'])
            if att.get('platform')=='Resolute':att['surface']='platform-22'
            att['text']=attention.text(att)
            a['attention']=att
        plats=[platform_where(dict(p,view=data['views'].get(p['name']))) for p in rows]
        snapshot={'agents':[a],'space':{'platforms':plats}}
        d.watch_platforms(snapshot,t)
        held=False
        if automatic:
            d.featured.prepare(d,snapshot,t)
            held=d.featured.main(d,snapshot,{},t,bool(current.get('urgent')),None,None)
        if not held:
            target=copy.deepcopy(current)
            target.pop('urgent',None)
            # With remote=False, preserve the acknowledged historical command exactly.
            if remote:
                from remotework import shot
                work, ready=shot(d,a,t) if target.get('follow')=='astra' else (False,None)
                if work and ready:target=ready
            if not remote:
                from director import Director
                Director.apply(d,d.slots[0],dict(target,since=t,framed=t),'recorded',{},t,quiet=True)
            else:
                try:
                    d.apply(d.slots[0],dict(target,since=t,framed=t),'replay',{},t,quiet=True)
                except CameraPending:
                    pass  # unresolved target: retain the last acknowledged view as in OneCam.step
        frame=d.state['main'] or {}
        samples.append((t,frame.get('surface')=='platform-22',frame.get('follow')=='astra'))
    return samples


def metrics(data):
    out={}
    for label,auto,remote in [('recorded',False,False),('remote_work',False,True),('remote_and_auto',True,True)]:
        with contextlib.redirect_stdout(io.StringIO()):rows=replay(data,auto,remote)
        windows={}
        for name,start,end in [('02:00-05:00',data['start'],data['end']),
                               ('02:00-03:16:48',data['start'],data['restart'])]:
            sample=[r for r in rows if start<=r[0]<end]
            windows[name]={'seconds':len(sample),'resolute_seconds':sum(r[1] for r in sample),
                           'resolute_percent':round(100*sum(r[1] for r in sample)/len(sample),2),
                           'astra_body_seconds':sum(r[2] for r in sample)}
        out[label]=windows
    return out


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--fixture',type=Path,default=FIXTURE)
    args=p.parse_args()
    print(json.dumps(metrics(json.loads(args.fixture.read_text())),indent=2))


if __name__=='__main__':main()
