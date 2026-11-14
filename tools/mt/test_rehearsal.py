"""Offline acceptance of rehearsal planning and measurement boundaries."""
import math
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parent))
import mt_map
import rehearse
import stop_helpers


class Planning(unittest.TestCase):
    def test_metrics_cleanup_checks_exact_run(self):
        self.assertTrue(stop_helpers.owned(['python3','tools/mt/rehearsal_metrics.py','r307'],'r307',[]))
        self.assertFalse(stop_helpers.owned(['python3','tools/mt/rehearsal_metrics.py','r307a'],'r307',[]))

    def test_roster_names_keep_symmetric_resources_and_all_planets(self):
        names=['green','yellow','blue']
        layout=mt_map.layout(3,1300,600,names)
        self.assertEqual([t['name'] for t in layout['teams']],names)
        spawns=[t['spawns']['nauvis'] for t in layout['teams']]
        distances=[math.dist(a,b) for i,a in enumerate(spawns) for b in spawns[i+1:]]
        self.assertLess(max(distances)-min(distances),2)
        for t in layout['teams']:
            own=[p for p in layout['patches'] if p['site']=='start '+t['name']]
            self.assertEqual({p['name']:p['amount'] for p in own},{p['name']:p['amount'] for p in mt_map.PRIMARY})
            self.assertEqual(set(t['spawns']),{'nauvis',*mt_map.PLANETS})
        self.assertEqual({s['name'] for s in layout['sites'] if s['kind']=='second'},
                         {'second green-yellow','second yellow-blue','second blue-green'})
        for names in (['blue','blue','green'],['green','blue'],['green','blue','op']):
            with self.assertRaises(AssertionError):mt_map.layout(3,1300,600,names)

    def test_quota_never_treats_unknown_or_other_profile_as_room(self):
        b=dict(generated_at=1000,profiles=[dict(command='codex',windows=[dict(duration_minutes=10080,percent=99)]),
            dict(command='codex-b',observed_at=1000,windows=[dict(duration_minutes=10080,percent=71)])])
        with patch.object(rehearse.time,'time',return_value=1000),patch.object(rehearse,'read',return_value=b):
            self.assertEqual(rehearse.weekly_usage('codex-b'),71)
            self.assertIsNone(rehearse.weekly_usage('missing'))
            b['profiles'][1]['stale']=True
            self.assertIsNone(rehearse.weekly_usage('codex-b'))
            b['profiles'][1]['stale']=False;b['profiles'][1]['windows']=[]
            self.assertIsNone(rehearse.weekly_usage('codex-b'))
            b['generated_at']=2000
            self.assertIsNone(rehearse.weekly_usage('codex-b'))



if __name__=='__main__':unittest.main()
