#!/usr/bin/env python3
"""Offline allowlist, identity, speech feed, race semantics, event deduplication and director regressions."""
import copy
import gzip
import json
import math
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock
import threading
import urllib.request
import urllib.error

sys.dont_write_bytecode = True
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'tools/mt'))
import public_race as race
import public_overlay as overlay
import public_replay as replay
import public_stream as stream
from public_replay import synthetic

AGENTS=[{'name':'gemini','model':'Flash','path':'PRIVATE','token':'PRIVATE'}]


def row(team='green',now=100,techs=0,entities=None,**extra):
    state={'now':now,'tick':6000,'research':{'done_count':techs},'space':{'rockets':0},'agents':[{'name':'gemini','activity':'acting','active':'build:lab'}]}
    state.update(extra)
    return race.project(team,state,AGENTS,now,{'tick':6000,'entities':entities or {}})


def quiet(team):
    return row(team,agents=[{'name':'gemini','activity':'idle','idle_s':300}])


class ProjectionTest(unittest.TestCase):
    def test_diplomacy_is_explicit_and_filters_private_content(self):
        teams=[row(),row('yellow'),row('blue')]
        message={'kind':'diplomacy','from_team':'green','to_team':'yellow','agent':'gemini',
                 'text':'Shall we end this pact?', 'tick':5900,'seq':1,'internal':'PRIVATE'}
        bad=[dict(message,kind='tell'),dict(message,from_team='hidden'),dict(message,agent='unknown'),
             dict(message,text='/Users/private/file'),dict(message,text='multi-team'),
             dict(message,source='site'),dict(message,to_team='green')]
        result=race.diplomacy([message]+bad,teams)
        self.assertEqual(len(result),1)
        self.assertEqual(result[0]['text'],'Shall we end this pact?')
        self.assertNotIn('PRIVATE',json.dumps(result))
        # This lane is never folded into team chat or viewer relay input.
        self.assertEqual(race.team_chat('green',[message],{'gemini'}),[])
        self.assertEqual(race.project_viewers([message],100,{'green','yellow','blue'}),[])

    def test_recursive_allowlist(self):
        marker={'path':'/PRIVATE','error':'PRIVATE','token':'PRIVATE'}
        state={'now':100,'tick':6000,'errors':marker,'operator_requests':[marker],
               'research':{'current':'automation','progress':.6,'done_count':3,'path':'PRIVATE'},
               'science':{'spm':12.5,'series':[1,2,marker,float('nan')],'made':{'packs':[]}},
               'space':{'rockets':0,'planets':[marker]},
               # A roster agent's unusable display name falls back to the roster; everything else it carries is dropped.
               'agents':[{'name':'gemini','display_name':'/Users/PRIVATE/person','activity':'acting','active':'craft:lab',
                          'action':'PRIVATE','job':'PRIVATE','plan':marker,'avatar':marker,'tokens':marker,
                          'motto':'see /PRIVATE/notes','persona':{'secret':'PRIVATE'},'glyph':'<PRIVATE>','color':'PRIVATE',
                          'pronouns':'PRIVATE','job_label':'PRIVATE','last_said':{'text':'PRIVATE'},'attention':marker,
                          'did':{'t':99,'position':{'x':1,'y':2},'action':'PRIVATE'}},
                         {'name':'private-agent','display_name':'Private Name','activity':'thinking'}],
               'chat':[{'name':'private-agent','text':'PRIVATE'},{'from':'gemini','text':'hello /Users/private/token'},
                       {'from':'gemini','text':'Ask Private Name to do it'}, {'from':'gemini','text':'Lab is ready!'}],
               'board':{'doing_items':[{'id':1,'title':'Feed the labs','owner':'gemini','note':'PRIVATE'},
                                       {'id':2,'title':'PRIVATE task','owner':'private-agent'}]},
               'chronicle':{'entries':[marker],'events':[{'kind':'operator','text':'PRIVATE','tick':5000},
                            {'kind':'research','name':'automation','tick':5800,'line':'PRIVATE'}]},
               'basemap':{'x0':0,'y0':0,'w':2,'h':1,'cell':1,'rows':['AR'],'path':'PRIVATE','pins':[marker]}}
        out=race.project('green',state,AGENTS,110)
        encoded=json.dumps(out,allow_nan=False)
        self.assertNotIn('PRIVATE',encoded.upper());self.assertNotIn('Private Name',encoded)
        self.assertEqual(out['agents'][0]['action'],'Crafting lab')
        self.assertEqual(out['agents'][0]['display_name'],'Gemini')
        self.assertEqual(out['agents'][0]['task'],'Feed the labs')
        self.assertEqual([r['text'] for r in out['chat']],['Lab is ready!'])
        self.assertEqual(out['events'][0]['text'],'Automation completed')
        self.assertEqual(out['map']['rows'],['AR'])
        self.assertFalse(out['stale'])
        # The camera's private view carries only names, numbers and an action class.
        subs=race.subjects(state,{'gemini'},110)
        self.assertNotIn('PRIVATE',json.dumps(subs).upper())

    def test_malformed_values(self):
        out=race.project('green',{'now':100,'tick':float('nan'),'agents':[{'name':'gemini','activity':{},'active':{'secret':'x'},'idle_s':float('inf'),'interest':'x'}],
                                 'research':{'progress':'SECRET','done_count':{'secret':'x'}},'space':{'rockets':float('inf')}},AGENTS,100)
        self.assertIsNone(out['agents'][0]['activity']);self.assertIsNone(out['agents'][0]['action'])
        self.assertIsNone(out['tick']);self.assertIsNone(out['research']['progress'])
        self.assertIsNone(out['space']['rockets']);json.dumps(out,allow_nan=False)
        json.dumps(race.subjects({'agents':[{'name':'gemini','position':{'x':float('nan'),'y':1},'surface':'nauvis'},
                                            {'name':'gemini','position':{'x':1,'y':1},'surface':'nauvis','interest':float('inf'),'idle_s':'x','did':{'t':'x'}}]},{'gemini'},100),allow_nan=False)

    def test_grid_rejects_paths_and_limits(self):
        raw={'x0':0,'y0':0,'w':4,'h':1,'cell':1,'rows':['/tmp']}
        self.assertIsNone(race.grid(raw))
        self.assertIsNone(race.grid(dict(raw,w=100000)))
        self.assertIsNone(race.grid(dict(raw,rows=['AAAA'],cell=0)))

    def test_unknown_values_are_not_zero(self):
        out=race.project('green',{'now':100},AGENTS,100)
        self.assertIsNone(out['research']['done_count']);self.assertIsNone(out['science']['spm'])
        self.assertIsNone(out['entities']);self.assertIsNone(out['map'])
        self.assertEqual(out['agents'][0]['model'],'Flash')
        self.assertIsNone(out['agents'][0]['activity']);self.assertIsNone(out['agents'][0]['action'])
        self.assertIsNone(out['agents'][0]['idle_s']);self.assertIsNone(out['agents'][0]['verb'])
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
        self.assertEqual([r['rank'] for r in teams],[1,2,2]);self.assertEqual(teams[1]['gap'],'1 startup step back')
        teams[0]['stale']=True;race.rank(teams)
        self.assertIsNone(teams[0]['rank']);self.assertFalse(teams[0]['leader']);self.assertEqual(teams[1]['gap'],'Joint lead')
        teams=[row('green',techs=10),row('yellow',techs=8),row('blue',techs=8)]
        race.rank(teams);self.assertEqual(teams[2]['rank'],2);self.assertEqual(teams[1]['gap'],'2 techs back')
        teams[1]['space']['rockets']=1;race.rank(teams);self.assertTrue(teams[1]['leader']);self.assertEqual(teams[0]['gap'],'1 rocket back')

    def test_pact_events_are_constructed_and_only_name_known_teams(self):
        r=race.Race();teams=[row(),row('yellow'),row('blue')]
        pacts=[{'id':4,'a':'green','b':'yellow','status':'active','accepted_tick':5900,'note':'PRIVATE','terms':'/Users/private'},
               {'id':5,'a':'green','b':'secret','status':'active','accepted_tick':5900}]
        out=r.update(teams,100,pacts=pacts)
        self.assertEqual(len(out['events']),1)
        self.assertEqual(out['events'][0]['text'],'Pact #4 signed with Yellow')
        self.assertEqual(out['events'][0]['other'],'yellow')
        self.assertNotIn('PRIVATE',json.dumps(out));self.assertNotIn('secret',json.dumps(out))
        self.assertEqual(teams[0]['pacts'],[{'id':4,'with':'yellow'}])
        self.assertEqual(teams[2]['pacts'],[])
        self.assertEqual(len(r.update(teams,105,pacts=pacts)['events']),1)
        pacts[0].update(status='ended',ended_tick=6000)
        out=r.update(teams,110,pacts=pacts)
        self.assertEqual(out['teams'][0]['pacts'],[])
        self.assertEqual({e['text'] for e in out['events']},{'Pact #4 signed with Yellow','Pact #4 with Yellow ended'})
        self.assertEqual(len({e['id'] for e in out['events']}),2)

    def test_event_dedup_first_observation_and_save_reset(self):
        r=race.Race();a=row(entities={'lab':2})
        self.assertEqual(r.update([a],100)['events'],[])
        b=row(now=105,entities={'lab':3});b['tick']=6300;b['score_tick']=6300
        self.assertEqual(len(r.update([b],105)['events']),1)
        first=r.update([copy.deepcopy(b)],110)['events']
        self.assertEqual(len(first),1);self.assertRegex(first[0]['id'],r'^[0-9a-f]{12}$')
        older=row(now=115,entities={'lab':1});older['tick']=5000
        self.assertEqual(r.update([older],115)['events'],[])

    def test_chronicle_text_is_constructed_and_prevents_delta_duplicate(self):
        r=race.Race();a=row(techs=1);r.update([a],100)
        b=row(now=105,techs=2,chronicle={'events':[{'kind':'research','name':'automation','tick':6200,'line':'PRIVATE'}]});b['tick']=6300
        events=r.update([b],105)['events'];self.assertEqual(len(events),1)
        self.assertFalse(events[0]['observed']);self.assertEqual(events[0]['time'],'01:43')

    def test_contact_only_public_teams(self):
        r=race.Race();teams=[row(),row('yellow')]
        out=r.update(teams,100,[{'team':'green','other':'private','tick':2,'kind':'chart'},
                                {'team':'green','other':'yellow','tick':6000,'kind':'chart','text':'PRIVATE'}])
        self.assertEqual([e['text'] for e in out['events']],['First contact with Yellow'])
        self.assertEqual(out['events'][0]['other'],'yellow')

    def test_real_stream_research_and_private_chat_lanes(self):
        state={'now':100,'tick':6300,'research':{'done_count':1,'recent':[{'name':'automation','tick':6000,'label':'PRIVATE'}]},
               'chronicle':{'events':[{'kind':'research','tick':6000,'line':'research finished: automation'}]},
               'chat':[{'agent':'gemini','text':'PRIVATE','lane':'tell'}, {'agent':'gemini','text':'PRIVATE','lane':'operator'},
                       {'agent':'gemini','text':'PRIVATE','lane':'talk','confess':True},
                       {'agent':'gemini','text':'Hello Nick','lane':'talk'}, {'agent':'gemini','text':'Labs are ready','lane':'talk'}]}
        out=race.project('green',state,AGENTS,100)
        self.assertEqual([e['text'] for e in out['events']],['Automation completed'])
        self.assertEqual([c['text'] for c in out['chat']],['Labs are ready'])
        self.assertNotIn('PRIVATE',json.dumps(out))

    def test_rebuilding_is_not_first_and_old_events_do_not_trigger_cut(self):
        r=race.Race();r.update([row(entities={'lab':1})],100)
        r.update([row(now=105)],105)
        rebuilt=row(now=110,entities={'lab':1});rebuilt['tick']=6600
        self.assertEqual(r.update([rebuilt],110)['events'][0]['text'],'+1 lab · 1 total')
        recent=row('blue',now=120,chronicle={'events':[{'kind':'research','name':'automation','tick':60}]})
        news=r.update([recent],120)['events']
        d=race.Director();d.success('green',100)
        self.assertIsNone(d.choose([row(now=120),recent],news,120))

    def test_speech_keeps_ordinary_slashes_and_marks_long_lines(self):
        self.assertEqual(race.speech('Shares green 0.52 / yellow 0.48, 50 iron/hr'),'Shares green 0.52 / yellow 0.48, 50 iron/hr')
        for private in ('see /Users/private/x','notes at ~/code','C:\\Users\\x','path=/tmp/x','(/etc/passwd)','mail a@b.co','the operator said','token abc'):
            self.assertEqual(race.speech(private),'',private)
        long=race.speech('word '*200)
        self.assertLessEqual(len(long),300);self.assertTrue(long.endswith('…'));self.assertNotIn('  ',long)

    def test_production_http_poll_and_fixed_assets(self):
        with tempfile.TemporaryDirectory() as d:
            op=Path(d);td=op/'runs/test/green';td.mkdir(parents=True)
            (td/'team.tsv').write_text('gemini\tagy\troute\tmodel\thigh\tFlash\tagy\n')
            (op/'streams.txt').write_text('green http://127.0.0.1:1/\n')
            (op/'views.json').write_text(json.dumps({'t':time.strftime('%Y-%m-%d %H:%M:%S'),'teams':[{'team':'green','score':{'tick':6000,'entities':{'lab':2},'research':['automation']}}]}))
            service=overlay.PublicOverlay(op,op,'test',port=0,camera=False)
            raw={'now':time.time(),'tick':6000,'research':{'done_count':1},'space':{'rockets':0},'tokens':{'secret':'PRIVATE'},
                 'agents':[{'name':'gemini','display_name':'Vesper','profile_set':True,'color':'#34a853'}],
                 'chat':[{'seq':4,'from':'gemini','text':'Labs are ready','lane':'talk','tick':5900}]}
            # One production poll, no camera or real game/network request.
            with mock.patch.object(overlay,'fetch',return_value=raw), mock.patch.object(service.stop,'wait',side_effect=lambda _:service.stop.set()):
                service.poll()
            threading.Thread(target=service.http.serve_forever,daemon=True).start()
            url=f'http://127.0.0.1:{service.http.server_port}'
            try:
                with urllib.request.urlopen(url+'/state.json') as response:state=json.load(response)
                self.assertEqual(state['teams'][0]['entities']['lab'],2)
                self.assertEqual(state['teams'][0]['rank'],1)
                self.assertEqual(state['teams'][0]['agents'][0]['display_name'],'Vesper')
                self.assertEqual([m['text'] for m in state['feed']],['Labs are ready'])
                self.assertEqual(state['layout'],{'camera':list(overlay.CAMERA_RECT)})
                self.assertNotIn('PRIVATE',json.dumps(state))
                for asset in ('/','/overlay.js','/avatar.js','/mapview.js','/fonts/titillium-web-600.woff2','/fonts/big-shoulders-display-var.woff2',
                              '/static/game/item/lab.webp','/static/game/tech/automation.webp'):
                    with urllib.request.urlopen(url+asset) as response:self.assertGreater(len(response.read()),100)
                for forbidden in ('/views.json','/static/game/item/../../gameicons.py','/static/game/item/secret.webp','/fonts/../public_race.py',
                                  '/fonts/OFL-titillium-web.txt','/public_race.py','/overlay.js/..'):
                    with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(url+forbidden)
                    self.assertEqual(e.exception.code,404);e.exception.close()
            finally:service.close()

    def test_page_draws_text_only_on_canvas_and_loads_nothing_remote(self):
        for name in ('public-overlay.html','public-overlay.js'):
            source=(ROOT/'tools/mt'/name).read_text()
            self.assertNotIn('innerHTML',source);self.assertNotIn('https://',source);self.assertNotIn('http://',source)
            self.assertNotIn('eval(',source);self.assertNotIn('document.write',source)
            # OBS's browser source can be as old as Chrome 103: nothing newer than that in the page.
            for newer in ('structuredClone','.toSorted(','.toReversed(','.findLast(','.with(','Object.groupBy','Array.fromAsync',
                          '.roundRect(',':has(','color-mix','@container','.at(-','??=','||=','&&=','.replaceAll('):
                self.assertNotIn(newer,source,newer)
        js=(ROOT/'tools/mt/public-overlay.js').read_text()
        self.assertIn("'letterSpacing' in ctx",js)       # Chrome 99+: used only where present
        self.assertIn('Graphics copyright Wube Software',js);self.assertIn('CREDIT_EVERY = 3600',js)


