#!/usr/bin/env python3
"""Offline allowlist, race semantics, event deduplication and director regressions."""
import copy
import json
import math
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'tools/mt'))
import public_race as race
import public_overlay as overlay
from public_replay import synthetic

AGENTS=[{'name':'gemini','model':'Flash','path':'PRIVATE','token':'PRIVATE'}]


def row(team='green',now=100,techs=0,entities=None,**extra):
    state={'now':now,'tick':6000,'research':{'done_count':techs},'space':{'rockets':0},'agents':[{'name':'gemini','activity':'acting','active':'build:lab'}]}
    state.update(extra)
    return race.project(team,state,AGENTS,now,{'tick':6000,'entities':entities or {}})


class ProjectionTest(unittest.TestCase):
    def test_recursive_allowlist(self):
        marker={'path':'/PRIVATE','error':'PRIVATE','token':'PRIVATE'}
        state={'now':100,'tick':6000,'errors':marker,'operator_requests':[marker],
               'research':{'current':'automation','progress':.6,'done_count':3,'path':'PRIVATE'},
               'science':{'spm':12.5,'series':[1,2,marker,float('nan')],'made':{'packs':[]}},
               'space':{'rockets':0,'planets':[marker]},
               'agents':[{'name':'gemini','display_name':'Private Person','activity':'acting','active':'craft:lab',
                          'action':'PRIVATE','job':'PRIVATE','plan':marker,'avatar':marker,'tokens':marker},
                         {'name':'private-agent','display_name':'Private Name','activity':'thinking'}],
               'chat':[{'name':'private-agent','text':'PRIVATE'},{'from':'gemini','text':'hello /Users/private/token'},
                       {'from':'gemini','text':'Ask Private Name to do it'}, {'from':'gemini','text':'Lab is ready!'}],
               'chronicle':{'entries':[marker],'events':[{'kind':'operator','text':'PRIVATE','tick':5000},
                            {'kind':'research','name':'automation','tick':5800,'line':'PRIVATE'}]},
               'basemap':{'x0':0,'y0':0,'w':2,'h':1,'cell':1,'rows':['AR'],'path':'PRIVATE','pins':[marker]}}
        out=race.project('green',state,AGENTS,110)
        encoded=json.dumps(out,allow_nan=False)
        self.assertNotIn('PRIVATE',encoded.upper());self.assertNotIn('Private Person',encoded)
        self.assertEqual(out['agents'][0]['action'],'Crafting lab')
        self.assertEqual(out['agents'][0]['display_name'],'Gemini')
        self.assertEqual([r['text'] for r in out['chat']],['Lab is ready!'])
        self.assertEqual(out['events'][0]['text'],'Automation completed')
        self.assertEqual(out['map']['rows'],['AR'])
        self.assertFalse(out['stale'])

    def test_malformed_values(self):
        out=race.project('green',{'now':100,'tick':float('nan'),'agents':[{'name':'gemini','activity':{},'active':{'secret':'x'}}],
                                 'research':{'progress':'SECRET','done_count':{'secret':'x'}},'space':{'rockets':float('inf')}},AGENTS,100)
        self.assertEqual(out['agents'][0]['activity'],'unknown')
        self.assertIsNone(out['tick']);self.assertIsNone(out['research']['progress'])
        self.assertIsNone(out['space']['rockets']);json.dumps(out,allow_nan=False)

    def test_grid_rejects_paths_and_limits(self):
        raw={'x0':0,'y0':0,'w':4,'h':1,'cell':1,'rows':['/tmp']}
        self.assertIsNone(race.grid(raw))
        self.assertIsNone(race.grid(dict(raw,w=100000)))
        self.assertIsNone(race.grid(dict(raw,rows=['AAAA'],cell=0)))

    def test_unknown_values_are_not_zero(self):
        out=race.project('green',{'now':100},AGENTS,100)
        self.assertIsNone(out['research']['done_count']);self.assertIsNone(out['science']['spm'])
        self.assertIsNone(out['entities']);self.assertIsNone(out['map'])
        race.rank([out]);self.assertIsNone(out['rank'])

    def test_fresh_score_fallback_does_not_replace_newer_feed(self):
        st={'now':100,'tick':12000,'research':{'done_count':4},'space':{'rockets':0}}
        self.assertEqual(race.project('green',st,AGENTS,100,{'tick':6000,'research':['automation']})['research']['done_count'],4)
        self.assertEqual(race.project('green',st,AGENTS,100,{'tick':13000,'research':['automation']})['research']['done_count'],1)

    def test_views_age_and_error(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);at=time.time()
            (p/'views.json').write_text(json.dumps({'t':time.strftime('%Y-%m-%d %H:%M:%S',time.localtime(at)),'teams':[]}))
            self.assertTrue(race.read_views(p,at));self.assertEqual(race.read_views(p,at+151),{})
            (p/'views.json').write_text('{');self.assertEqual(race.read_views(p,at),{})

    def test_rank_tie_stale_and_startup(self):
        teams=[row('green',entities={'lab':1,'steam-engine':1}),row('yellow',entities={'lab':1}),row('blue',entities={'lab':3})]
        basis=race.rank(teams);self.assertIn('Startup',basis)
        self.assertEqual([r['rank'] for r in teams],[1,2,2]);self.assertEqual(teams[1]['gap'],'1 startup steps back')
        teams[0]['stale']=True;race.rank(teams)
        self.assertIsNone(teams[0]['rank']);self.assertFalse(teams[0]['leader']);self.assertEqual(teams[1]['gap'],'Joint lead')
        teams=[row('green',techs=10),row('yellow',techs=8),row('blue',techs=8)]
        race.rank(teams);self.assertEqual(teams[2]['rank'],2);self.assertEqual(teams[1]['gap'],'2 techs back')
        teams[1]['space']['rockets']=1;race.rank(teams);self.assertTrue(teams[1]['leader']);self.assertEqual(teams[0]['gap'],'1 rockets back')

    def test_event_dedup_first_observation_and_save_reset(self):
        r=race.Race();a=row(entities={'lab':2})
        self.assertEqual(r.update([a],100)['events'],[])
        b=row(now=105,entities={'lab':3});b['tick']=6300;b['score_tick']=6300
        self.assertEqual(len(r.update([b],105)['events']),1)
        self.assertEqual(len(r.update([copy.deepcopy(b)],110)['events']),1)
        older=row(now=115,entities={'lab':1});older['tick']=5000
        self.assertEqual(r.update([older],115)['events'],[])

    def test_chronicle_text_is_constructed_and_prevents_delta_duplicate(self):
        r=race.Race();a=row(techs=1);r.update([a],100)
        b=row(now=105,techs=2,chronicle={'events':[{'kind':'research','name':'automation','tick':6200,'line':'PRIVATE'}]});b['tick']=6300
        events=r.update([b],105)['events'];self.assertEqual(len(events),1)
        self.assertFalse(events[0]['observed']);self.assertEqual(events[0]['time'],'01:43')

    def test_contact_only_public_teams(self):
        r=race.Race();teams=[row(),row('yellow')]
        out=r.update(teams,100,[{'a':'green','b':'private','tick':2},{'a':'green','b':'yellow','tick':6000,'text':'PRIVATE'}])
        self.assertEqual([e['text'] for e in out['events']],['First contact with Yellow'])


