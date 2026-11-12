#!/usr/bin/env python3
"""Checks evidence interpretation: supplied stock, consumption, clocks and sampling gaps."""
import copy
import subprocess
import tempfile
import unittest
from pathlib import Path
from market_fixture import instructions, require_claim, PREPARE, ACTIVATE, FINISH, RELEASE, TARGETS, lua_string
from market_metrics import summarize, response_in_window, minimum_fill_count, BASELINE, SNAPSHOT
import json

class Metrics(unittest.TestCase):
    def test_fixture_uses_the_selected_existing_server_claim(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'claim.txt'
            with self.assertRaises(AssertionError):require_claim('eng-mt290',path)
            path.write_text('eng-mt290 owns imac2 for the approved market public run')
            require_claim('eng-mt290',path)
            with self.assertRaises(AssertionError):require_claim('eng-mt296',path)
            with self.assertRaises(AssertionError):require_claim('unknown',path)

    def test_consumed_fill_bound_does_not_credit_every_small_delivery(self):
        self.assertEqual(minimum_fill_count([100]+[1]*20,100),1)
        self.assertEqual(minimum_fill_count([100]+[1]*20,119),20)
        self.assertEqual(minimum_fill_count([100]+[1]*20,120),21)
        self.assertEqual(minimum_fill_count([100],0),0)
        with self.assertRaises(ValueError):minimum_fill_count([100],101)

    def test_startup_at_the_same_paused_tick_is_not_a_trial_refusal(self):
        e={'event':'response','at':'1970-01-01T00:01:30Z','response':{'tick':100,'ok':False}}
        self.assertFalse(response_in_window(e,100,200,100,200))
        e['at']='1970-01-01T00:01:40Z';self.assertTrue(response_in_window(e,100,200,100,200))
        e['response']['tick']=201;self.assertFalse(response_in_window(e,100,200,100,200))
        e['response']['tick']=150;e['at']='1970-01-01T00:03:21Z';self.assertFalse(response_in_window(e,100,200,100,200))

    def test_consumption_is_not_automatically_a_relief_claim(self):
        baseline={'teams':{'green':{'made':{'iron-plate':20},'used':{'iron-plate':5},'stock':{'iron-plate':100}}}}
        s={'tick':100,'started_tick':100,'market':True,'baseline':baseline,'contact':{'chart green>yellow':102},
           'teams':{'green':{'made':{'iron-plate':20},'used':{'iron-plate':5},'poor_ore':100}},
           'agents':{'a':{'team':'green','kind':False}},'transactions':[],'messages':[]}
        arrival=copy.deepcopy(s);arrival['tick']=6100
        arrival['transactions']=[{'pair':'green>yellow','id':1,'tick':700,'eta':6100,'status':'delivered','item':'iron-plate','count':50,
            'price':20,'legs':[{'to':'green','item':'iron-plate','count':50,'delivered':50}]}]
        end=copy.deepcopy(arrival);end['tick']=6700;end['teams']['green']['used']['iron-plate']=35
        out=summarize([s,arrival,end]);self.assertEqual(out['decision_latency_seconds'],(700-102)/60)
        self.assertEqual(out['fills_followed_by_consumption'],1)
        self.assertEqual(out['teams']['green']['imported_consumption_lower_bound']['iron-plate'],0)
        self.assertEqual(out['unmeasured_gap_seconds'],100)
        self.assertEqual(out['idle']['a']['idle_share'],1)
        end['teams']['green']['used']['iron-plate']=130
        out=summarize([s,arrival,end]);self.assertEqual(out['teams']['green']['imported_consumption_lower_bound']['iron-plate'],25)
        end['teams']['green']['made']['iron-plate']=50
        out=summarize([s,arrival,end]);self.assertEqual(out['teams']['green']['imported_consumption_lower_bound']['iron-plate'],0)

    def test_fixture_briefs_fit_real_limit(self):
        row={'stock_position':{'x':4004.5,'y':2000.5},'kit':{'x':4012.5,'y':2000.5},'rich':'copper-ore','poor':'iron-ore',
             'production':[{'recipe':'automation-science-pack','input':{'x':4001.5,'y':2028.5},'output':{'x':4007.5,'y':2028.5}}]*7}
        for enabled in (True,False):self.assertLessEqual(len(instructions(row,enabled).encode()),2000)

    def test_embedded_lua_compiles(self):
        chunks=[PREPARE.replace('TARGETS',lua_string(json.dumps(TARGETS))),
                ACTIVATE.replace('MARKET','true').replace('BASELINE',BASELINE),FINISH.replace('RELEASE',RELEASE),SNAPSHOT]
        with tempfile.TemporaryDirectory() as d:
            for i,chunk in enumerate(chunks):
                path=Path(d)/f'{i}.lua';path.write_text(chunk)
                subprocess.run(['luac','-p',str(path)],check=True)

if __name__=='__main__':unittest.main()