class IdentityTest(unittest.TestCase):
    def project(self,live,roster=None):
        roster=roster or [{'name':'gemini','model':'Gemini 3.8 Flash'}]
        return race.project('green',{'now':100,'agents':[dict(live,name='gemini')]},roster,100)['agents'][0]

    def test_chosen_identity_reaches_the_overlay(self):
        out=self.project({'display_name':'Vesper','profile_set':True,'color':'#34A853','glyph':'♊','motto':'Mining today, rocket tomorrow',
                          'pronouns':' She/Her ','avatar':{'base':'robot','helmet':'power','visor':'nope','accent':'#33CCFF','extra':'x'}},
                         [{'name':'gemini','model':'Gemini 3.8 Flash','color':'#112233','glyph':'R','icon':'iron-gear-wheel','persona':'Seeded persona'}])
        self.assertEqual(out['name'],'gemini');self.assertEqual(out['display_name'],'Vesper');self.assertTrue(out['named'])
        self.assertEqual(out['color'],'#34a853');self.assertEqual(out['glyph'],'♊');self.assertEqual(out['icon'],'iron-gear-wheel')
        self.assertEqual(out['persona'],'Mining today, rocket tomorrow');self.assertEqual(out['pronouns'],'she/her')
        self.assertEqual(out['avatar'],{'base':'robot','helmet':'power','accent':'#33ccff'})
        self.assertEqual(out['model'],'Gemini 3.8 Flash')

    def test_roster_seeds_apply_until_the_agent_chooses(self):
        seeded=[{'name':'gemini','model':'Flash','color':'#112233','icon':'⚙','display_name':'Cog','persona':'Seeded persona'}]
        out=self.project({},seeded)
        self.assertEqual((out['display_name'],out['color'],out['glyph'],out['icon'],out['persona']),('Cog','#112233','⚙',None,'Seeded persona'))
        out=self.project({'display_name':'Gemini'},[{'name':'gemini','model':'Flash'}])
        self.assertEqual(out['display_name'],'Gemini');self.assertFalse(out['named'])
        self.assertIsNone(out['color']);self.assertIsNone(out['glyph']);self.assertEqual(out['persona'],'')

    def test_unusable_identity_falls_back(self):
        for bad in ('Nick','nick winter','Operator','The Moderator','YouTube','/Users/x','~/notes','<b>x</b>','x','https://a.b','a@b.co','secret token',123,None,{'a':1},'x'*201):
            out=self.project({'display_name':bad,'profile_set':True})
            self.assertEqual(out['display_name'],'Gemini',bad);self.assertFalse(out['named'])
        self.assertEqual(self.project({'display_name':'Sprocket ⚙️ the  Great!!'})['display_name'],'Sprocket the Great!!')
        self.assertEqual(self.project({'display_name':'A very long chosen name that keeps going'})['display_name'],'A very long chosen name')
        self.assertEqual(len(self.project({'display_name':'Supercalifragilisticexpialidocious'})['display_name']),24)
        for color in ('red','#12345','#1234567','#gggggg',7):self.assertIsNone(self.project({'color':color})['color'])
        for g in ('<','too long glyph',' ','a b','\x07',5):self.assertIsNone(self.project({'glyph':g})['glyph'])
        for g in ('G2','♊','👩‍🚀','⚡'):self.assertEqual(self.project({'glyph':g})['glyph'],g)
        self.assertEqual(self.project({'pronouns':'he/him/his'})['pronouns'],'he/him/his')
        for p in ('attack helicopter','he/<b>','they/them/'+'x'*30,7):self.assertIsNone(self.project({'pronouns':p})['pronouns'])
        for a in ({'base':'dragon'},'robot',['robot'],{'accent':'red'}):self.assertIsNone(self.project({'avatar':a})['avatar'])
        self.assertEqual(self.project({'persona':'see /Users/x/notes','motto':'Ratios first.'})['persona'],'Ratios first.')
        self.assertEqual(self.project({'motto':'Ask Nick'})['persona'],'')

    def test_roster_reads_identity_columns(self):
        with tempfile.TemporaryDirectory() as d:
            td=Path(d)/'runs/r/green';td.mkdir(parents=True)
            (td/'team.tsv').write_text('# name\tkind\troute\tmodel\teffort\tlabel\tharness\tcolor\ticon\tdisplay\tpersona\tprivate_note\n'
                                       'gemini\tagy\tagy\tgemini\t-\tGemini 3.8 Flash\tAntigravity\t#34a853\tiron-gear-wheel\tCog\tKeeps the belts full\tPRIVATE\n'
                                       'gemini2\tagy\tagy\tgemini\t-\tGemini 3.8 Flash\tAntigravity\t-\t\t-\n')
            agents=overlay.roster(Path(d),'r','green')
            self.assertEqual(agents[0],{'name':'gemini','model':'Gemini 3.8 Flash','harness':'Antigravity','color':'#34a853',
                                        'icon':'iron-gear-wheel','display_name':'Cog','persona':'Keeps the belts full'})
            self.assertEqual(agents[1],{'name':'gemini2','model':'Gemini 3.8 Flash','harness':'Antigravity'})
            # The launcher's present seven-column file, with or without its header, reads as before.
            (td/'team.tsv').write_text('# name\tkind\troute\tmodel\teffort\tlabel\tharness\ngrok\tgrok\tgrok\tgrok-4.7\tlow\tGrok 4.7\tGrok Build\n')
            self.assertEqual(overlay.roster(Path(d),'r','green'),[{'name':'grok','model':'Grok 4.7','harness':'Grok Build'}])
            (td/'team.tsv').write_text('grok\tgrok\tgrok\tgrok-4.7\tlow\tGrok 4.7\tGrok Build\t#ffffff\n')
            self.assertEqual(overlay.roster(Path(d),'r','green'),[{'name':'grok','model':'Grok 4.7','harness':'Grok Build'}])

    def test_death_news_uses_the_chosen_name(self):
        state={'now':100,'tick':6300,'agents':[{'name':'gemini','display_name':'Vesper'}],'chronicle':{'events':[{'kind':'death','agent':'gemini','tick':6200,'cause':'PRIVATE'}]}}
        self.assertEqual(race.project('green',state,AGENTS,100)['events'][0]['text'],'Vesper was lost')


