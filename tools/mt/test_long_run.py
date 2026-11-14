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
    def test_restore_copy_lock_is_quiet_but_real_copy_failure_alerts(self):
        with tempfile.TemporaryDirectory() as temp:
            stop=unittest.mock.Mock();stop.is_set.side_effect=[False,False,True]
            with patch.object(sys,'argv',['autosave','watch','trial']),patch.object(autosave,'op_dir',return_value=Path(temp)), \
                 patch('threading.Event',return_value=stop),patch.object(autosave.signal,'signal'), \
                 patch.object(autosave,'copy_new',side_effect=[BlockingIOError(35,'busy'),RuntimeError('copy failed')]), \
                 patch.object(autosave,'alert') as alert,patch('builtins.print'):
                autosave.main()
            self.assertEqual(alert.call_count,1)
            self.assertEqual(str(alert.call_args.args[2]),'copy failed')
            self.assertEqual(stop.wait.call_count,2)

    def test_queued_save_that_never_replaces_old_slot_alerts(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);dest=root/'trial'/'saves';dest.mkdir(parents=True);op=root/'op';op.mkdir()
            name='trial-auto-01';stamp=[5,10]
            run_state.write(dest/'index.json',dict(copies=[dict(file='old.zip',tick=100,copied_at=1)],seen={name:json.dumps([1,100,stamp])}))
            clock=dict(prefix='trial',enabled=True,records={'1':dict(name=name,sequence=2,tick=200)})
            with patch.object(autosave,'ARCHIVE',root),patch.object(autosave,'op_dir',return_value=op),patch.object(autosave,'pinned'), \
                 patch.object(Path,'is_mount',return_value=True),patch.object(autosave,'rcon',return_value=json.dumps(clock)), \
                 patch.object(autosave,'stat',return_value=stamp),patch.object(autosave.time,'time',return_value=1000):
                index=autosave.copy_new('trial');self.assertEqual(len(index['copies']),1)
                with patch.object(autosave.time,'time',return_value=1121),self.assertRaisesRegex(RuntimeError,'not replaced'):
                    autosave.copy_new('trial')

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
import stop_helpers
import team_views
import quota_refresh
import rehearsal_metrics

