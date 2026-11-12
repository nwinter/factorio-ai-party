#!/usr/bin/env python3
"""Small operator-only market/control sampler and evidence summary.

watch RUN --minutes 45 records a snapshot every ten seconds, never starts a server.
report RUN reads only saved evidence and agent journals; compare RUN CONTROL pairs it.
Idle means no active harness action or an explicit wait, not a model performance score.
Consumption after a delivery is temporal evidence, not unique-item provenance. A stricter
aggregate lower bound subtracts all initial stock and local production before crediting imports.
"""
import argparse
from collections import Counter
import gzip
import json
from pathlib import Path
import time
from market_fixture import Client, ROOT, TARGETS

SNAPSHOT=r'''
local h=storage.agent_harness;local fxt=assert(storage.mt296_fixture,'no prepared fixture')
local r={tick=game.tick,paused=game.tick_paused,started_tick=fxt.started_tick,market=fxt.market,teams={},agents={},transactions={},messages={}}
local wanted={'iron-ore','copper-ore','iron-plate','copper-plate','copper-cable','electronic-circuit','iron-gear-wheel','automation-science-pack'}
local statusnames={};for k,v in pairs(defines.entity_status) do statusnames[v]=k end
for _,row in ipairs(fxt.teams) do
 local f=game.forces[row.team];local sf=game.surfaces.nauvis;local st=f.get_item_production_statistics(sf)
 local a={made={},used={},machines={},poor_ore=0,stock={}};r.teams[row.team]=a
 for _,n in ipairs(wanted) do a.made[n]=st.get_input_count(n);a.used[n]=st.get_output_count(n) end
 for _,e in ipairs(sf.find_entities_filtered{force=f,type={'assembling-machine','furnace','mining-drill'}}) do
  local k=e.type..':'..(statusnames[e.status] or tostring(e.status));a.machines[k]=(a.machines[k] or 0)+1
 end
 for _,e in ipairs(sf.find_entities_filtered{name=row.poor,area={{row.spawn.x-55,row.spawn.y-55},{row.spawn.x+55,row.spawn.y+55}}}) do a.poor_ore=a.poor_ore+e.amount end
 local post=h.mt.market and h.mt.market.teams[row.team] and h.mt.market.teams[row.team].post
 local inv=post and post.valid and post.get_inventory(defines.inventory.chest)
 if inv then for _,n in ipairs(wanted) do a.stock[n]=inv.get_item_count{name=n,quality='normal'} end end
end
for _,b in pairs(h.bots and h.bots.by_index or {}) do
 if r.teams[b.force] then
  local a=h.active[b.index];local alive=b.character and b.character.valid
  r.agents[b.name]={team=b.force,alive=not not alive,kind=a and a.kind or false,
    position=alive and b.character.position or false}
 end
end
for key,p in pairs(h.mt.market and h.mt.market.pairs or {}) do
 for _,tx in ipairs(p.transactions) do
  r.transactions[#r.transactions+1]={pair=key,id=tx.id,tick=tx.tick,eta=tx.eta,status=tx.status,ended_tick=tx.ended_tick,
    price=tx.price,item=tx.item,count=tx.count,escrow=tx.escrow,legs=tx.legs}
 end
end
for _,c in pairs(h.mt.pacts and h.mt.pacts.diplomacy or {}) do for _,m in ipairs(c.messages) do
 if not fxt.started_tick or m.tick>=fxt.started_tick then r.messages[#r.messages+1]=m end
end end
r.baseline=fxt.baseline
r.contact=h.mt.first
rcon.print(helpers.table_to_json(r))
'''