class ConversationTest(unittest.TestCase):
    def setUp(self):
        self.roster=[{'name':n,'model':'Gemini Flash'} for n in ('gemini1','gemini2')]
        self.tell={'from':'gemini1','agent':'gemini1','lane':'tell','tell':True,'to':['gemini2'],
                   'body':'I will build the labs. Please bring copper.', 'text':'PRIVATE presentation name',
                   'to_shown':'PRIVATE display name','tick':6000}

    def project_chat(self, messages, team='green', roster=None):
        return race.project(team,{'now':100,'chat':messages},self.roster if roster is None else roster,100)['chat']

    def test_two_agent_tell_and_reply_stay_in_own_team(self):
        reply=dict(self.tell,agent='gemini2',**{'from':'gemini2'},to=['gemini1'],body='Copper is on the way.')
        own=self.project_chat([self.tell,reply])
        self.assertEqual([m['name'] for m in own],['gemini1','gemini2'])
        self.assertEqual([m['team'] for m in own],['green','green'])
        self.assertEqual(own[0]['to'],['gemini2'])
        self.assertNotIn('PRIVATE',json.dumps(own))
        other=[{'name':n,'model':'Grok'} for n in ('grok1','grok2')]
        self.assertEqual(self.project_chat([self.tell,reply],'yellow',other),[])
        self.assertEqual(race.project_viewers(own,100,('green','yellow')),[])
        data=race.Race().update([row(chat=[self.tell])],100)
        self.assertEqual(data['events'],[])

    def test_reject_cross_team_unknown_recipient_and_wrong_scope(self):
        rejected=[dict(self.tell,to=['grok1']),dict(self.tell,to=['gemini2','grok1']),
                  dict(self.tell,to=['team','grok1']),dict(self.tell,to=[]),dict(self.tell,to={}),
                  dict(self.tell,team='yellow'),dict(self.tell,force='yellow'),dict(self.tell,operator=True),
                  dict(self.tell,confess=True),dict(self.tell,source='site'),dict(self.tell,body=None),
                  dict(self.tell,agent='gemini1',**{'from':'grok1'})]
        self.assertEqual(self.project_chat(rejected),[])
        good=self.project_chat([dict(self.tell,to='team'),dict(self.tell,to=['pog-gemini2'])])
        self.assertEqual([m['to'] for m in good],[['team'],['gemini2']])

    def test_chat_history_keeps_both_speakers_and_bounded_fields(self):
        msgs=[dict(self.tell,body='Lab '+str(i),tokens='PRIVATE',error='PRIVATE') for i in range(20)]
        own=self.project_chat(msgs)
        self.assertEqual(len(own),12)
        self.assertEqual(own[-1]['text'],'Lab 19')
        self.assertEqual(set(own[0]),{'id','team','name','to','kind','text','tick','t','at','reply'})

    def test_line_ids_time_and_restored_lines(self):
        said=[{'seq':7,'tick':5400,'from':'gemini1','text':'Earlier line','lane':'log','t':99},          # restored at a service start
              {'seq':8,'tick':5940,'from':'gemini1','text':'Live line','lane':'talk','t':98.5,'reply_to':3},
              dict(self.tell,seq='t3',t=99.0),
              {'tick':5700,'from':'gemini2','text':'No sequence','lane':'talk'},
              {'seq':'9; drop','tick':5800,'from':'gemini2','text':'Odd sequence','lane':'talk'}]
        own=race.project('green',{'now':100,'tick':6000,'chat':said},self.roster,100)['chat']
        self.assertEqual([m['id'] for m in own][:3],['green:7','green:8','green:t3'])
        self.assertRegex(own[3]['id'],r'^green:[0-9a-f]{12}$');self.assertRegex(own[4]['id'],r'^green:[0-9a-f]{12}$')
        self.assertEqual(own[0]['at'],90.0)      # from its tick: 600 ticks before the feed's own
        self.assertEqual(own[1]['at'],98.5);self.assertEqual(own[3]['at'],95.0)
        self.assertEqual([m['reply'] for m in own],[False,True,False,False,False])
        again=race.project('green',{'now':130,'tick':7800,'chat':said},self.roster,130)['chat']
        self.assertEqual([m['id'] for m in again],[m['id'] for m in own])

    def test_viewer_sources_and_receipts_only(self):
        msgs=[{'source':source,'name':'PRIVATE author','text':'Keep the labs fed!','t':95,
               'targets':['all'],'delivery':'sent','delivery_why':'PRIVATE','tokens':'PRIVATE'}
              for source in ('site','youtube')]
        out=race.project_viewers(msgs,100,('green','yellow','blue'))
        self.assertEqual([m['source'] for m in out],['site','youtube'])
        self.assertTrue(all(m['delivery']=='sent' and m['targets']==['all'] for m in out))
        self.assertNotIn('PRIVATE',json.dumps(out))
        invalid=dict(msgs[0],targets=['green','PRIVATE'],delivery='PRIVATE')
        clean=race.project_viewers([invalid],100,('green',))[0]
        self.assertEqual(clean['targets'],[]);self.assertIsNone(clean['delivery'])

    def test_viewer_lane_rejects_team_messages_stale_and_private_text(self):
        base={'source':'site','text':'Copper next?','t':95}
        msgs=[dict(base,lane='tell'),dict(base,kind='talk'),dict(base,team='green'),dict(base,agent='gemini1'),
              dict(base,**{'from':'gemini1'}),dict(base,tell=True),dict(base,operator=True),dict(base,source='private'),
              dict(base,t=-1000),dict(base,t=1000),dict(base,text='Path /Users/private/file'),dict(base,text='Ask Nick')]
        self.assertEqual(race.project_viewers(msgs,100,('green',)),[])


