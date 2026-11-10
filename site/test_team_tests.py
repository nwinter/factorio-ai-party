#!/usr/bin/env python3
"""Team-test public contract and pusher: no private state or auxiliary documents."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, str(Path(__file__).resolve().parent))
import team_tests as contract
import moderation


def fixture(now=100):
    return {'now': now, 'teams': [{'team': 'green', 'stale': False,
        'agents': [{'name': 'gemini', 'model': 'Gemini Flash', 'activity': 'acting'}, {'name': 'gemini2', 'activity': 'thinking'}],
        'research': {'label': 'Automation', 'progress': .4, 'done_count': 2},
        'chat': [{'name': 'gemini', 'text': 'I will supply the lab.'}],
        'board': [{'title': 'Supply the lab', 'owner': 'gemini2'}]}],
        'stream': {'youtube_video_id': 'abcdefghijk'}}


class TestContract(unittest.TestCase):
    def test_allowlist_and_moderation(self):
        s=fixture();r=s['teams'][0]
        r['operator']={'path':'/home/private'};r['agents'][0]['notes']='NOT PUBLIC'
        private=['/home/private/note', 'https://private.example/secret', 'key@example.com', 'multi'+'-team', 'secret word', 'POG_PRIVATE']
        r['chat'] += [{'name':'gemini','text':v} for v in private] + [{'name':'foreign','text':'NOT PUBLIC'}]
        h=moderation.Hidden();h.add_text('Guest','Hidden audience line')
        s['viewers']=[{'source':'youtube','id':'yt:1','name':'Guest','text':'Hidden audience line','t':100},
                      {'source':'youtube','id':'yt:2','name':'Guest','text':'How is the iron?','t':100}]
        out=contract.public_state(s,now=100,hidden=h);wire=json.dumps(out)
        self.assertNotIn('NOT PUBLIC',wire)
        for v in private:self.assertNotIn(v,wire)
        self.assertEqual(len(out['teams'][0]['chat']),1)
        self.assertEqual([v['id'] for v in out['youtube_chat']],['yt:2'])
        self.assertTrue(out['active']);self.assertEqual(out['stream']['youtube_video_id'],'abcdefghijk')

    def test_stale_off_and_malformed(self):
        self.assertFalse(contract.public_state(fixture(),now=131)['active'])
        self.assertFalse(contract.public_state(dict(fixture(),active=False),now=100)['active'])
        s=fixture();s['teams'] += [{'team':[]},{}]
        s['teams'][0]['agents'].append({'name':'bad','activity':{},'model':{}})
        s['teams'][0]['research']['progress']=float('nan')
        out=contract.public_state(s,video='bad/url',now=100)
        self.assertNotIn('stream',out);self.assertIsNone(out['teams'][0]['research']['progress'])
        json.dumps(out,allow_nan=False)

    def test_real_pusher_and_off_use_only_state(self):
        seen=[]
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append(('GET',self.path))
                body=json.dumps(fixture(time.time())).encode();self.send_response(200);self.end_headers();self.wfile.write(body)
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                seen.append(('POST',self.path,body));self.send_response(200);self.end_headers();self.wfile.write(b'{}')
            def log_message(self,*_):pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            import os
            base='http://127.0.0.1:'+str(server.server_port)
            with tempfile.TemporaryDirectory() as tmp:
                args=[sys.executable,str(Path(__file__).with_name('push_live.py')),'--api',base,'--lock',tmp+'/lock']
                env=dict(os.environ,POG_LIVE_TOKEN='fixture')
                subprocess.run(args+['--team-tests','--once','--source',base+'/state.json'],env=env,check=True,capture_output=True)
                subprocess.run(args+['--team-tests-off'],env=env,check=True,capture_output=True)
            self.assertEqual([(r[0],r[1]) for r in seen],[('GET','/state.json'),('POST','/v1/state'),('POST','/v1/state')])
            self.assertTrue(seen[1][2]['active']);self.assertFalse(seen[2][2]['active'])
        finally:server.shutdown();server.server_close()

if __name__=='__main__':unittest.main()
