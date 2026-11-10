#!/usr/bin/env python3
"""Offline Python/JSON cost and camera scheduling measurements. Never contacts a game."""
import json
import statistics
import time
from public_race import project, Race, Director
from public_replay import synthetic, PAIR_ROSTER as ROSTER


def measure(dense=False):
    width=160 if dense else 40
    raw={'now':1000,'tick':6000,'research':{'done_count':12,'current':'automation','progress':.5},
         'space':{'rockets':0},'science':{'spm':18,'series':list(range(30))},
         'basemap':{'tick':6000,'x0':0,'y0':0,'w':width,'h':width,'cell':1,
                    'rows':['.'*width if y%3 else 'A'*width for y in range(width)]}}
    raw['agents']=[{'name':a['name'],'activity':'acting','active':'build:lab'} for roster in ROSTER.values() for a in roster]
    durations=[]
    for _ in range(300):
        start=time.perf_counter()
        rows=[project(t,raw,roster,1000,{'tick':6000,'entities':{'lab':3}}) for t,roster in ROSTER.items()]
        out=Race().update(rows,1000)
        wire=json.dumps(out,separators=(',',':')).encode()
        durations.append((time.perf_counter()-start)*1000)
    return {'three_team_projection_and_json_ms':{'median':round(statistics.median(durations),3),
            'p95':round(sorted(durations)[285],3)},'public_bytes':len(wire),'browser_KiB_per_minute':round(len(wire)*30/1024,1)}


def camera():
    teams=synthetic()[4]['teams'];director=Director();cuts=[]
    for now in range(0,601,5):
        events=[{'team':'green','kind':'rocket','at':now}]  # deliberately unbalanced news
        choice=director.choose(teams,events,now)
        if choice:
            cuts.append([now,*choice]);director.success(choice[0],now)
    gaps={}
    for t in ROSTER:
        seen=[0]+[c[0] for c in cuts if c[1]==t]+[600]
        gaps[t]=max(b-a for a,b in zip(seen,seen[1:]))
    return {'seconds':600,'cuts':len(cuts),'cuts_per_minute':round(len(cuts)/10,1),'max_gap_seconds':gaps,'schedule':cuts}


if __name__=='__main__':
    print(json.dumps({'normal':measure(),'dense_160':measure(True),'director':camera()},indent=2))
