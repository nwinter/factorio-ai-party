#!/usr/bin/env python3
"""Public lifecycle safety: existing content ownership and unlisted binding."""
import sys
from pathlib import Path
import threading
import tempfile
import unittest
from unittest.mock import patch
import json
sys.path.insert(0,str(Path(__file__).resolve().parent/'mt'))
import public_session as session

class Api:
    def __init__(self,privacy='unlisted',stream='s'):
        self.privacy,self.stream,self.phase,self.posts=privacy,stream,'ready',[]
    def call(self,method,url):
        if method=='POST':
            self.posts.append(url)
            self.phase='live' if 'broadcastStatus=live' in url else 'testing'
            return {}
        if '/liveStreams?' in url:return {'items':[{'status':{'streamStatus':'active'}}]}
        return {'items':[{'status':{'privacyStatus':self.privacy,'lifeCycleStatus':self.phase},'contentDetails':{'boundStreamId':self.stream}}]}

class TestSession(unittest.TestCase):
    def test_publisher_recovery_keeps_archive_and_credential_checkout(self):
        with tempfile.TemporaryDirectory() as d:
            main=Path(d); op=main/'runs'/'trial'/'op'
            credentials=main/'site/worker/.secrets.json'
            credentials.parent.mkdir(parents=True)
            credentials.write_text(json.dumps({'PUBLISH_TOKEN':'fixture-publisher-token'}))
            with patch.object(session,'MAIN',main), patch.dict(session.os.environ,{},clear=True):
                env=session.publisher_env('video')
                self.assertEqual(env['POG_LIVE_TOKEN'],'fixture-publisher-token')
                self.assertEqual(env['POG_YOUTUBE'],'video')
                session.os.environ['POG_LIVE_TOKEN']='explicit-fixture-token'
                self.assertEqual(session.publisher_env('video')['POG_LIVE_TOKEN'],'explicit-fixture-token')
            cmd=session.publisher_command('trial',op)
            self.assertEqual(cmd[1],str(session.ROOT/'site/push_live.py'))
            self.assertEqual(cmd[cmd.index('--team-archive-dir')+1],str(op/'public-site'))
            self.assertEqual(cmd[cmd.index('--team-run-id')+1],'trial')
            self.assertEqual(session.publisher_command('trial',op,off=True),cmd[:2]+['--team-tests-off'])

    def test_stale_or_partial_roster_cannot_look_healthy(self):
        expected={t:{t+'1',t+'2'} for t in ('green','yellow','blue')}
        state={'now':100,'teams':[{'team':t,'stale':False,'agents':[{'name':n} for n in sorted(expected[t])]} for t in expected]}
        self.assertTrue(session.fresh_feed(state,110,expected))
        self.assertFalse(session.fresh_feed(state,161,expected))
        state['teams'][1]['stale']=True
        self.assertFalse(session.fresh_feed(state,110,expected))
        state['teams'][1]['stale']=False
        state['teams'][0]['agents'][0]['name']='another-agent'
        self.assertFalse(session.fresh_feed(state,110,expected))
        state['teams'][0]['agents'][0]['name']='green1'
        state['teams'][0]['agents'].pop()
        self.assertFalse(session.fresh_feed(state,110,expected))

    def test_selected_roster_controls_health_check(self):
        with tempfile.TemporaryDirectory() as d:
            op=Path(d)
            (op/'streams.txt').write_text('green http://localhost:8791/\nyellow http://localhost:8792/\n')
            (op/'teams.tsv').write_text('# roster\ngreen\tg1\ngreen\tg2\nyellow\ty1\nyellow\ty2\nblue\tb1\nblue\tb2\n')
            expected=session.roster_of(op)
        self.assertEqual(expected,{'green':{'g1','g2'},'yellow':{'y1','y2'}})
        state={'now':100,'teams':[{'team':t,'stale':False,'agents':[{'name':n} for n in names]} for t,names in expected.items()]}
        self.assertTrue(session.fresh_feed(state,110,expected))
        state['teams'].append(state['teams'][0])
        self.assertFalse(session.fresh_feed(state,110,expected))

    def test_never_clear_another_publication(self):
        self.assertFalse(session.owns_site({'mode':'team-tests','stream':{'youtube_video_id':'other'}},'ours'))
        self.assertFalse(session.owns_site({'stream':{'youtube_video_id':'ours'}},'ours'))
        self.assertFalse(session.owns_site({},'ours'))
        self.assertTrue(session.owns_site({'mode':'team-tests','stream':{'youtube_video_id':'ours'}},'ours'))
    def test_changed_privacy_or_binding_refuses_transition(self):
        for api in (Api(privacy='public'),Api(stream='other')):
            with self.assertRaises(AssertionError):session.transition(api,{'id':'v','stream_id':'s'},'live',threading.Event())
            self.assertFalse(api.posts)
    def test_transition_retry_does_not_duplicate_post(self):
        api=Api();receipt={'id':'v','stream_id':'s'}
        session.transition(api,receipt,'live',threading.Event())
        session.transition(api,receipt,'live',threading.Event())
        self.assertEqual(len(api.posts),1)

if __name__=='__main__':unittest.main()