class FeedTest(unittest.TestCase):
    """One chronological speech feed across teams, built only from each team's own scoped lines."""
    def team(self,name,names,chat,now=100,tick=6000):
        return race.project(name,{'now':now,'tick':tick,'research':{'done_count':0},'space':{'rockets':0},'chat':chat},
                            [{'name':n,'model':'M'} for n in names],now)

    def test_feed_merges_teams_in_time_order_and_outlives_the_service_window(self):
        r=race.Race()
        green=self.team('green',('gemini','gemini2'),[{'seq':1,'tick':5400,'from':'gemini','text':'First','lane':'talk','t':90}])
        yellow=self.team('yellow',('grok','grok2'),[{'seq':1,'tick':5700,'from':'grok','text':'Second','lane':'talk','t':95},
                                                    {'seq':'t1','tick':5880,'from':'grok2','tell':True,'lane':'tell','to':['grok'],'body':'Third','t':98}])
        feed=r.update([green,yellow],100)['feed']
        self.assertEqual([(m['team'],m['name'],m['kind'],m['text']) for m in feed],
                         [('green','gemini','talk','First'),('yellow','grok','talk','Second'),('yellow','grok2','tell','Third')])
        self.assertEqual(set(feed[0]),{'id','team','name','to','kind','text','tick','at','reply'})
        self.assertEqual(len({m['id'] for m in feed}),3)
        # The team services show only their latest lines; the feed keeps what it has seen, once.
        green=self.team('green',('gemini','gemini2'),[{'seq':2,'tick':6200,'from':'gemini2','text':'Fourth','lane':'talk','t':104}],105,6300)
        yellow=self.team('yellow',('grok','grok2'),[{'seq':1,'tick':5700,'from':'grok','text':'Second','lane':'talk','t':95}],105,6300)
        feed=r.update([green,yellow],105)['feed']
        self.assertEqual([m['text'] for m in feed],['First','Second','Third','Fourth'])
        many=[{'seq':10+i,'tick':6300+i,'from':'gemini','text':f'Line {i}','lane':'talk','t':106+i/100} for i in range(60)]
        for start in range(0,60,10):
            feed=r.update([self.team('green',('gemini','gemini2'),many[start:start+10],110,6400),yellow],110)['feed']
        self.assertEqual(len(feed),40);self.assertEqual(feed[-1]['text'],'Line 59')

    def test_feed_holds_no_foreign_viewer_or_operator_rows(self):
        r=race.Race()
        green=self.team('green',('gemini',),[{'seq':1,'tick':5400,'from':'grok','text':'FOREIGN','lane':'talk'},
                                             {'seq':2,'tick':5400,'from':'gemini','text':'OPERATOR','lane':'operator'},
                                             {'seq':3,'tick':5400,'from':'viewer A','text':'VIEWER','viewer':True,'source':'site','lane':'viewer'},
                                             {'seq':4,'tick':5400,'from':'gemini','text':'NOTICE','notice':True},
                                             {'seq':5,'tick':5400,'from':'gemini','text':'Mine'}])
        # A row smuggled into another team's projected chat is not adopted by the feed.
        yellow=self.team('yellow',('grok',),[])
        yellow['chat'].append(dict(green['chat'][0],text='SMUGGLED'))
        feed=r.update([green,yellow],100)['feed']
        self.assertEqual([m['text'] for m in feed],['Mine'])

    def test_diplomacy_joins_the_feed_as_its_own_kind(self):
        r=race.Race();teams=[self.team('green',('gemini',),[]),self.team('yellow',('grok',),[])]
        talks=race.diplomacy([{'kind':'diplomacy','from_team':'yellow','to_team':'green','agent':'grok','text':'Cease-fire?','tick':5900,'seq':2}],teams)
        feed=r.update(teams,100,diplomacy=talks)['feed']
        self.assertEqual(len(feed),1)
        self.assertEqual({k:feed[0][k] for k in ('id','kind','team','name','to_team','text')},
                         {'id':'dip:green-yellow:2','kind':'diplomacy','team':'yellow','name':'grok','to_team':'green','text':'Cease-fire?'})
        self.assertEqual(len(r.update(teams,105,diplomacy=talks)['feed']),1)

    def test_loading_an_older_save_clears_that_team_only(self):
        r=race.Race()
        green=self.team('green',('gemini',),[{'seq':1,'tick':5400,'from':'gemini','text':'Green line','lane':'talk','t':90}])
        yellow=self.team('yellow',('grok',),[{'seq':1,'tick':5400,'from':'grok','text':'Yellow line','lane':'talk','t':91}])
        r.update([green,yellow],100)
        older=self.team('green',('gemini',),[],105,3000)
        self.assertEqual([m['text'] for m in r.update([older,yellow],105)['feed']],['Yellow line'])


