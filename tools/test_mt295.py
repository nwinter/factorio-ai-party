import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools/mt'))
import identities
import game_test
from public_feed import identity,project_feed

class IdentityFeedTests(unittest.TestCase):
    def setUp(self):
        self.teams=[{'team':'green','agents':[{'name':'gemini','model':'Gemini Flash'},{'name':'gemini2','model':'Gemini Flash'}]},
                    {'team':'blue','agents':[{'name':'muse','model':'Muse Spark'},{'name':'muse2','model':'Muse Spark'}]}]
        self.line={'seq':2,'tick':100,'team':'green','agent':'gemini','kind':'tell','scope':'team-private',
                   'text':'Build the smelter while I mine.','to':['gemini2'],
                   'identity':{'display_name':'Forge','persona':'A patient builder.','color':'#3CB44B','glyph':'⚙'},
                   'internal':'PRIVATE'}

    def test_all_sources_order_and_scope(self):
        rows=[self.line,dict(self.line,seq=1,kind='say',to={}),dict(self.line,seq=3,kind='board',to=[]),
              dict(self.line,seq=4,kind='diplomacy',scope='diplomacy',to=['blue']),
              dict(self.line,seq=5,kind='identity',scope='public',to=[]),self.line]
        result=project_feed(rows,self.teams)
        self.assertEqual([r['seq'] for r in result],[1,2,3,4,5])
        self.assertEqual(result[1]['identity']['display_name'],'Forge')
        self.assertEqual(result[1]['identity']['color'],'#3cb44b')
        self.assertEqual(result[1]['model'],'Gemini Flash')
        self.assertNotIn('PRIVATE',json.dumps(result))

    def test_privacy_and_forged_scope(self):
        bad=[dict(self.line,to=['muse']),dict(self.line,scope='public'),dict(self.line,agent='muse'),
             dict(self.line,team='hidden'),dict(self.line,operator=True),dict(self.line,source='site'),
             dict(self.line,kind='confess'),dict(self.line,seq=True),dict(self.line,tick=-1),
             dict(self.line,kind='diplomacy',scope='diplomacy',to=['green'])]
        bad += [dict(self.line,text=t) for t in ['/Users/private/file','D:\\private\\file','tools/mt/start-mt.sh',
                'mt/batch290','multi-team','NickWinter','password=abc','https://private.invalid','a@private.invalid']]
        self.assertEqual(project_feed(bad,self.teams),[])

    def test_identity_allowlist(self):
        p={'display_name':'/Users/private','persona':'multi-team','motto':'Build carefully.','glyph':'⚙',
           'color':'red;url(x)','avatar':{'base':'robot','accent':'#AABBCC','source':'PRIVATE','visor':'bad'},'error':'PRIVATE'}
        self.assertEqual(identity(p,'Forge'),{'display_name':'Forge','motto':'Build carefully.','glyph':'⚙',
                                             'avatar':{'base':'robot','accent':'#aabbcc'}})
        self.assertEqual(identity({'pronouns':'she/her'},'Forge')['pronouns'],'she/her')

    def test_seeded_roster_and_resume(self):
        rows=identities.seeds(ROOT/'agent/mt/teams-test.tsv')
        self.assertEqual(len(rows),6)
        self.assertEqual(len({r['glyph'] for r in rows.values()}),6)
        self.assertEqual(len({r['color'] for r in rows.values()}),6)
        chosen={'display_name':'Forge','persona':'Builder','color':'#123456','glyph':'F'}
        self.assertEqual(identities.missing(chosen,rows['gemini']),{})
        self.assertEqual(identities.missing({'display_name':'Forge'},rows['gemini']),rows['gemini'])
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'roster.tsv';p.write_text('\n'.join(f't{i//3}\ta{i}' for i in range(12)))
            expanded=identities.seeds(p)
            self.assertEqual(len({r['glyph'] for r in expanded.values()}),12)
            self.assertEqual(len({r['color'] for r in expanded.values()}),12)

    def test_launch_registers_only_selected_models_before_profiles(self):
        requests=[]
        def encode(value):
            requests.append(json.loads(value));return '"request"'
        chosen={'display_name':'Vector','color':'#123456','glyph':'V'}
        client=mock.Mock()
        client.command.return_value=json.dumps({'ok':True,'result':chosen})
        args=['identities',str(ROOT/'agent/mt/teams-test.tsv'),'green','--execute']
        with mock.patch.object(sys,'argv',args),mock.patch.object(identities,'Harness',return_value=client),mock.patch.object(identities,'lua_string',side_effect=encode),mock.patch('builtins.print'):
            identities.main()
        self.assertEqual(requests[0]['action'],'mt_roster')
        self.assertTrue(requests[0]['operator'])
        self.assertEqual({r['name'] for r in requests[0]['args']['agents']},{'gemini','gemini2'})
        self.assertTrue(all(r['model']=='Gemini 3.8 Flash' for r in requests[0]['args']['agents']))
        self.assertEqual([r['action'] for r in requests[1:]],['profile','profile'])
        self.assertTrue(all(r['args']=={} for r in requests[1:]),'chosen profiles stay intact')
        client.reset_mock();client.command.return_value=json.dumps({'ok':False,'error':'no roster'})
        with mock.patch.object(sys,'argv',args),mock.patch.object(identities,'Harness',return_value=client),mock.patch.object(identities,'lua_string',side_effect=encode):
            with self.assertRaises(AssertionError):identities.main()
        self.assertEqual(client.command.call_count,1,'a failed trusted roster prevents profile seeding')

    def test_game_objectives_follow_real_contact_only(self):
        teams={'green':['gemini','gemini2'],'yellow':['grok','grok2'],'blue':['muse','muse2']}
        self.assertNotIn('blue',game_test.opening(teams['green']))
        self.assertNotIn('muse',game_test.opening(teams['green']))
        done=set()
        self.assertEqual(game_test.events([],teams,done),[])
        pair={'team':'green','other':'yellow','kind':'chart'}
        out=game_test.events([pair,dict(pair,team='yellow',other='green')],teams,done)
        self.assertEqual(len(out),1)
        self.assertEqual({t for t,_ in out[0][1]},{'green','yellow'})
        self.assertIn('diplomacy_send',out[0][1][0][1])
        self.assertEqual(game_test.events([pair],teams,done),[])
        self.assertEqual(game_test.events([dict(pair,kind='shot',damage=0)],teams,done),[])
        hit=game_test.events([dict(pair,kind='shot',damage=5)],teams,done)
        self.assertEqual(len(hit),1)
        self.assertTrue(hit[0][0].startswith('fight:'))
        self.assertEqual(game_test.events([dict(pair,other='hidden')],teams,done),[])
        selected=game_test.roster(ROOT/'agent/mt/teams-test.tsv','green,yellow')
        self.assertEqual(set(selected),{'green','yellow'})
        self.assertEqual(game_test.events([dict(pair,other='blue')],selected,set()),[])

if __name__=='__main__':unittest.main()
