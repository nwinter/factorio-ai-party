#!/usr/bin/env python3
"""Offline overlay replay: no Harness, clients, server launch, OBS or broadcast.

  python tools/mt/public_replay.py --write /absolute/fixture.json [--mtt1 /path/to/op]
  python tools/mt/public_replay.py --serve /absolute/fixture.json --port 8796

Synthetic fixture exercises changing research, lead changes, chat, maps and news.
Mtt1 replay uses only recorded score/chat facts; unavailable SPM/maps/activity stay unknown.
"""
import argparse
import copy
import http.server
import json
from pathlib import Path
import time
import urllib.parse

from public_race import project, project_viewers, Race, Director, icons, clock

HERE = Path(__file__).resolve().parent
ROSTER = {'green': [{'name': 'gemini', 'model': 'Gemini 3.8 Flash'}],
          'yellow': [{'name': 'grok', 'model': 'Grok 4.7'}],
          'blue': [{'name': 'muse', 'model': 'Muse Spark 1.3'}]}
PAIR_ROSTER = {team: [dict(roster[0], name=roster[0]['name'] + suffix) for suffix in ('', '2')]
               for team, roster in ROSTER.items()}


def synthetic():
    race, director, frames = Race(), Director(), []
    for step in range(25):
        now, tick = 1000 + step * 5, 180000 + step * 300
        teams = []
        for i, (team, roster) in enumerate(PAIR_ROSTER.items()):
            lead = team == 'yellow' and step >= 12
            count = [16, 13, 9][i] + (5 if lead else 0) + (1 if step >= 6 else 0)
            tech = ['chemical-science-pack', 'advanced-circuit', 'logistic-science-pack'][i]
            entities = {'burner-mining-drill': 4, 'electric-mining-drill': 5-i, 'stone-furnace': 8-i,
                        'assembling-machine-1': 4-i, 'steam-engine': 2, 'lab': 3-i+(step>=6)}
            grid = [['.' for _ in range(40)] for _ in range(28)]
            for row in range(5,24):
                grid[row][10] = 'B'
                for col in range(13,29):
                    if row in (9,14,20):
                        grid[row][col] = 'B'
                    elif col%4==0:
                        grid[row][col] = ['M','S','A','R','E'][(row//4+i)%5]
            stream = {'now': now, 'tick': tick, 'research': {'current': tech, 'progress': (.22+.025*step+i*.18)%1, 'done_count': count},
                      'science': {'spm': [24.6,31.2,8.4][i]+step*.4, 'series': [max(0,(j-4)*(i+1)+((j*7)%11)-5) for j in range(30)], 'stage': 2,
                                  'made': {'packs': [{'item':'automation-science-pack','total':200}]}},
                      'space': {'rockets': 0},
                      'agents': [{'name': roster[0]['name'], 'activity': 'thinking' if (step+i)%4==0 else 'acting',
                                  'active': ['build:chemical-plant','craft:advanced-circuit','insert:lab'][i],
                                  'position': {'x': 18+step%7, 'y': 14}, 'surface': 'nauvis'}],
                      'basemap': {'tick':tick-600,'x0':0,'y0':0,'w':40,'h':28,'cell':1,'rows':[''.join(r) for r in grid]},
                      'chat': [{'from':roster[0]['name'],'tick':tick-2400,'text':[
                          'Oil is connected. Building chemical plants for blue science next.',
                          'More labs are running. Scaling circuits to catch the leader.',
                          'Green science is next. Feeding the labs while I add inserters.'][i]}],
                      'chronicle': {'events': [{'kind':'research','name':['steel-processing','logistics','automation'][i],'tick':177600-i*1200}]}}
            stream['agents'].append({'name': roster[1]['name'], 'activity': 'acting' if step%3 else 'thinking',
                                     'active': ['insert:lab', 'build:assembling-machine-1', 'craft:inserter'][i],
                                     'position': {'x':24-step%4,'y':18}, 'surface':'nauvis'})
            replies = ['I will feed the labs. You can keep building the chemical plants.',
                       'I have the copper line. Keep the circuit assemblers supplied.',
                       'I will add inserters and belts. You handle the science packs.']
            stream['chat'].append({'agent':roster[1]['name'],'from':roster[1]['name'],'lane':'tell','tell':True,
                                   'to':[roster[0]['name']],'body':replies[i], 'text':'ignored presentation text',
                                   'tick':tick-900})
            teams.append(project(team, stream, roster, now, {'entities':entities,'tick':tick}))
        data = race.update(teams, now)
        if step in (5,11,17):
            race.add(['blue','yellow','green'][(step-5)//6], 'build', 'First chemical plant built', tick, now, 'chemical-plant', observed=True)
            data = race.update(teams, now)
        choice = director.choose(teams, data['events'], now)
        if choice:
            director.success(choice[0],now)
        viewers = [{'id':'site:104','source':'site','text':'Green, can one of you handle oil while the other feeds the labs?',
                    't':now-8},
                   {'source':'youtube','text':'Yellow is closing the gap. Can they keep the labs fed?',
                    't':now-3}]
        data.update(now=now, camera={'team':director.current,'reason':choice[1] if choice else 'Following the action','surface':'nauvis'},
                    viewers=project_viewers(viewers,now,PAIR_ROSTER), viewer_status='on',
                    viewer_delivery={'104':{'s':'held' if step<18 else 'relayed',
                                            'teams':['green'] if step<18 else list(PAIR_ROSTER),'t':now}},
                    fixture='SYNTHETIC PAIR REPLAY')
        frames.append(copy.deepcopy(data))
    return frames


def jsonl(path):
    out=[]
    for line in path.read_text().splitlines() if path.exists() else []:
        try: out.append(json.loads(line))
        except ValueError: pass
    return out


def recorded(op):
    scores={t:jsonl(op/t/'scores.jsonl') for t in ROSTER}
    chats={t:jsonl(op/t/'chat.jsonl') for t in ROSTER}
    # views.json's final 60s read can be newer than the 120s score log.
    view=json.loads((op/'views.json').read_text()) if (op/'views.json').exists() else {}
    for team in view.get('teams',[]):
        name,s=team.get('team'),team.get('score') or {}
        if name in scores and s.get('tick') is not None and not (team.get('errors') or {}).get('score'):
            scores[name].append({'score':{'tick':s['tick'],'research_done':s.get('research'),
                                         'current_research':s.get('researching'),'entities':s.get('entities'),
                                         'rockets':s.get('rockets')}})
            scores[name].sort(key=lambda r:r['score']['tick'])
    ticks=sorted({r['score']['tick'] for ss in scores.values() for r in ss})
    race, frames=Race(),[]
    for i,tick in enumerate(ticks):
        now=1000+i*5
        teams=[]
        for team,roster in ROSTER.items():
            prior=[r['score'] for r in scores[team] if r['score']['tick']<=tick]
            score=prior[-1] if prior else {}
            score=dict(score,research=score.get('research_done'))
            st={'now':now,'tick':score.get('tick'),'research':{'current':score.get('current_research'),
                'done_count':len(score.get('research_done') or []) if prior else None},'space':{'rockets':score.get('rockets')},
                'chat':[r for r in chats[team] if r.get('tick',1e20)<=tick]}
            teams.append(project(team,st,roster,now,score if prior else None))
        data=race.update(teams,now)
        data.update(now=now,camera={'team':list(ROSTER)[i%3],'surface':'nauvis','reason':'Recorded score replay'},viewers=[],fixture='MTT1 SCORE REPLAY')
        frames.append(copy.deepcopy(data))
    return frames


def serve(path,port):
    frames=json.loads(path.read_text())
    start=time.monotonic()
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            parsed=urllib.parse.urlsplit(self.path)
            if parsed.path=='/state.json':
                query=urllib.parse.parse_qs(parsed.query)
                try: index=int(query.get('frame',[int((time.monotonic()-start)/2)%len(frames)])[0])
                except ValueError: self.send_error(400);return
                state=copy.deepcopy(frames[max(0,min(index,len(frames)-1))])
                shift=time.time()-state['now'];state['now']+=shift
                for m in state.get('viewers',[]):m['t']+=shift
                body,mime=json.dumps(state).encode(),'application/json'
            elif parsed.path in ('/','/overlay.html'):
                body,mime=(HERE/'public-overlay.html').read_bytes(),'text/html'
            elif parsed.path=='/mapview.js':
                body,mime=(HERE.parents[1]/'site/static/mapview.js').read_bytes(),'text/javascript'
            elif parsed.path.startswith('/static/game/'):
                parts=parsed.path.split('/')
                if len(parts)!=5 or parts[3] not in icons.INDEX or not parts[4].endswith('.webp') or parts[4][:-5] not in icons.INDEX[parts[3]]:
                    self.send_error(404);return
                body,mime=(icons.GAME/parts[3]/parts[4]).read_bytes(),'image/webp'
            else:self.send_error(404);return
            self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def log_message(self,*_):pass
    server=http.server.ThreadingHTTPServer(('127.0.0.1',port),Handler)
    print(f'Replay only: http://127.0.0.1:{port}/ ({len(frames)} frames)',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close()


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--write',type=Path);ap.add_argument('--mtt1',type=Path)
    ap.add_argument('--serve',type=Path);ap.add_argument('--port',type=int,default=8796)
    args=ap.parse_args()
    if args.write:
        frames=recorded(args.mtt1) if args.mtt1 else synthetic()
        args.write.write_text(json.dumps(frames,separators=(',',':')))
        print(f'{len(frames)} frames, {args.write.stat().st_size} bytes: {args.write}')
    elif args.serve:serve(args.serve,args.port)
    else:ap.print_help()