class OrderedFeedTest(unittest.TestCase):
    """The operator's ordered feed (mt_feed, via views.json.feed): one sequence across teams, notes and announcements."""
    def setUp(self):
        mk=lambda team,names:race.project(team,{'now':100,'tick':6000,'research':{'done_count':0},'space':{'rockets':0},
            'chat':[{'seq':9,'tick':5900,'from':names[0],'text':'We split it: I feed the labs.','lane':'talk','reply_to':3,'t':99}]},
            [{'name':n,'model':'Model '+team} for n in names],100)
        self.teams=[mk('green',('gemini','gemini2')),mk('yellow',('grok','grok2'))]
        self.line={'seq':2,'tick':5700,'team':'green','agent':'gemini','kind':'tell','scope':'team-private','text':'Build the smelter while I mine.',
                   'to':['gemini2'],'identity':{'display_name':'Forge','persona':'A patient builder.','color':'#3CB44B','glyph':'⚙'},'internal':'PRIVATE'}

    def lines(self,raw):
        return race.broadcast(overlay.project_feed(raw,self.teams),self.teams,100)

    def test_every_kind_in_sequence_with_its_own_shape(self):
        raw=[dict(self.line,seq=5,kind='identity',scope='public',to={},text='Forge: A patient builder.'),
             self.line,dict(self.line,seq=1,kind='say',to={},text='We split it: I feed the labs.'),
             dict(self.line,seq=3,kind='board',to=[],text='#4 posted: Iron smelting — two drills a furnace'),
             dict(self.line,seq=4,kind='diplomacy',scope='diplomacy',to=['yellow'],text='Cease-fire, equal shares?'),self.line]
        out=self.lines(raw)
        self.assertEqual([(m['id'],m['kind']) for m in out],[('f:1','talk'),('f:2','tell'),('f:3','board'),('f:4','diplomacy'),('f:5','identity')])
        self.assertEqual(out[1]['to'],['gemini2']);self.assertEqual(out[3]['to_team'],'yellow')
        self.assertEqual(out[2]['text'],'posted: Iron smelting — two drills a furnace')
        self.assertEqual((out[4]['title'],out[4]['text']),('Forge','A patient builder.'))
        self.assertEqual(out[1]['at'],95.0)                       # 300 ticks before the newest team clock
        self.assertEqual(set(out[0]),{'id','team','name','to','kind','text','tick','at','reply'})
        self.assertNotIn('PRIVATE',json.dumps(out))

    def test_scope_roster_and_text_rules(self):
        bad=[dict(self.line,to=['grok']),dict(self.line,scope='public'),dict(self.line,agent='grok'),dict(self.line,team='hidden'),
             dict(self.line,operator=True),dict(self.line,source='site'),dict(self.line,kind='confess'),dict(self.line,seq=True),
             dict(self.line,tick=-1),dict(self.line,kind='diplomacy',scope='diplomacy',to=['green']),
             dict(self.line,kind='identity',scope='public',to=[],identity={'display_name':'/Users/private'}),
             dict(self.line,kind='identity',scope='public',to=[],identity={'display_name':'Moderator'})]
        bad+=[dict(self.line,text=t) for t in ('/Users/private/file','the operator fixed it','multi-team','ask Nick','password=abc','https://private.invalid')]
        self.assertEqual(self.lines(bad),[])
        ok=self.lines([dict(self.line,text='Shares green 0.52 / yellow 0.48, 50 iron/hr')])
        self.assertEqual([m['text'] for m in ok],['Shares green 0.52 / yellow 0.48, 50 iron/hr'])     # an ordinary slash is speech
        long=self.lines([dict(self.line,text='word '*900)])[0]['text']
        self.assertLessEqual(len(long),300);self.assertTrue(long.endswith('…'))

    def test_ordered_feed_replaces_the_chat_windows_and_keeps_viewer_answers(self):
        r=race.Race()
        raw=[dict(self.line,seq=1,kind='say',to={},text='We split it: I feed the labs.'),dict(self.line,seq=2,team='yellow',agent='grok',to=['grok2'])]
        feed=r.update(self.teams,100,lines=self.lines(raw))['feed']
        self.assertEqual([(m['id'],m['team'],m['reply']) for m in feed],[('f:1','green',True),('f:2','yellow',False)])   # no chat-window copies
        # A poll without the operator feed (a stale views file) adds nothing twice; the feed resumes when it returns.
        self.assertEqual(len(r.update(self.teams,105)['feed']),2)
        self.assertEqual(len(r.update(self.teams,110,lines=self.lines(raw+[dict(self.line,seq=3)]))['feed']),3)
        # A line whose sender is not on the projected roster is not adopted.
        ghost={'id':'f:9','team':'green','name':'ghost','to':[],'kind':'talk','text':'GHOST','tick':5990,'at':99,'reply':False}
        self.assertNotIn('GHOST',json.dumps(r.update(self.teams,115,lines=[ghost])['feed']))
        # Without an operator feed at all, speech still comes from each team's own chat window.
        self.assertEqual([m['id'] for m in race.Race().update(self.teams,100)['feed']],['green:9','yellow:9'])


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

    def test_goes_to_the_team_that_is_doing_something(self):
        # Yellow stands still; blue is building. At the ordinary dwell the camera picks blue, not the next in line.
        d=race.Director();teams=[row('green'),quiet('yellow'),row('blue')];d.success('green',100)
        self.assertIsNone(d.choose(teams,[],125))
        self.assertEqual(d.choose(teams,[],130),('blue','Following the action'))
        # The first shot of a stream is the busiest team too.
        self.assertEqual(race.Director().choose([quiet('green'),quiet('yellow'),row('blue')],[],100),('blue','Following the action'))

    def test_stays_with_the_only_team_at_work_and_leaves_dead_air_early(self):
        d=race.Director();teams=[row('green'),quiet('yellow'),quiet('blue')];d.success('green',100)
        self.assertIsNone(d.choose(teams,[],135))      # past the ordinary dwell: nobody else is doing anything
        self.assertIsNone(d.choose(teams,[],150))
        d=race.Director();teams=[quiet('green'),quiet('yellow'),row('blue')];d.success('green',100)
        self.assertIsNone(d.choose(teams,[],110))      # the minimum dwell always holds
        self.assertEqual(d.choose(teams,[],115),('blue','Following the action'))

    def test_quiet_team_keeps_its_turn_as_a_glance(self):
        d=race.Director();teams=[row('green'),quiet('yellow'),quiet('blue')]
        self.assertEqual(d.choose(teams,[],100),('green','Following the action'));d.success('green',100)
        # Fairness is unchanged: unseen for dwell x teams, oldest first.
        self.assertIsNone(d.choose(teams,[],155))
        self.assertEqual(d.choose(teams,[],160),('yellow','Around the teams'));d.success('yellow',160)
        self.assertTrue(d.glance)
        self.assertIsNone(d.choose(teams,[],170))
        # Blue is as overdue as yellow was: it gets its own glance, then the camera returns to the team at work
        # after the minimum dwell, well before the ordinary one.
        self.assertEqual(d.choose(teams,[],175),('blue','Around the teams'));d.success('blue',175)
        self.assertTrue(d.glance)
        self.assertEqual(d.choose(teams,[],190),('green','Following the action'));d.success('green',190)
        self.assertFalse(d.glance)
        # When the overdue team is itself at work, its visit is an ordinary one.
        d=race.Director();teams=self.teams();d.choose(teams,[],100);d.success('green',100);d.shown['yellow']=100
        self.assertEqual(d.choose(teams,[],190),('blue','Following the action'));d.success('blue',190)
        self.assertFalse(d.glance)

    def test_airtime_follows_action_while_every_team_is_seen(self):
        d=race.Director();teams=[row('green'),quiet('yellow'),quiet('blue')];cuts=[];on=[]
        for now in range(100,1001,5):
            pick=d.choose(teams,[],now)
            if pick:d.success(pick[0],now);cuts.append((now,pick[0]))
            on.append(d.current)
        self.assertGreaterEqual(on.count('green')/len(on),.6)
        for team in ('yellow','blue'):
            seen=[100]+[n for n,t in cuts if t==team]+[1000]
            self.assertLessEqual(max(b-a for a,b in zip(seen,seen[1:])),130,team)   # 90 s target + dwell and poll slack
            visits=[n for n,t in cuts if t==team];self.assertGreaterEqual(len(visits),5)
        stays=[b-a for (a,t),(b,_) in zip(cuts,cuts[1:]) if t!='green']
        self.assertTrue(stays and max(stays)<=20,stays)                               # quiet visits are glances

    def test_rotates_when_nobody_is_working(self):
        d=race.Director();teams=[quiet('green'),quiet('yellow'),quiet('blue')];cuts=[]
        for now in range(100,401,5):
            pick=d.choose(teams,[],now)
            if pick:d.success(pick[0],now);cuts.append(pick)
        self.assertEqual({t for t,_ in cuts},{'green','yellow','blue'})
        self.assertEqual({why for _,why in cuts},{'Around the teams'})
        self.assertGreaterEqual(len(cuts),8)

    def test_turns_to_the_teammate_who_is_working(self):
        sub=lambda agent,score:{'agent':agent,'surface':'nauvis','x':0,'y':0,'verb':'build','score':score,'idle':0}
        d=race.Director();teams=[row('green')];d.success('green',100,'gemini')
        self.assertIsNone(d.choose(teams,[],130,{'green':[sub('gemini',9),sub('gemini2',12)]}))    # the one on air is still at it
        self.assertEqual(d.choose(teams,[],130,{'green':[sub('gemini',.4),sub('gemini2',9)]}),('green','Following the action'))
        self.assertIsNone(d.choose(teams,[],130,{'green':[sub('gemini',.4),sub('gemini2',2)]}))    # nobody is acting: hold the shot
        d.success('green',130,None)                                                                # a base shot gives way to an agent at work
        self.assertEqual(d.choose(teams,[],150,{'green':[sub('gemini2',9)]}),('green','Following the action'))
        self.assertEqual(race.Director.best([sub('a',1),sub('b',7),sub('c',3)])['agent'],'b');self.assertIsNone(race.Director.best([]))

    def test_scout_outranks_the_coarse_public_activity(self):
        # Both rows say "acting", but the scout knows green's agent has stood idle and yellow's is building.
        sub=lambda score:[{'agent':'gemini','surface':'nauvis','x':0,'y':0,'verb':None,'score':score,'idle':0}]
        d=race.Director();teams=[row('green'),row('yellow'),row('blue')];d.success('blue',100)
        self.assertEqual(d.choose(teams,[],130,{'green':sub(.2),'yellow':sub(11),'blue':sub(6)})[0],'yellow')

    def test_subjects_score_action_over_standing(self):
        state={'agents':[
            {'name':'a','activity':'acting','active':'build:lab','position':{'x':1,'y':2},'surface':'nauvis','interest':6,'idle_s':0,'did':{'t':95}},
            {'name':'b','activity':'idle','active':False,'position':{'x':3,'y':4},'surface':'nauvis','interest':8,'idle_s':200},
            {'name':'c','activity':'thinking','position':{'x':5,'y':6},'surface':'nauvis','interest':7,'idle_s':5},
            {'name':'w','activity':'acting','active':'move_to','position':{'x':5,'y':6},'surface':'nauvis'},
            {'name':'f','activity':'thinking','combat':True,'position':{'x':5,'y':6},'surface':'nauvis'},
            {'name':'r','activity':'resting','position':{'x':5,'y':6},'surface':'nauvis','interest':30},
            {'name':'x','activity':'acting','active':'build','position':{'x':0,'y':0},'surface':'nauvis'},      # not on the roster
            {'name':'d','activity':'acting','active':'move_to','position':{'x':'bad'},'surface':'nauvis'},     # no position
            {'name':'e','activity':'acting','alive':False,'position':{'x':0,'y':0},'surface':'nauvis'},        # dead
            {'name':'s','activity':'acting','position':{'x':0,'y':0},'surface':'../etc'}]}                     # not a surface name
        subs={s['agent']:s for s in race.subjects(state,{'a','b','c','w','f','r','d','e','s'},100)}
        self.assertEqual(set(subs),{'a','b','c','w','f','r'})
        self.assertGreater(subs['a']['score'],12);self.assertEqual(subs['a']['verb'],'build')
        self.assertGreaterEqual(subs['f']['score'],race.ACTION);self.assertEqual(subs['f']['verb'],'fight')
        self.assertGreaterEqual(subs['w']['score'],race.ACTION);self.assertEqual(subs['w']['verb'],'walk')
        self.assertTrue(race.WARM<=subs['c']['score']<race.ACTION)      # between actions, recently busy
        self.assertLess(subs['b']['score'],race.WARM)                    # standing: its old interest barely counts
        self.assertLess(subs['r']['score'],race.ACTION)
        self.assertEqual(set(subs['a']),{'agent','surface','x','y','verb','score','idle'})

    def test_camera_targets_active_agent_then_core(self):
        st={'agents':[{'activity':'acting','surface':'nauvis','position':{'x':42,'y':24}}],
            'basemap':{'x0':0,'y0':0,'w':10,'h':10,'cell':2}}
        self.assertEqual(overlay.target(st),('nauvis',42,24))
        st['agents'][0]['activity']='thinking';self.assertEqual(overlay.target(st),('nauvis',10,10))

    def test_fixture_actually_changes(self):
        frames=synthetic()
        self.assertNotEqual(frames[0]['teams'][0]['research']['progress'],frames[-1]['teams'][0]['research']['progress'])
        leaders=[tuple(t['team'] for t in f['teams'] if t['leader']) for f in frames]
        self.assertEqual(leaders[0],('green',));self.assertEqual(leaders[-1],('yellow',))
        self.assertGreater(len({f['camera']['team'] for f in frames}),1)


