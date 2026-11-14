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
import restore
import run_state

class Shifts(unittest.TestCase):
    def test_quota_reset_after_deadline_starts_next_shift(self):
        a=dict(name='a',deadline=100,shift=1,held=True,hold_reason='quota')
        s=dict(max_shifts=0,agents={'a':a})
        self.assertEqual(full_run.due_agents(s,200,{}),[])
        self.assertEqual(full_run.due_agents(s,200,{'a':'fresh room'}),['a'])
        self.assertFalse(a['held']);self.assertNotIn('hold_reason',a)
        a.update(held=True,hold_reason='quota');s['max_shifts']=1
        self.assertEqual(full_run.due_agents(s,200,{}),['a'])

    def test_foreign_claim_refuses_before_rcon(self):
        with tempfile.TemporaryDirectory() as temp:
            claim=Path(temp,'claim');claim.write_text('another-owner imac2')
            with patch.object(run_state,'CLAIM',claim),patch.object(run_state,'command') as command, \
                 patch.dict('os.environ',{'POG_CLAIM_OWNER':'eng-mt300','MT_DIR':'/Users/owner/pog-mt21','MT_EXPECT_VERSION':'2.1.24'}):
                with self.assertRaises(RuntimeError):run_state.rcon('game.tick_paused=false')
                command.assert_not_called()

    def test_restore_proves_exact_state_before_camera_join_ticks(self):
        with tempfile.TemporaryDirectory() as temp:
            op=Path(temp);run_state.write(op/'full-env.json',{});run_state.write(op/'full-run.json',{'agents':{}})
            before=dict(tick=123,paused=True,forces={'a':1},profiles={'a':'identity'})
            calls=[]
            def rcon(lua):
                calls.append(('rcon',lua))
                if '"yes"' in lua:return 'yes'
                if 'connected=' in lua:return json.dumps(dict(tick=200,connected=True))
                return ''
            def command(args,**kw):calls.append(('command',[str(x) for x in args]));return 'camera joined'
            with patch.object(restore,'op_dir',return_value=op),patch.object(restore,'pinned'), \
                 patch.object(restore,'change'),patch.object(restore,'indexes'),patch.object(restore,'rcon',side_effect=rcon), \
                 patch.object(restore,'fingerprint',return_value=before),patch.object(restore,'checkpoint',return_value=(op/'save.zip',{})), \
                 patch.object(restore,'command',side_effect=command):
                result=restore.drill('test')
            self.assertTrue(all(result['exact'].values()));self.assertEqual(result['after']['tick'],123)
            self.assertEqual(result['camera']['tick'],200)
            commands=[c[1] for c in calls if c[0]=='command']
            self.assertEqual([c[-1] for c in commands],['stop','stop',str(op/'save.zip'),'start'])
            self.assertEqual(calls[-2],('rcon','game.tick_paused=true'))

    def test_resume_environment_keeps_engine_version(self):
        with tempfile.TemporaryDirectory() as temp,patch.dict('os.environ',{'POG_FACTORIO_VERSION':'2.1.24'}):
            full_run.capture_env(Path(temp))
            self.assertEqual(json.loads(Path(temp,'full-env.json').read_text())['POG_FACTORIO_VERSION'],'2.1.24')

    def test_dead_client_restarts_once_then_backs_off(self):
        with tempfile.TemporaryDirectory() as temp:
            a=dict(name='a',folder=temp,kind='grok',pane='p',started=0,restarts=0)
            panes=unittest.mock.Mock();panes.read.return_value='';panes.status.return_value='done'
            state=dict(agents={'a':a})
            with patch.object(full_run,'live_client',return_value=False),patch.object(full_run,'change') as change,patch.object(full_run,'alert'):
                full_run.watch_agent(Path(temp),state,a,10000,panes,{}, {})
                full_run.watch_agent(Path(temp),state,a,10020,panes,{}, {})
                self.assertEqual(change.call_count,1)
                self.assertEqual(a['restarts'],1)
                a['restarts']=4;a['next_retry']=0
                full_run.watch_agent(Path(temp),state,a,11000,panes,{}, {})
                self.assertTrue(a['held']);self.assertEqual(change.call_count,1)

    def test_unknown_limit_holds_without_restart_or_prompt(self):
        with tempfile.TemporaryDirectory() as temp:
            a=dict(name='a',folder=temp,kind='grok',pane='p',started=0,restarts=0)
            panes=unittest.mock.Mock();panes.read.return_value='Weekly limit reached'
            with patch.object(full_run,'live_client',return_value=True),patch.object(full_run,'change') as change, \
                 patch.object(full_run,'stop_client') as stop,patch.object(full_run,'alert'):
                full_run.watch_agent(Path(temp),dict(agents={'a':a}),a,10000,panes,{}, {})
                stop.assert_called_once();change.assert_not_called();panes.prompt.assert_not_called()
                self.assertEqual(a['hold_reason'],'quota');self.assertTrue(a['held'])

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
