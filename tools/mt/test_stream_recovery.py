import copy
import datetime
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import urlparse, parse_qs

from broadcast_rotation import LiveAPI, RequestRejected, Rotation
from public_session import broadcast, transition
from public_tours import Tours
from stream_memory import assess, GIB
from stream_recovery import Recovery, FrameProgress, recording_space_ok
from stream_feeds import owns, owned_pids
from viewer_inbox import BroadcastChat


class API:
    def __init__(self):
        self.rows={'old':{'id':'old','status':{'lifeCycleStatus':'live','privacyStatus':'unlisted'},
                          'contentDetails':{'boundStreamId':'stream'},'snippet':{}}}
        self.inserts=0
        self.lose_insert=False
        self.lose_bind=False
        self.reject_insert=False
    def call(self, method, url, body=None):
        q={k:v[0] for k,v in parse_qs(urlparse(url).query).items()}
        if '/liveStreams?' in url:
            return {'items':[{'status':{'streamStatus':'active'}}]}
        if method=='GET':
            return {'items':[copy.deepcopy(self.rows[q['id']])] if 'id' in q else list(copy.deepcopy(self.rows).values())}
        if '/bind?' in url:
            self.rows[q['id']]['contentDetails']['boundStreamId']=q['streamId']
            if self.lose_bind:
                self.lose_bind=False
                raise TimeoutError('lost bind reply')
        elif '/transition?' in url:
            self.rows[q['id']]['status']['lifeCycleStatus']=q['broadcastStatus']
        else:
            if self.reject_insert:
                self.reject_insert=False
                raise RequestRejected('YouTube HTTP 403')
            self.inserts+=1
            self.rows['new']={'id':'new','snippet':body['snippet'],
                'status':dict(body['status'],lifeCycleStatus='created'),'contentDetails':{}}
            if self.lose_insert:
                self.lose_insert=False
                raise TimeoutError('lost insert reply')
            return {'id':'new'}
        return {}


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.op=Path(self.tmp.name)
        self.patches=[patch('stream_recovery.alert'),patch('broadcast_rotation.alert')]
        for p in self.patches:p.start()
    def tearDown(self):
        for p in self.patches:p.stop()
        self.tmp.cleanup()
    def receipt(self):
        return dict(id='old',stream_id='stream',session_privacy='unlisted',bound=True,
                    request={'snippet':{'title':'Drill'},'status':{'privacyStatus':'unlisted'}})
    def rotation(self,api):
        return Rotation(self.op,api,'unlisted',threading.Event(),transition,broadcast,300)
    def test_rotation_preserves_privacy_and_commits_only_live(self):
        api=API();r=self.receipt()
        new,at,changed=self.rotation(api).advance(r,0,400)
        self.assertTrue(changed);self.assertEqual(new['id'],'new')
        self.assertEqual(api.rows['old']['status']['lifeCycleStatus'],'complete')
        self.assertEqual(api.rows['new']['status']['lifeCycleStatus'],'live')
        self.assertEqual(api.rows['new']['status']['privacyStatus'],'unlisted')
        self.assertEqual(json.loads((self.op/'broadcast.json').read_text())['id'],'new')
        self.assertFalse(self.rotation(api).advance(new,at,401)[2])
        self.assertEqual(api.inserts,1)
    def test_ended_broadcast_recovers_before_age_threshold(self):
        api=API();api.rows['old']['status']['lifeCycleStatus']='complete'
        self.assertTrue(self.rotation(api).advance(self.receipt(),100,101)[2])
    def test_lost_insert_reply_reconciles_after_controller_restart(self):
        api=API();api.lose_insert=True
        with self.assertRaises(TimeoutError):self.rotation(api).advance(self.receipt(),0,400)
        new,_,_=self.rotation(api).advance(self.receipt(),0,460)
        self.assertEqual(new['id'],'new');self.assertEqual(api.inserts,1)
    def test_rejected_insert_retries_after_restart_with_a_fresh_start_time(self):
        api=API();api.reject_insert=True
        with self.assertRaises(RequestRejected):self.rotation(api).advance(self.receipt(),0,400)
        pending=json.loads((self.op/'broadcast-rotation.json').read_text())
        self.assertFalse(pending['attempted']);self.assertEqual(api.inserts,0)
        self.assertEqual(api.rows['old']['status']['lifeCycleStatus'],'live')
        new,_,changed=self.rotation(api).advance(self.receipt(),0,86400)
        self.assertTrue(changed);self.assertEqual(api.inserts,1)
        self.assertIn(pending['marker'],new['request']['snippet']['description'])
        self.assertEqual(datetime.datetime.fromisoformat(new['request']['snippet']['scheduledStartTime']).timestamp(),86460)
    def test_api_distinguishes_rejections_from_uncertain_http_errors(self):
        for code in (401,403,429,408,500,503):
            with self.subTest(code=code),patch('broadcast_rotation.access_token',return_value='test-token'),patch(
                    'broadcast_rotation.urllib.request.urlopen',side_effect=HTTPError('https://example.invalid',code,'error',{},None)):
                with self.assertRaises(RuntimeError) as caught:
                    LiveAPI().call('POST','https://example.invalid',{})
                self.assertEqual(isinstance(caught.exception,RequestRejected),code in (401,403,429))
                self.assertEqual(str(caught.exception),f'YouTube HTTP {code}')
    def test_token_failure_never_sends_insert_or_exposes_credentials(self):
        for error in (SystemExit('private-token'),RuntimeError('private-token')):
            with self.subTest(error=type(error).__name__),patch('broadcast_rotation.access_token',side_effect=error),patch(
                    'broadcast_rotation.urllib.request.urlopen') as request:
                with self.assertRaisesRegex(RequestRejected,'^YouTube authorization unavailable$'):
                    LiveAPI().call('POST','https://example.invalid',{})
                request.assert_not_called()
    def test_lost_bind_reply_is_idempotent(self):
        api=API();api.lose_bind=True
        with self.assertRaises(TimeoutError):self.rotation(api).advance(self.receipt(),0,400)
        self.assertTrue(self.rotation(api).advance(self.receipt(),0,460)[2])
        self.assertEqual(api.inserts,1)
    def test_uncertain_insert_never_duplicates(self):
        api=API();api.lose_insert=True
        with self.assertRaises(TimeoutError):self.rotation(api).advance(self.receipt(),0,400)
        del api.rows['new']
        with self.assertRaisesRegex(RuntimeError,'ambiguous'):self.rotation(api).advance(self.receipt(),0,460)
        self.assertEqual(api.inserts,1)
    def test_changed_privacy_and_revocation_hold(self):
        api=API();api.rows['old']['status']['privacyStatus']='public'
        with self.assertRaises(AssertionError):self.rotation(api).advance(self.receipt(),0,400)
        self.assertEqual(api.inserts,0)
        api.rows['old']['status'].update(privacyStatus='unlisted',lifeCycleStatus='revoked')
        with self.assertRaisesRegex(RuntimeError,'revoked'):self.rotation(api).advance(self.receipt(),0,400)
        self.assertEqual(api.inserts,0)
    def test_backoff_survives_restart_and_requires_observed_health(self):
        repairs=[]
        def bad():raise RuntimeError('disconnected')
        r=Recovery(self.op,'test')
        self.assertFalse(r.run('camera',bad,lambda:repairs.append(1),grace=0,now=1000))
        r=Recovery(self.op,'test')
        self.assertFalse(r.run('camera',bad,lambda:repairs.append(1),now=1010))
        self.assertEqual(len(repairs),1)
        r.run('camera',bad,lambda:repairs.append(1),now=1030)
        self.assertEqual(len(repairs),2)
        self.assertIn('since',r.states['camera'])
        self.assertTrue(r.run('camera',lambda:None,lambda:None,now=1040))
        self.assertEqual(r.states['camera'],{})
    def test_freeze_requires_ticks_and_changed_camera(self):
        f=FrameProgress()
        self.assertTrue(f.observe('a',1000,10,False,0))
        self.assertTrue(f.observe('a',1000,20,False,180))
        self.assertTrue(f.observe('a',12000,10,False,180))
        self.assertFalse(f.observe('a',12000,20,False,180))
        self.assertTrue(f.observe('a',12000,20,True,181))
        self.assertTrue(f.observe('b',12000,20,False,182))
    def test_memory_trend_and_boot_boundaries(self):
        base=dict(at=100,boot='a',available_bytes=16*GIB,nonpaged_bytes=GIB,commit_bytes=20*GIB,commit_limit=70*GIB)
        later=dict(base,at=100+4*3600,available_bytes=10*GIB,nonpaged_bytes=1.2*GIB)
        result=assess([base,later]);self.assertAlmostEqual(result['nonpaged_gib_per_hour'],.05)
        self.assertTrue(result['warnings']);self.assertAlmostEqual(result['hours_to_4gib'],4)
        result=assess([base,dict(later,boot='b')]);self.assertEqual(result['hours'],0)
        self.assertNotIn('nonpaged_gib_per_hour',result)
    def test_multi_day_tours_visit_every_team_and_resume(self):
        rows=[dict(team=t,stale=False,paused=False,research={'done_count':2},science={'spm':3}) for t in ('green','yellow','blue')]
        tours=Tours(self.op);seen={t:0 for t in ('green','yellow','blue')}
        for now in range(100,3*86400,5):
            choice,hold=tours.choose(rows,now)
            if choice:
                team=choice[0];msg=tours.success(next(r for r in rows if r['team']==team),now)
                self.assertNotIn('position',msg);seen[team]+=1
                tours=Tours(self.op)
        self.assertTrue(all(n>=71 for n in seen.values()),seen)
        self.assertLessEqual(max(seen.values())-min(seen.values()),1)
    def test_feed_restart_cannot_signal_another_run_or_agent(self):
        config=self.op/'stream.json'
        args=['python3','tools/stream/serve.py','--world','imac2','--team','green','--run',str(config),'--port','8791']
        self.assertTrue(owns(args,config,'green',8791))
        self.assertFalse(owns(args,config,'blue',8791))
        self.assertFalse(owns(args,self.op/'other.json','green',8791))
        self.assertFalse(owns(['python3','agent.py']+args[2:],config,'green',8791))
        self.assertFalse(owns(args[:-1],config,'green',8791))
    def test_operator_chat_follows_durable_broadcast_receipt(self):
        class Chat:
            def __init__(self,target):self.target=target
            def poll(self):return self.target
        feed=BroadcastChat(self.op,'old',Chat)
        self.assertEqual(feed.poll(),'old')
        (self.op/'broadcast.json').write_text(json.dumps({'id':'new'}))
        self.assertEqual(feed.poll(),'new')
        self.assertFalse(hasattr(feed,'relay'))
    def test_tours_do_not_discard_a_temporarily_stale_team(self):
        rows=[dict(team=t,stale=False,paused=False) for t in ('green','yellow','blue')]
        tours=Tours(self.op)
        team=tours.choose(rows,100)[0][0]
        tours.success(next(r for r in rows if r['team']==team),100)
        rows[0]['stale']=True
        choice,_=tours.choose(rows,150)
        self.assertEqual(choice[0],'yellow')
        tours.success(rows[1],150)
        rows[0]['stale']=False
        self.assertEqual(tours.choose(rows,200)[0][0],'green')
    def test_low_spool_space_holds_only_recording_with_hysteresis(self):
        self.assertFalse(recording_space_ok(4095))
        self.assertTrue(recording_space_ok(4096))
        self.assertFalse(recording_space_ok(5000,held=True))
        self.assertTrue(recording_space_ok(8192,held=True))
        self.assertFalse(recording_space_ok(None))
    def test_feed_scan_ignores_unrelated_and_unparseable_processes(self):
        config=self.op/'stream.json'
        args=f'tools/stream/serve.py --world imac2 --team green --run {config} --port 8791'
        processes=f'11 python3 {args}\n12 python3 {args.replace("8791","8792")}\n13 editor serve.py \'unterminated\n14 arbitrary \'quote\n15 exited\n'
        with patch('stream_feeds.subprocess.check_output',return_value=processes):
            self.assertEqual(owned_pids(config,'green',8791),[11])


if __name__=='__main__':unittest.main()