# Captured at activation with agents present, before the first contact and production interval.
# Inventory ids are selected by entity type, so a shared inventory cannot be counted twice.
BASELINE=r'''
fxt.baseline={teams={}}
local invs={container={'chest'},['logistic-container']={'chest'},character={'character_main','character_trash'},
 ['assembling-machine']={'assembling_machine_input','assembling_machine_output'},
 furnace={'furnace_source','furnace_result'},lab={'lab_input'},['mining-drill']={'mining_drill_output'}}
for _,row in ipairs(fxt.teams) do
 local f=game.forces[row.team];local st=f.get_item_production_statistics(game.surfaces.nauvis)
 local b={made={},used={},stock={}};fxt.baseline.teams[row.team]=b
 for n,v in pairs(st.input_counts) do b.made[n]=v end
 for n,v in pairs(st.output_counts) do b.used[n]=v end
 for typ,ids in pairs(invs) do for _,e in ipairs(game.surfaces.nauvis.find_entities_filtered{force=f,type=typ}) do
  for _,id in ipairs(ids) do local idx=defines.inventory[id];local i=idx and e.get_inventory(idx)
   if i then for _,q in pairs(i.get_contents()) do if q.quality=='normal' then b.stock[q.name]=(b.stock[q.name] or 0)+q.count end end end
  end
 end end
end
'''


def rows(path):
    if not path.exists():return []
    opener=gzip.open if path.suffix=='.gz' else open
    result=[]
    with opener(path,'rt') as f:
        for line in f:
            try:result.append(json.loads(line))
            except ValueError:pass # active writer may be finishing the final line
    return result


def summarize(samples):
    samples=[s for s in samples if s.get('started_tick') is not None and s.get('baseline')]
    assert samples,'no activated snapshots'
    first,last=samples[0],samples[-1];start=first['started_tick'];base=first['baseline']['teams']
    out={'market':last['market'],'start_tick':start,'end_tick':last['tick'],
         'minutes':(last['tick']-start)/3600,'targets':TARGETS,'teams':{},'idle':{},'fills':[],
         'measurement_notes':[
             'Idle is sampled no-action/explicit-wait simulation time; model thinking may overlap factory production.',
             'Consumption after arrival is temporal evidence. It does not identify individual fungible items.',
             'Imported-consumption lower bound = max(0, total use - initial stock - local production), capped by delivered imports; assumes no nonmarket imports.',
             'Production counts include gears consumed by science; supplied items and pre-contact production are excluded.']}
    txs=last.get('transactions') or []
    messages={ (m.get('from_team'),m.get('seq'),m.get('tick')) for s in samples for m in s.get('messages') or []}
    out['diplomacy_lines']=len(messages);out['fill_count']=len(txs)
    out['diplomacy_lines_per_fill']=len(messages)/len(txs) if txs else None
    contacts=[v for v in (last.get('contact') or {}).values() if isinstance(v,(int,float)) and v>=start]
    contact_tick=min(contacts) if contacts else start;out['contact_tick']=contact_tick
    out['decision_latency_seconds']=(min(t['tick'] for t in txs)-contact_tick)/60 if txs else None
    for team,a in last['teams'].items():
        b=base[team];made={n:v-b.get('made',{}).get(n,0) for n,v in a['made'].items()}
        used={n:v-b.get('used',{}).get(n,0) for n,v in a['used'].items()}
        delivered=Counter()
        for tx in txs:
            for leg in tx['legs']:
                if leg['to']==team:delivered[leg['item']]+=leg['delivered']
        lower={n:min(q,max(0,used.get(n,0)-b.get('stock',{}).get(n,0)-made.get(n,0))) for n,q in delivered.items()}
        progress={n:{'made':made.get(n,0),'target':q,'fraction':min(1,made.get(n,0)/q)} for n,q in TARGETS.items()}
        out['teams'][team]={'produced':made,'consumed':used,'progress':progress,
            'objective_mean_fraction':sum(p['fraction'] for p in progress.values())/len(progress),
            'delivered':dict(delivered),'imported_consumption_lower_bound':lower,'poor_ore_left':a['poor_ore']}
    for tx in txs:
        row={k:tx.get(k) for k in ('pair','id','status','tick','eta','ended_tick','item','count','price')};row['legs']=[]
        for i,leg in enumerate(tx['legs']):
            arrival=next((s for s in samples if any(t['pair']==tx['pair'] and t['id']==tx['id'] and t['legs'][i]['delivered']>0 for t in s.get('transactions') or [])),None)
            used_after=0 if arrival is None else last['teams'][leg['to']]['used'].get(leg['item'],0)-arrival['teams'][leg['to']]['used'].get(leg['item'],0)
            row['legs'].append({'to':leg['to'],'item':leg['item'],'delivered':leg['delivered'],'consumption_after_observed_arrival':used_after})
        row['followed_by_consumption']=any(l['delivered']>0 and l['consumption_after_observed_arrival']>0 for l in row['legs'])
        out['fills'].append(row)
    out['fills_followed_by_consumption']=sum(t['followed_by_consumption'] for t in out['fills'])
    active,total=Counter(),Counter();gap_ticks=0
    for s,nxt in zip(samples,samples[1:]):
        dt=nxt['tick']-s['tick']
        if dt<=0:continue
        if dt>1800:gap_ticks+=dt;continue
        for name,a in (s.get('agents') or {}).items():
            total[name]+=dt
            if a.get('kind') and not str(a['kind']).startswith('wait'):active[name]+=dt
    for name,ticks in total.items():out['idle'][name]={'sampled_seconds':ticks/60,'idle_share':1-active[name]/ticks}
    out['unmeasured_gap_seconds']=gap_ticks/60
    return out


