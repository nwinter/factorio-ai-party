#!/usr/bin/env python3
"""Paired rosters, scoped audience routing, moderation, and public projection."""
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'tools/stream'),str(ROOT/'tools/mt')]
import viewers
import public_overlay
import public_race

class Harness:
    def __init__(self,team):self.team,self.requests=team,[]
    def command(self,cmd):
        # The production relay serializes a JSON request as a Lua string.
        wire=cmd.split('"dispatch",',1)[1][:-2]
        req=json.loads(wire[2:-2]);self.requests.append(req)
        return json.dumps({'ok':True,'result':{'posted':True,'muted':[]}})

class TestAudience(unittest.TestCase):
    def test_pairs(self):
        rows=[l.split('\t') for l in (ROOT/'agent/mt/teams-test.tsv').read_text().splitlines() if l and not l.startswith('#')]
        self.assertEqual(len(rows),6);self.assertEqual(len({r[1] for r in rows}),6)
        for team,route,model in [('green','agy','gemini-3.8-flash-high'),('yellow','grok','grok-4.7'),('blue','muse','muse-spark-1.3')]:
            pair=[r for r in rows if r[0]==team];self.assertEqual(len(pair),2)
            self.assertTrue(all(r[3]==route and r[4]==model for r in pair))

    def test_site_path_operator_only_and_no_team_relay(self):
        now=time.time()
        with tempfile.TemporaryDirectory() as tmp:
            inbox=Path(tmp)/'viewer-inbox.jsonl'
            for team in ('green','yellow','blue'):
                h=Harness(team)
                with self.assertRaisesRegex(ValueError,'never receive'):
                    viewers.Relay(h,str(Path(tmp)/'relay'))
                self.assertEqual(h.requests,[])
            source=viewers.SiteChat(fetch=lambda *_:json.dumps({'messages':[{'seq':701,'name':'Visitor','text':'Green, how are the furnaces?','t':now}],'last_seq':701,'open':True}),resume=700)
            messages,dels,_=source.poll()
            feed=viewers.Feed({'site':source},inbox=str(inbox),operator_only=True)
            feed.ingest(messages,dels,now)
            self.assertIsNone(feed.relay)
            self.assertEqual(feed.lane()[0][0]['text'],'Green, how are the furnaces?')
            self.assertEqual(feed.lane()[1]['delivery'][0]['status'],'operator')
            again=viewers.Feed({},inbox=str(inbox),operator_only=True);again.ingest(messages,[],now)
            self.assertEqual(len(inbox.read_text().splitlines()),1)
            self.assertEqual(json.loads(inbox.read_text())['id'],'site:701')

    def test_hidden_deletion_and_rate_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'hidden.json';p.write_text(json.dumps({'names':['Visitor']}))
            hidden=viewers.HiddenViewers(str(p),tmp);f=viewers.Filter();f.hidden=hidden
            m={'id':'site:1','source':'site','name':'Visitor','text':'How are the furnaces?','author':'v','t':100}
            self.assertIn('hidden',f.check(m,100)[1])
            r=viewers.Relay(Harness(None),str(p),roster=[('gemini',None)]);r.hidden=hidden
            r.offer(dict(m),'v');self.assertIsNone(r.step(100));self.assertEqual(len(r.q),0)
            f=viewers.Filter();reasons=[]
            for i in range(21):
                m=dict(m,id=f'site:{i}',name='Guest '+str(i),author=str(i),text=f'How are the furnaces at row {i}?')
                reasons=f.check(m,100)[1]
            self.assertIn('busy',reasons)
            feed=viewers.Feed({});feed.ingest([dict(m,t=time.time())],[],time.time());feed.ingest([], [('id',m['id'])],time.time())
            self.assertFalse(feed.lane()[0])

    def test_internal_tell_only_own_recipients_and_receipts(self):
        roster=[{'name':'gemini'},{'name':'gemini2'}]
        state={'now':100,'chat':[{'lane':'tell','agent':'gemini','to':['gemini2'],'body':'Supply the lab','text':'Ignored presentation text'},
                               {'lane':'tell','agent':'gemini','to':['grok'],'text':'FOREIGN'},
                               {'lane':'talk','agent':'grok','text':'FOREIGN'},
                               {'lane':'operator','agent':'gemini','text':'OPERATOR'}]}
        out=public_race.project('green',state,roster,100)
        self.assertEqual([m['text'] for m in out['chat']],['Supply the lab'])
        self.assertEqual(public_race.speech('This is multi-team mode'), '')
        states={'operator':{'viewers_status':{'delivery':[{'id':'site:701','status':'operator'}]}}}
        receipt=public_overlay.audience(states,['green','yellow','blue'],100)['viewer_delivery']['701']
        self.assertEqual(receipt['s'],'operator');self.assertEqual(receipt['teams'],[])
        self.assertEqual(public_overlay.audience({'green':states['operator']},['green'],100)['viewer_delivery'],{})

if __name__=='__main__':unittest.main()
