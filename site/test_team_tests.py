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
    def test_chat_ui_enters_and_leaves_test_mode(self):
        from test_sitechat import LIVE_CHAT_JS
        driver=LIVE_CHAT_JS.replace("require(process.argv[2]);", "eval(fs.readFileSync(process.argv[2], 'utf8').replace('  tick();\\n})();', '  globalThis.modeForTest = showTestMode; globalThis.repliesForTest = () => replyLines;\\n  tick();\\n})();'));")
        driver=driver.replace("out.html = kids['#vchat'].innerHTML;", """out.html = kids['#vchat'].innerHTML;
          out.testMode = [kids['#team-test-chat-help'].hidden, kids['#vchat-game-help'].hidden, kids['#vchat-replies-label'].hidden];
          out.testReplies = repliesForTest().map(r => r.by);
          modeForTest(false);
          out.normalMode = [kids['#team-test-chat-help'].hidden, kids['#vchat-game-help'].hidden, kids['#vchat-replies-label'].hidden];
          out.normalReplies = repliesForTest().map(r => r.by);
          modeForTest(true);""")
        now=time.time();s=contract.public_state(fixture(now),now=now)
        s['viewer_replies']=[{'seq':1,'by':'gemini','text':'A historical agent answer','t':now-1},
                             {'seq':2,'by':'operator','text':'An operator answer','t':now-1}]
        with tempfile.TemporaryDirectory() as tmp:
            js=Path(tmp)/'check.js';state=Path(tmp)/'state.json'
            js.write_text(driver);state.write_text(json.dumps(s))
            out=json.loads(subprocess.check_output(['node',str(js),str(Path(__file__).parent/'static/live.js'),str(state)],text=True))
        self.assertEqual(out['testMode'],[False,True,True])
        self.assertEqual(out['normalMode'],[True,False,False])
        self.assertEqual(out['testReplies'],['operator'])
        self.assertEqual(out['normalReplies'],['gemini','operator'])

    def test_only_operator_receipts_in_tests(self):
        s=fixture();s['viewer_delivery']={'1':{'s':'operator','teams':['green'],'t':100},
                                         '2':{'s':'relayed','teams':['green'],'t':100},
                                         '3':{'s':'held','teams':['green'],'t':100}}
        receipts=contract.public_state(s,now=100)['viewer_delivery']
        self.assertEqual(set(receipts),{'1','3'})
        self.assertEqual(receipts['1']['to'],'')
        self.assertEqual(receipts['1']['why'],"to the operator's inbox")
        self.assertNotIn('team',receipts['3']['why'])

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

    def test_chosen_identity_and_tell_recipients(self):
        s=fixture();r=s['teams'][0]
        r['agents'][0].update(display_name='Vesper',persona='A patient miner who counts every plate',glyph='⚙',color='#3CB44B',pronouns='she/her',notes='NOT PUBLIC')
        r['agents'][1].update(display_name='Gemini2',persona='see /home/private/notes',glyph='<b>',color='red',pronouns='not a pronoun')
        r['chat']=[{'name':'gemini','text':'Bring coal.','kind':'tell','to':['gemini2']},{'name':'gemini2','text':'On my way.','kind':'tell','to':['team']},
                   {'name':'gemini','text':'Labs are up.','kind':'talk','to':['gemini2']},{'name':'gemini','text':'Foreign.','kind':'tell','to':['grok']},
                   {'name':'gemini','text':'Mixed.','kind':'tell','to':['gemini2',{'x':1}]}]
        out=contract.public_state(s,now=100)['teams'][0]
        self.assertEqual(out['agents'][0],{'name':'gemini','model':'Gemini Flash','activity':'acting','display_name':'Vesper',
                                           'persona':'A patient miner who counts every plate','glyph':'⚙','color':'#3cb44b','pronouns':'she/her'})
        self.assertEqual(out['agents'][1],{'name':'gemini2','model':'','activity':'thinking'})    # nothing chosen survives: the roster entry alone
        self.assertEqual([m.get('to') for m in out['chat']],[['gemini2'],['team'],None,None,None])
        self.assertNotIn('NOT PUBLIC',json.dumps(out))
        for bad in ('Operator','The Moderator','YouTube','/home/private','<b>x</b>','x','https://private.example','key@example.com','x'*201,7,None):
            r['agents'][0]['display_name']=bad
            self.assertNotIn('display_name',contract.public_state(s,now=100)['teams'][0]['agents'][0],bad)
        self.assertEqual(contract.chosen_name('Sprocket ⚙️ the  Great!!'),'Sprocket the Great!!')
        self.assertEqual(contract.chosen_name('Grok the Unyielding'),'Grok the Unyielding')
        self.assertEqual([contract.glyph(g) for g in ('G2','♊','👩‍🚀',' ','a b','too long glyph',5)],['G2','♊','👩‍🚀','','','',''])

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
