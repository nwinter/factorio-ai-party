#!/usr/bin/env python3
"""Public lifecycle safety: existing content ownership and unlisted binding."""
import sys
from pathlib import Path
import threading
import unittest
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