def report(run):
    folder=ROOT/'runs'/run;out=summarize(rows(folder/'op/market-samples.jsonl'));out['run']=run
    refusals=Counter();actions=Counter();out['agents']={}
    for line in (folder/'op/teams.tsv').read_text().splitlines():
        if not line or line.startswith('#'):continue
        team,name,kind,route,model,*_=line.split('\t');d=folder/team/name
        if team not in out['teams']:continue
        events=rows(d/'journal.jsonl.gz')+rows(d/'journal.jsonl')
        req={r['request']['id']:r['request'] for r in events if r.get('event')=='request'}
        res={r['response']['id']:r['response'] for r in events if r.get('event')=='response'}
        counts=Counter()
        for ident,r in res.items():
            if ident not in req:continue
            action=req[ident]['action'];counts[action]+=1;actions[action]+=1
            if not r.get('ok'):refusals[(action,(r.get('error') or {}).get('message',''))]+=1
        out['agents'][name]={'team':team,'kind':kind,'route':route,'model':model,'requests':dict(counts)}
    out['actions']=dict(actions);out['refusals']=[{'action':a,'message':m,'count':n} for (a,m),n in refusals.most_common()]
    (folder/'op/market-results.json').write_text(json.dumps(out,indent=2)+'\n');return out


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['watch','report','compare']);p.add_argument('run')
    p.add_argument('control',nargs='?');p.add_argument('--minutes',type=float,default=45);a=p.parse_args()
    if a.action=='watch':
        claim=Path('/Users/owner/code/pog-operator/server-claim.txt');assert claim.exists() and 'eng-mt296' in claim.read_text()
        op=ROOT/'runs'/a.run/'op';op.mkdir(parents=True,exist_ok=True);c=Client();end=time.time()+a.minutes*60
        while time.time()<end:
            try:
                s=c.lua(SNAPSHOT);s['wall']=time.time()
                with (op/'market-samples.jsonl').open('a') as f:f.write(json.dumps(s,separators=(',',':'))+'\n')
            except Exception as e:
                with (op/'market-sampler-errors.jsonl').open('a') as f:f.write(json.dumps({'wall':time.time(),'error':str(e)})+'\n')
            time.sleep(10)
    elif a.action=='report':print(json.dumps(report(a.run),indent=2))
    else:
        market,control=report(a.run),report(a.control)
        out={'market':market,'control':control,'delta_objective_mean_fraction':{t:market['teams'][t]['objective_mean_fraction']-control['teams'][t]['objective_mean_fraction'] for t in market['teams']}}
        dst=ROOT/'runs'/a.run/'op/market-comparison.json';dst.write_text(json.dumps(out,indent=2)+'\n');print(dst)

if __name__=='__main__':main()