class DirectorTest(unittest.TestCase):
    def teams(self):return [row(t) for t in ('green','yellow','blue')]

    def test_min_dwell_then_event(self):
        d=race.Director();teams=self.teams();d.success('green',100)
        news=[{'team':'blue','kind':'rocket','at':105}]
        self.assertIsNone(d.choose(teams,news,110))
        self.assertEqual(d.choose(teams,news,115),('blue','New milestone'))
        d.success('blue',115)
        self.assertIsNone(d.choose(teams,news,125))

    def test_fairness_under_permanent_events(self):
        d=race.Director();teams=self.teams();cuts=[]
        for now in range(100,701,5):
            news=[{'team':'green','kind':'rocket','at':now}]
            pick=d.choose(teams,news,now)
            if pick:d.success(pick[0],now);cuts.append((now,pick[0]))
        for team in ('green','yellow','blue'):
            seen=[100]+[n for n,t in cuts if t==team]+[700]
            self.assertLessEqual(max(b-a for a,b in zip(seen,seen[1:])),110)

    def test_failed_cut_keeps_label_and_cools_down(self):
        d=race.Director();teams=self.teams();d.success('green',100);d.failed('yellow',130)
        self.assertEqual(d.current,'green')
        self.assertEqual(d.choose(teams,[],135)[0],'blue')
        self.assertEqual(d.shown,{'green':100})

    def test_stale_paused_and_single_team(self):
        d=race.Director();teams=self.teams();teams[0]['stale']=True;teams[1]['paused']=True
        self.assertEqual(d.choose(teams,[],100)[0],'blue');d.success('blue',100)
        self.assertIsNone(d.choose(teams,[],200));teams[2]['stale']=True
        self.assertIsNone(d.choose(teams,[],300))

    def test_camera_targets_active_agent_then_core(self):
        st={'agents':[{'activity':'acting','surface':'nauvis','position':{'x':42,'y':24}}],
            'basemap':{'x0':0,'y0':0,'w':10,'h':10,'cell':2}}
        self.assertEqual(overlay.target(st),('nauvis',42,24))
        st['agents'][0]['activity']='thinking';self.assertEqual(overlay.target(st),('nauvis',10,10))

    def test_fixture_actually_changes(self):
        frames=synthetic()
        self.assertNotEqual(frames[0]['teams'][0]['research']['progress'],frames[-1]['teams'][0]['research']['progress'])
        self.assertTrue(frames[0]['teams'][0]['leader']);self.assertTrue(frames[-1]['teams'][1]['leader'])
        self.assertGreater(len({f['camera']['team'] for f in frames}),1)


if __name__=='__main__':unittest.main()