class Shifts(unittest.TestCase):
    def test_unknown_quota_does_not_rest_or_stop_a_playing_agent(self):
        with tempfile.TemporaryDirectory() as temp:
            op=Path(temp);team=op/'team.tsv';team.write_text('a\tgrok\tgrok\tgrok-4.7\n')
            brief=dict(generated_at=1000,profiles=[dict(command='grok',available=False,stale=True,
                windows=[dict(label='Grok · Weekly',percent=100,resets_at=2000)])])
            hits,rooms=full_run.quota(brief,team,1000);self.assertEqual((hits,rooms),({},{}))
            a=dict(name='a',folder=temp,kind='grok',pane='p',started=100,restarts=0)
            panes=unittest.mock.Mock();panes.status.return_value='working';panes.read.return_value='Working [stop]'
            with patch.object(full_run,'live_client',return_value=True),patch.object(full_run,'stop_client') as stop, \
                 patch.object(full_run,'change') as change,patch.object(full_run.quota_rest,'mark') as rest:
                full_run.watch_agent(op,dict(agents={'a':a}),a,1000,panes,hits,rooms)
            stop.assert_not_called();change.assert_not_called();rest.assert_not_called()
            self.assertFalse(a.get('held'));self.assertNotIn('rest_until',a)

    def test_quota_cache_age_overrides_saved_availability_without_zeroing_windows(self):
        brief=dict(generated_at=1000,profiles=[dict(command='grok',observed_at=1000,available=True,stale=False,windows=[dict(percent=29)])])
        self.assertEqual(quota_refresh.unavailable(brief,{'grok'},1900),[])
        self.assertEqual(quota_refresh.unavailable(brief,{'grok'},1901),['grok'])
        with patch.object(rehearsal_metrics,'read',return_value=brief),patch.object(rehearsal_metrics.time,'time',return_value=1901):
            sample=rehearsal_metrics.quota_snapshot()
        self.assertTrue(sample['stale']);self.assertFalse(sample['profiles'][0]['available'])
        self.assertEqual(sample['profiles'][0]['windows'],[dict(percent=29)])

    def test_quota_cache_is_primary_and_fallback_cooldown_survives_restart(self):
        with tempfile.TemporaryDirectory() as temp:
            op=Path(temp);cache=op/'cache.json'
            run_state.write(op/'full-run.json',dict(phase='running',agents={'a':dict(kind='grok',route='grok')}))
            fresh=dict(generated_at=1000,profiles=[dict(command='grok',observed_at=1000,available=True,stale=False)])
            for brief,cooldown in [(fresh,False),(dict(fresh,generated_at=0),True)]:
                run_state.write(cache,brief)
                if cooldown:run_state.write(op/'quota-fallback.json',dict(at=950,phase='failed'))
                stop=unittest.mock.Mock();stop.is_set.side_effect=[False,True]
                with patch.object(sys,'argv',['quota_refresh','trial']),patch.object(quota_refresh,'op_dir',return_value=op), \
                     patch.object(quota_refresh,'CACHE',cache),patch.object(quota_refresh,'pinned'), \
                     patch.object(quota_refresh.threading,'Event',return_value=stop),patch.object(quota_refresh.signal,'signal'), \
                     patch.object(quota_refresh.time,'time',return_value=1100),patch.object(quota_refresh.subprocess,'run') as run,patch.object(quota_refresh,'alert'):
                    quota_refresh.main()
                run.assert_not_called()
                self.assertEqual(run_state.read(op/'quota-health.json')['stale'],cooldown)

    def test_custom_quota_reader_preserves_unknown_profiles(self):
        with tempfile.TemporaryDirectory() as temp:
            op=Path(temp);cache=op/'cache.json';run_state.write(cache,dict(generated_at=0))
            run_state.write(op/'full-run.json',dict(phase='running',agents={'a':dict(kind='grok',route='grok')}))
            brief=dict(generated_at=1000,profiles=[dict(command='grok',available=False,stale=True,windows=[])])
            stop=unittest.mock.Mock();stop.is_set.side_effect=[False,True]
            result=unittest.mock.Mock(returncode=0,stdout=json.dumps(brief))
            with patch.object(sys,'argv',['quota_refresh','trial','--reader','ruby','reader.rb']), \
                 patch.object(quota_refresh,'op_dir',return_value=op),patch.object(quota_refresh,'CACHE',cache), \
                 patch.object(quota_refresh,'pinned'),patch.object(quota_refresh.threading,'Event',return_value=stop), \
                 patch.object(quota_refresh.signal,'signal'),patch.object(quota_refresh.time,'time',return_value=1000), \
                 patch.object(quota_refresh.subprocess,'run',return_value=result) as run,patch.object(quota_refresh,'alert') as alert:
                quota_refresh.main()
            self.assertEqual(run.call_args.args[0],['ruby','reader.rb'])
            self.assertIn("['grok']",run_state.read(op/'quota-health.json')['error'])
            alert.assert_called_once()

    def test_unknown_grok_completion_recovers_without_restarting(self):
        with tempfile.TemporaryDirectory() as temp:
            op=Path(temp);a=dict(name='a',folder=temp,kind='grok',pane='p',started=100,restarts=0)
            path=op/'a/.grok-home/sessions/own/updates.jsonl';path.parent.mkdir(parents=True)
            completion=dict(timestamp=200,method='_x.ai/session/update',params=dict(update=dict(sessionUpdate='turn_completed',stop_reason='end_turn')))
            path.write_text(json.dumps(completion)+'\n')
            panes=unittest.mock.Mock();panes.read.return_value='│ ❯                     │\nShift+Tab:mode'
            panes.status.return_value='unknown';panes.prompt.return_value=('pane send-text',True,'')
            with patch.object(full_run,'live_client',return_value=True),patch.object(full_run,'change') as change,patch.object(full_run,'alert') as alert:
                full_run.watch_agent(op,dict(agents={'a':a}),a,1000,panes,{}, {})
                panes.prompt.assert_called_once_with('p',full_run.NUDGE)
                full_run.watch_agent(op,dict(agents={'a':a}),a,1020,panes,{}, {})
                self.assertEqual(panes.prompt.call_count,1);change.assert_not_called();alert.assert_not_called()
            self.assertTrue(run_state.read(op/'shifts.jsonl')['native_completion'])

    def test_native_idle_requires_completed_current_turn_and_empty_safe_prompt(self):
        with tempfile.TemporaryDirectory() as temp:
            a=dict(name='a',folder=temp,kind='grok',started=100)
            path=Path(temp)/'a/.grok-home/sessions/own/updates.jsonl';path.parent.mkdir(parents=True)
            complete=dict(timestamp=200,method='_x.ai/session/update',params=dict(update=dict(sessionUpdate='turn_completed',stop_reason='end_turn')))
            path.write_text(json.dumps(complete)+'\n')
            ready='│ ❯                │'
            self.assertTrue(full_run.native_idle(a,ready,1000))
            for screen in ('',ready+'\n[stop]',ready+'\nBuy more credits','│ ❯ queued input │'):
                self.assertFalse(full_run.native_idle(a,screen,1000))
            self.assertFalse(full_run.native_idle(a,ready,250))
            self.assertFalse(full_run.native_idle(dict(a,started=300),ready,1000))
            self.assertFalse(full_run.native_idle(dict(a,kind='muse'),ready,1000))
            with path.open('a') as f:f.write(json.dumps(dict(timestamp=300,method='session/update',params=dict(update=dict(sessionUpdate='agent_thought_chunk'))))+'\n')
            self.assertFalse(full_run.native_idle(a,ready,1000))
            complete['params']['update']['stop_reason']='rate_limit';path.write_text(json.dumps(complete)+'\n')
            self.assertFalse(full_run.native_idle(a,ready,1000))

    def test_partial_view_failure_reconnects_next_poll(self):
        with tempfile.TemporaryDirectory() as temp:
            op=Path(temp)/'runs/trial/op';op.mkdir(parents=True)
            readers=[unittest.mock.Mock(),unittest.mock.Mock()]
            views=[dict(t='failed',teams=[],errors={'bots':'Broken pipe'}),dict(t='recovered',teams=[],errors={})]
            with patch.object(sys,'argv',['team_views','trial','--every','5']),patch.object(team_views,'ROOT',temp), \
                 patch.object(team_views,'Reader',side_effect=readers) as factory,patch.object(team_views,'collect',side_effect=views), \
                 patch.object(team_views,'page',return_value='view'),patch.object(team_views.time,'sleep',side_effect=[None,StopIteration]):
                with self.assertRaises(StopIteration):team_views.main()
            self.assertEqual(factory.call_count,2)
            for reader in readers:reader.rcon.sock.close.assert_called_once()
            self.assertEqual(run_state.read(op/'views.json')['t'],'recovered')

    def test_helper_pid_reuse_does_not_stop_another_run(self):
        folders=[Path('/private/run/one')]
        self.assertTrue(stop_helpers.owned(['python3','tools/mt/full_run.py','watch','one'],'one',folders))
        self.assertTrue(stop_helpers.owned(['bash','tools/score-loop.sh','/private/run/one/op/green'],'one',folders))
        self.assertFalse(stop_helpers.owned(['python3','tools/mt/full_run.py','watch','two'],'one',folders))
        self.assertFalse(stop_helpers.owned(['vim','/private/run/one/notes.md'],'one',folders))
        self.assertFalse(stop_helpers.owned(['python3','tools/mt/full_run.py','watch','one-more'],'one',folders))

    def test_bounded_completion_releases_watch_lock_without_sleep(self):
        with tempfile.TemporaryDirectory() as temp:
            op=Path(temp);folder=op/'team';folder.mkdir()
            run_state.write(op/'full-run.json',dict(phase='running',max_shifts=1,agents={'a':dict(name='a',team='green',kind='grok',folder=str(folder),pane='p',deadline=0,shift=1)}))
            stop=unittest.mock.Mock();stop.is_set.side_effect=[False,True]
            with patch.object(full_run,'op_dir',return_value=op),patch.object(full_run,'pinned'),patch.object(full_run,'stop_client'), \
                 patch.object(full_run,'quota',return_value=({},{})),patch.object(full_run.pane_resume,'HerdrPanes'), \
                 patch.object(full_run.signal,'signal'),patch.object(full_run.threading,'Event',return_value=stop),patch.object(full_run,'alert') as alert:
                full_run.watch('test')
            alert.assert_not_called()
            stop.wait.assert_not_called()
            self.assertEqual(run_state.read(op/'full-run.json')['phase'],'shifts-complete')
            with run_state.lock(op/'full-watch.lock'):pass

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
