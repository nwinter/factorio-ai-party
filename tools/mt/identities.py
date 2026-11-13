"""Seed distinct visual identifiers, preserving all agent-chosen profile fields."""
import argparse
import json
from pathlib import Path
import re
import sys
import uuid

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/stream'))
from harness import Harness,lua_string

PALETTE=['#3cb44b','#42d4f4','#ffe119','#f58231','#4363d8','#f032e6',
         '#e6194b','#911eb4','#bfef45','#469990','#9a6324','#fffac8']
GLYPHS=['⚙','⚡','◆','▲','✦','☾','●','✚','■','⬟','✿','◎']

def seeds(roster,seed_file=ROOT/'agent/mt/identities.tsv'):
    chosen={}
    for line in Path(seed_file).read_text().splitlines():
        if line and not line.startswith('#'):
            name,color,glyph=line.split('\t')
            assert re.fullmatch(r'#[0-9a-fA-F]{6}',color) and 1<=len(glyph)<=2
            assert name not in chosen,'duplicate identity seed'
            chosen[name]={'color':color,'glyph':glyph}
    names=[line.split('\t')[1] for line in Path(roster).read_text().splitlines() if line and not line.startswith('#')]
    assert len(set(names))==len(names) and len(names)<=len(PALETTE),'unique roster IDs, at most twelve agents'
    result={n:chosen[n] for n in names if n in chosen}
    for n in names:
        if n not in result:
            color=next(c for c in PALETTE if c not in [s['color'] for s in result.values()])
            glyph=next(g for g in GLYPHS if g not in [s['glyph'] for s in result.values()])
            result[n]={'color':color,'glyph':glyph}
    assert len({s['color'].lower() for s in result.values()})==len(names),'seed colors must be distinct'
    assert len({s['glyph'] for s in result.values()})==len(names),'seed icons must be distinct'
    return result

def missing(profile,seed):
    return {k:v for k,v in seed.items() if not profile.get(k)}

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('roster',type=Path);ap.add_argument('team')
    ap.add_argument('--world',default='imac2');ap.add_argument('--execute',action='store_true');a=ap.parse_args()
    selected={l.split('\t')[1] for l in a.roster.read_text().splitlines() if l and not l.startswith('#') and l.split('\t')[0]==a.team}
    all_seeds=seeds(a.roster)
    if not a.execute: print(json.dumps({n:all_seeds[n] for n in sorted(selected)}));return
    h=Harness(a.world)
    models=[]
    for line in a.roster.read_text().splitlines():
        fields=line.split('\t')
        if not line.startswith('#') and len(fields)>=8 and fields[1] in selected:
            models.append({'name':fields[1],'model':fields[6]})
    assert len(models)==len(selected),'every selected agent needs a public base-model label'
    req={'id':'roster-'+uuid.uuid4().hex[:12],'operator':True,'action':'mt_roster','args':{'agents':models}}
    reply=json.loads(h.command('/silent-command rcon.print(remote.call("agent_harness","dispatch",'+lua_string(json.dumps(req))+'))'))
    assert reply['ok'],reply.get('error')
    def call(name,args):
        req={'id':'identity-'+uuid.uuid4().hex[:12],'bot':name,'action':'profile','args':args}
        reply=json.loads(h.command('/silent-command rcon.print(remote.call("agent_harness","dispatch",'+lua_string(json.dumps(req))+'))'))
        assert reply['ok'],reply.get('error');return reply['result']
    for name in sorted(selected):
        before=call(name,{});patch=missing(before,all_seeds[name])
        if patch:call(name,patch)
        print(name+': '+('seeded color/icon' if patch else 'kept chosen identity'))

if __name__=='__main__':main()