class ShotTest(unittest.TestCase):
    """What the camera is told: follow the agent at work, else the base, never an uncharted frame."""
    class Harness:
        team='green'
        def __init__(self,charted=lambda lua:True):self.charted,self.calls=charted,[]
        def lua(self,lua):
            if 'get_player' in lua:return {'index':7}
            ok=self.charted(lua);return {'center':ok,'charted':4 if ok else 0,'chunks':4}
        def camera(self,body):self.calls.append(body);return {'ok':True}

    STATE={'agents':[],'basemap':{'core':{'x0':100,'y0':200,'w':20,'h':10,'cell':2}}}
    SUBJECT={'agent':'gemini2','surface':'nauvis','x':40.0,'y':-12.0,'verb':'build','score':9.0,'idle':0}

    def test_follows_the_agent_at_work(self):
        h=self.Harness();out=overlay.cut(h,self.STATE,self.SUBJECT)
        self.assertEqual(h.calls,[{'player':7,'zoom':1.4,'smooth':False,'follow':'gemini2'}])
        self.assertEqual((out['kind'],out['agent'],out['team']),('follow','gemini2','green'))
        walking=dict(self.SUBJECT,verb='walk');h=self.Harness();overlay.cut(h,self.STATE,walking,smooth=True)
        self.assertEqual(h.calls[0],{'player':7,'zoom':.8,'smooth':True,'follow':'gemini2'})

    def test_standing_agents_give_way_to_the_base(self):
        idle=dict(self.SUBJECT,score=.4,verb=None);h=self.Harness();out=overlay.cut(h,self.STATE,idle)
        self.assertEqual(h.calls,[{'player':7,'zoom':.6,'smooth':False,'surface':'nauvis','position':{'x':120,'y':210}}])
        self.assertEqual((out['kind'],out['agent']),('base',None))
        # No base map yet: the least idle agent is still better than nothing.
        h=self.Harness();out=overlay.cut(h,{'agents':[]},idle)
        self.assertEqual(h.calls[0]['follow'],'gemini2');self.assertEqual(out['kind'],'follow')
        with self.assertRaises(ValueError):overlay.cut(self.Harness(),{'agents':[]})

    def test_uncharted_follow_tightens_then_falls_back_to_the_base(self):
        # Only the base's own frame is charted: every zoom around the agent is refused, the base is shown.
        h=self.Harness(lambda lua:'120.0' in lua);out=overlay.cut(h,self.STATE,self.SUBJECT)
        self.assertEqual(out['kind'],'base');self.assertNotIn('follow',h.calls[0])
        # Charted only close around the agent: the follow shot tightens instead.
        seen=[];h=self.Harness(lambda lua:seen.append(lua) or len(seen)>=2);out=overlay.cut(h,self.STATE,self.SUBJECT)
        self.assertEqual((out['kind'],out['zoom']),('follow',1.5))
        with self.assertRaises(ValueError):overlay.cut(self.Harness(lambda lua:False),self.STATE,self.SUBJECT)
        with self.assertRaises(ValueError):overlay.cut(self.Harness(),self.STATE,dict(self.SUBJECT,x=math.inf))

    def test_obs_camera_item_and_page_share_one_rectangle(self):
        class OBS:
            def __init__(self):self.transforms={}
            def call(self,name,body=None):
                body=body or {}
                if name=='GetStreamStatus' or name=='GetRecordStatus':return {'outputActive':name=='GetRecordStatus'}
                if name=='GetCurrentProgramScene':return {'currentProgramSceneName':'stream'}
                if name=='GetSceneList':return {'scenes':[]}
                if name=='GetInputList':return {'inputs':[]}
                if name=='GetSceneItemId':return {'sceneItemId':body['sourceName']}
                if name=='SetSceneItemTransform':self.transforms[body['sceneItemId']]=body['sceneItemTransform']
                return {}
        obs=OBS();stream.setup_obs(obs,'http://127.0.0.1:8790/',{})
        t=obs.transforms['mt camera']
        self.assertEqual((t['positionX'],t['positionY'],t['boundsWidth'],t['boundsHeight']),overlay.CAMERA_RECT)
        x,y,w,h=overlay.CAMERA_RECT
        self.assertEqual(w*9,h*16);self.assertTrue(0<x and x+w<1920 and 0<y and y+h<1080)
        self.assertEqual(obs.transforms['mt overlay']['boundsWidth'],1920)


