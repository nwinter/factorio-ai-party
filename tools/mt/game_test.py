#!/usr/bin/env python3
"""Bounded fresh-game objectives: production, natural contact, negotiation and combat.

Reads actual contacts and sends scoped rules. Never relocates agents, supplies
items/technology, fabricates contact, accepts a pact or fires a weapon for them.
Started as an owned helper by start-mt.sh only when POG_GAME_TEST=1.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import time

from team_views import Reader

ROOT=Path(__file__).resolve().parents[2]

def roster(path,only=''):
    teams={}
    selected=set(only.split(',')) if only else None
    for line in Path(path).read_text().splitlines():
        f=line.split('\t')
        if line and not line.startswith('#') and len(f)>=2 and (selected is None or f[0] in selected):
            teams.setdefault(f[0],[]).append(f[1])
    assert teams and all(len(names)>=2 for names in teams.values()),'this exercise needs at least two agents per team'
    return teams

def opening(names):
    return (f'Fresh factory exercise. {names[0]} starts on smelting, power and research; {names[1]} starts on mining, '
            'supply and scouting. Agree your roles using your own tells/board; introduce your chosen names/personas. '
            'Build at least two working drills and two furnaces, then powered research and ten automation science packs '
            'from resources you gather. Keep production running. Once equipped with a gun and ammunition, the scout '
            'should explore a safe route toward the larger resource deposits around Nauvis (0,0), while the builder '
            'keeps the factory advancing. Begin scouting within ten minutes if you can travel safely; you need not '
            'wait for every science goal. Chart by actually walking. Avoid or defend against wildlife. If blocked, '
            'change the plan and do useful work; do not repeat an unchanged inspection or wait indefinitely. '
            'Report what you built, where you moved, and what your teammate independently verified.')

def contact_rules(other):
    return (f'You have made actual contact with {other}. Forces are hostile unless a cease-fire is active. '
            'Ordinary say/tells/board remain private to your own team; use diplomacy_send {to: TEAM, text: MESSAGE} '
            'and diplomacy {with: TEAM} for the contacted team. Keep building and supplying your factory while '
            'the scout negotiates. For this short exercise, try both an agreement and a brief skirmish over an '
            'outpost or resource route you actually reach. Use your own produced gear; inspect pacts before firing '
            'and explicitly end any cease-fire you decide to end. A notice period, if configured, must elapse. '
            'Do not pretend a fight occurred: record a hit, damage, ammunition spent or a destroyed target, with '
            'your teammate verifying. Negotiating a new cease-fire afterward is allowed. There are no kill points; '
            'the long-term objective remains reaching the system edge, and fighting can cost production time. '
            'If the other team does not answer within ninety seconds, keep doing useful work instead of repeating '
            'ordinary team chat and waiting for it to reach them.')

def events(contacts,teams,done):
    """Commands for newly observed pairs only. Never tell a third team private pair facts."""
    commands=[]
    for row in contacts if isinstance(contacts,list) else []:
        if not isinstance(row,dict) or row.get('kind') not in ('chart','shot'):continue
        a,b=row.get('team'),row.get('other')
        if a not in teams or b not in teams or a==b:continue
        pair=':'.join(sorted((a,b)))
        if 'contact:'+pair not in done:
            commands.append(('contact:'+pair,[(a,contact_rules(b)),(b,contact_rules(a))]))
            done.add('contact:'+pair)
        if row.get('kind')=='shot' and row.get('damage',0)>0 and 'fight:'+pair not in done:
            text=('A real hostile hit between these contacted forces is now recorded. Verify the result with your '
                  'teammate and counterpart, decide whether to continue or negotiate a cease-fire, and resume '
                  'production. Do not stand on the finished test waiting for another instruction.')
            commands.append(('fight:'+pair,[(a,text),(b,text)]));done.add('fight:'+pair)
    return commands

def run(reader,op,minutes,every):
    teams=roster(op/'teams.tsv',os.environ.get('POG_MT_TEAMS',''));receipt=op/'game-scenario.json'
    assert not receipt.exists(),'scenario already exists; do not reset its delivery cursor'
    contacts=reader.op('mt_contacts').get('contacts') or []
    assert not contacts,'fresh-game exercise refuses a world with existing contacts'
    state={'phase':'starting','started':time.time(),'deadline':time.time()+60*minutes,'teams':list(teams),
           'supplied':False,'teleported':False,'sent':[],'contacts':[]}
    def save():
        temp=receipt.with_suffix('.json.tmp');temp.write_text(json.dumps(state,indent=2));temp.replace(receipt)
    def send(key,commands):
        for team,text in commands:
            reader.op('mt_rules',{'team':team,'text':text,'summary':'Build, scout, coordinate and verify real progress.'})
        state['sent'].append(key);save()
    alive=True
    def stop(*_):
        nonlocal alive
        alive=False
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    save()
    try:
        for team,names in teams.items():send('opening:'+team,[(team,opening(names))])
        state['phase']='running';save()
        while alive and time.time()<state['deadline']:
            contacts=reader.op('mt_contacts').get('contacts') or []
            state['contacts']=contacts
            for key,commands in events(contacts,teams,set(state['sent'])):send(key,commands)
            save();time.sleep(every)
        state['phase']='finished' if alive else 'stopped'
    except Exception as e:
        state.update(phase='failed',error=str(e));raise
    finally:
        state['ended']=time.time();save()

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--minutes',type=int,default=45)
    p.add_argument('--every',type=float,default=5);p.add_argument('--execute',action='store_true');a=p.parse_args()
    assert a.run and '/' not in a.run and not a.run.startswith('.') and 1<=a.minutes<=90 and 1<=a.every<=30
    op=ROOT/'runs'/a.run/'op'
    if not a.execute:
        print('Plan: fresh production and scouting; real contact unlocks pair-scoped negotiation/skirmish objectives; no supplied items or relocation.');return
    run(Reader(),op,a.minutes,a.every)

if __name__=='__main__':main()
