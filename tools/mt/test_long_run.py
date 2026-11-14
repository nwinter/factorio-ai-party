import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
import autosave

class Saves(unittest.TestCase):
    def test_retention_keeps_hourly_and_recent_after_rollback(self):
        rows=[dict(file=str(i),tick=i*54000,copied_at=i) for i in range(24)]
        rows.append(dict(file='rollback',tick=1,copied_at=30))
        keep=autosave.retain(rows,3)
        self.assertEqual(keep,{'0','4','8','12','16','20','22','23','rollback'})
    def test_verify_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(autosave,'ARCHIVE',Path(temp)):
            root=Path(temp)/'trial'/'saves';root.mkdir(parents=True)
            path=root/'one.zip';path.write_bytes(b'good')
            (root/'index.json').write_text(json.dumps({'copies':[dict(file='one.zip',sha256=autosave.sha(path))]}))
            self.assertEqual(autosave.verified('trial','one.zip')[0],path)
            path.write_bytes(b'bad')
            with self.assertRaises(RuntimeError):autosave.verified('trial','one.zip')
            with self.assertRaises(ValueError):autosave.verified('trial','../one.zip')

import full_run
import public_session
import launch

class Shifts(unittest.TestCase):
    def test_scoped_nudge_ignores_foreign_rows(self):
        a=dict(name='a',team='green',started=0,folder='unused',tree='unused')
        state={'agents':{'a':a,'b':dict(a,name='b',team='blue')}}
        reader=unittest.mock.Mock()
        reader.op.return_value={'agents':[dict(name='a',standing_s=9999,lanes=[]),dict(name='b',standing_s=9999,lanes=[])]}
        with patch.object(full_run,'Reader',return_value=reader),patch.object(full_run,'event'):
            full_run.nudge(Path('/unused'),state,10000)
        tells=[c for c in reader.op.call_args_list if c.args[0]=='tell']
        self.assertEqual(len(tells),2)
        for call in tells:self.assertEqual(call.kwargs['team'],state['agents'][call.args[1]['to']]['team'])
        self.assertNotIn('other team',full_run.NUDGE)

    def test_shift_preserves_unselected_and_has_no_world_teardown(self):
        with tempfile.TemporaryDirectory() as temp:
            op=Path(temp);a=dict(name='a',team='green',shift=1,restarts=0,pane='old',folder=str(op/'g'))
            b=dict(a,name='b',team='blue',folder=str(op/'b'))
            state=dict(serial=0,agents={'a':a,'b':b});calls=[]
            with patch.object(full_run,'stop_client',side_effect=lambda a:calls.append(('stop',a['name']))), \
                 patch.object(full_run,'snapshot',return_value=op/'history'), \
                 patch.object(full_run,'start_client',side_effect=lambda op,a,c:calls.append(('start',a['name'],str(c)))), \
                 patch.object(full_run,'say'),patch.object(full_run,'indexes'),patch.object(full_run,'event'),patch.object(full_run,'set_deadline'):
                full_run.change(op,state,['a'],90)
            self.assertEqual([r[:2] for r in calls],[('stop','a'),('start','a')])
            self.assertEqual(b['pane'],'old');self.assertEqual(b['shift'],1)
            self.assertEqual(a['shift'],2)
            self.assertFalse(a['changing'])

    def test_unknown_quota_never_creates_fabricated_reset(self):
        now=10000
        with tempfile.TemporaryDirectory() as temp:
            team=Path(temp)/'team.tsv';team.write_text('a\tagy\tagy\tgemini-3.8-flash-high\n')
            profile=dict(command='agy',available=True,windows=[dict(label='Gemini · Weekly',percent=100,resets_at=20000)])
            hits,rooms=full_run.quota(dict(generated_at=now-901,profiles=[profile]),team,now)
            self.assertEqual((hits,rooms),({},{}))
            hits,rooms=full_run.quota(dict(generated_at=now,profiles=[profile]),team,now)
            self.assertEqual(hits['a']['reset'],20000)
            profile['stale']=True
            self.assertEqual(full_run.quota(dict(generated_at=now,profiles=[profile]),team,now),({},{}))

    def test_public_default_rejects_public_without_operator_flag(self):
        api=unittest.mock.Mock();api.call.return_value={'items':[dict(status=dict(privacyStatus='public'),contentDetails=dict(boundStreamId='s'))]}
        receipt=dict(id='v',stream_id='s')
        with self.assertRaises(AssertionError):public_session.broadcast(api,receipt)
        receipt['session_privacy']='public'
        self.assertEqual(public_session.broadcast(api,receipt)['status']['privacyStatus'],'public')

    def test_launch_bounds(self):
        with patch.object(sys,'argv',['launch','test','91']),self.assertRaises(AssertionError):launch.main()
        with patch.object(sys,'argv',['public_session','start','test','--minutes','91']),self.assertRaises(AssertionError):public_session.main()
        with patch.object(sys,'argv',['public_session','start','test','--minutes','91','--run-mode','full']),patch('builtins.print') as output:
            public_session.main()
            self.assertIn('until explicit stop',output.call_args.args[0])

if __name__=='__main__':unittest.main()