class ReplayTest(unittest.TestCase):
    def test_synthetic_four_by_three_goes_through_the_production_projection(self):
        frames=synthetic(4,3,40);last=frames[-1]
        self.assertEqual([len(t['agents']) for t in last['teams']],[3,3,3,3])
        self.assertEqual({t['team'] for t in last['teams']},{'green','yellow','blue','red'})
        self.assertIn('diplomacy',{m['kind'] for m in last['feed']});self.assertIn('tell',{m['kind'] for m in last['feed']})
        self.assertTrue(any(v['source']=='youtube' for f in frames for v in f['viewers']))
        self.assertTrue(any(f['viewer_delivery'].get('104',{}).get('teams')==['green','yellow','blue','red'] for f in frames))
        self.assertTrue(any(t['pacts'] for t in last['teams']))
        names={a['display_name'] for t in last['teams'] for a in t['agents']}
        self.assertTrue({'Vesper','Grok the Unyielding','Muse3','Terra'}<=names)
        self.assertTrue(all(f['camera'] and f['layout']=={'camera':list(overlay.CAMERA_RECT)} for f in frames))
        self.assertIn('follow',{f['camera']['kind'] for f in frames})
        json.dumps(frames,allow_nan=False)

    def test_recorded_run_is_rebuilt_from_its_own_logs(self):
        at=lambda s:time.strftime('%Y-%m-%dT%H:%M:%S',time.gmtime(1794380000+s))+'.000Z'
        def calls(rows):
            out=[]
            for n,(start,action,args,ok,result,tick) in enumerate(rows):
                out.append({'at':at(start),'event':'request','request':{'id':str(n),'action':action,'bot':'x','args':args}})
                out.append({'at':at(start+.5),'event':'response','response':{'id':str(n),'ok':ok,'tick':tick,'result':result}})
            return out
        with tempfile.TemporaryDirectory() as d:
            op=Path(d)/'ops/runs/r1/op';tree=Path(d)/'tree'
            (op/'green').mkdir(parents=True);(op/'yellow').mkdir()
            (op/'launch-tree').write_text(str(tree))
            (op/'teams.tsv').write_text('# team\tname\tkind\troute\tmodel\teffort\tlabel\tharness\n'
                                        'green\tgemini\tagy\tagy\tm\t-\tGemini 3.8 Flash\tAntigravity\n'
                                        'yellow\tgrok\tgrok\tgrok\tm\tlow\tGrok 4.7\tGrok Build\n'
                                        'red\tastra\tcodex\tcodex\tm\tlow\tGPT-6 Astra\tCodex\n')      # not launched: no op folder
            (op/'green/chat.jsonl').write_text(json.dumps({'seq':3,'tick':6600,'from':'gemini','text':'Lab is ready'})+'\n'+
                                               json.dumps({'seq':4,'tick':6700,'from':'viewer A','text':'hello','viewer':True})+'\n')
            (op/'green/scores.jsonl').write_text(json.dumps({'score':{'tick':6000,'research_done':['automation'],'current_research':'logistics','entities':{'lab':1},'rockets':0}})+'\n')
            (op/'views.json').write_text(json.dumps({'pacts':[{'id':2,'a':'yellow','b':'green','status':'ended','proposed_tick':6300,'accepted_tick':9000,'ended_tick':99999,'note':'PRIVATE'}],
                                                     'contacts':[{'kind':'chart','team':'green','other':'yellow','tick':6100}]}))
            for team,name,rows in (('green','gemini',[(0,'status',{},True,{'logistics_here':'none where you stand (10.5,-4.0)'},6000),
                                                     (20,'build',{'item':'lab','position':{'x':12,'y':-4}},True,{},7200),
                                                     (40,'tell',{'to':'gemini','text':'A long private tell','summary':'Short summary'},True,{'seq':5,'to':['gemini']},8400),
                                                     (60,'sleep',{'seconds':30},True,{'sleeping_s':30},9600),
                                                     (120,'observe',{},True,{},13200)]),
                                  ('yellow','grok',[(1,'profile',{'display_name':'Sprocket'},True,{'display_name':'Sprocket','color':'#ff8a3c','glyph':'⚙','motto':'Red science'},6060),
                                                    (30,'mine',{'position':{'x':70,'y':7}},True,{'until_tick':8400},7800),
                                                    (119,'observe',{},True,{},13140)])):
                folder=tree/'runs/r1'/team/name;folder.mkdir(parents=True)
                with gzip.open(folder/'journal.jsonl.gz','wt') as f:
                    for r in calls(rows):f.write(json.dumps(r)+'\n')
            frames=replay.recorded(op,label='Replay · test')
        self.assertEqual({t['team'] for t in frames[0]['teams']},{'green','yellow'})
        state=lambda f,team,name:next(a for t in f['teams'] if t['team']==team for a in t['agents'] if a['name']==name)
        index=lambda seconds:int((seconds-20.5)/5)          # frames start 20 s after the first reply, every 5 s
        self.assertEqual(state(frames[index(22)],'green','gemini')['action'],'Building lab')
        self.assertEqual(state(frames[index(22)],'green','gemini')['position'],{'x':12.0,'y':-4.0})
        self.assertEqual(state(frames[index(70)],'green','gemini')['activity'],'resting')
        self.assertEqual(state(frames[index(115)],'green','gemini')['activity'],'idle')
        self.assertEqual(state(frames[index(34)],'yellow','grok')['action'],'Mining')
        sprocket=state(frames[-1],'yellow','grok')
        self.assertEqual((sprocket['display_name'],sprocket['color'],sprocket['glyph'],sprocket['persona']),('Sprocket','#ff8a3c','⚙','Red science'))
        self.assertEqual({(m['kind'],m['text']) for m in frames[-1]['feed']},{('talk','Lab is ready'),('tell','Short summary')})
        self.assertEqual({e['text'] for e in frames[-1]['events']},{'First contact with Yellow','Pact #2 proposed to Green','Pact #2 signed with Green'})
        self.assertEqual(frames[-1]['fixture'],'Replay · test');self.assertNotIn('PRIVATE',json.dumps(frames))
        self.assertEqual(frames[index(22)]['camera']['agent'],'gemini');self.assertEqual(frames[index(22)]['camera']['kind'],'follow')
        shifted=replay.rebase(frames[-1],5000.0)
        self.assertEqual(shifted['now'],5000.0);self.assertAlmostEqual(shifted['feed'][0]['at']-frames[-1]['feed'][0]['at'],5000.0-frames[-1]['now'])


if __name__=='__main__':unittest.main()
