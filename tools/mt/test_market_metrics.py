#!/usr/bin/env python3
"""Checks evidence interpretation: supplied stock, consumption, clocks and sampling gaps."""
import copy
import subprocess
import tempfile
import unittest
from pathlib import Path
from market_fixture import instructions, PREPARE, ACTIVATE, FINISH, TARGETS, lua_string
from market_metrics import summarize, BASELINE, SNAPSHOT
import json

class Metrics(unittest.TestCase):
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
                ACTIVATE.replace('MARKET','true').replace('BASELINE',BASELINE),FINISH,SNAPSHOT]
        with tempfile.TemporaryDirectory() as d:
            for i,chunk in enumerate(chunks):
                path=Path(d)/f'{i}.lua';path.write_text(chunk)
                subprocess.run(['luac','-p',str(path)],check=True)

if __name__=='__main__':unittest.main()
