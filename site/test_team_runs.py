#!/usr/bin/env python3
"""Offline spectator contract, durable history and real Chromium behavior."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import team_runs as tr
from test_archive import make
from test_maptoolbar import playwright

SITE = Path(__file__).resolve().parent


def fixture(now=None):
    now = time.time() if now is None else now
    tick = 3 * 24 * 216000
    return {'now': now, 'teams': [
        {'team': t, 'tick': tick, 'stale': False, 'agents': [{'name': name, 'model': model, 'activity': 'acting'}],
         'race': {'milestones': n, 'tick': 100 + i, 'latest': ('logistic-science-pack' if n == 2 else 'automation-science-pack') if n else None,
                  'reached': ['automation-science-pack', 'logistic-science-pack'][:n]}, 'pacts': [{'id': 1, 'with': 'blue' if t == 'green' else 'green'}]}
        for i, (t, name, model, n) in enumerate([('green','gemini','Gemini Flash',2), ('blue','grok','Grok',1), ('yellow','muse','Muse',0)])],
        'market': {'wallets': {'green': {'wallet': 0, 'reserved': 0}, 'blue': {'wallet': 999999, 'reserved': 20}}},
        'events': [{'kind': 'contact', 'team': 'green', 'other': 'blue', 'tick': 200, 'text': 'First contact with Blue'}],
        'feed': [{'kind': 'market', 'team': 'green', 'to_team': 'blue', 'tick': 300, 'text': 'Traded iron plates with Blue'}]}


class TeamRuns(unittest.TestCase):
    def test_projection_separates_money_and_race_and_drops_private_fields(self):
        raw = fixture(100)
        raw.update(operator={'secret': 'DO NOT PUBLISH'}, deadline_tick=9999, config={'secret': 'DO NOT PUBLISH'})
        raw['teams'][0].update(wiped=True, notes='DO NOT PUBLISH')
        raw['events'] += [{'kind': 'pact', 'team': 'green', 'tick': 100, 'text': '/private/operator/notes'},
                          {'kind': 'pact', 'team': [], 'tick': 100, 'text': 'bad'},
                          {'kind': [], 'team': 'green', 'tick': 100, 'text': 'bad'}]
        s = tr.project(raw, 'days', 100)
        self.assertEqual([r['rank'] for r in s['teams']], [1,2,3])
        self.assertEqual([r['coins'] for r in s['teams']], [0,999999,None])
        self.assertEqual(len(s['events']), 2)
        self.assertNotIn('DO NOT PUBLISH', json.dumps(s))
        self.assertNotIn('deadline', json.dumps(s))
        self.assertNotIn('wiped', json.dumps(s))
        self.assertEqual(tr.project(raw, 'days', 200)['status'], 'unavailable')
        self.assertIsNone(tr.project(raw, '../escape', 100))
        self.assertIsNone(tr.project({}, 'days', 100))
        raw['teams'][0]['pacts'] = [{'id': 1, 'with': []}]
        self.assertEqual(tr.project(raw, 'days', 100)['teams'][0]['pacts'], [])

    def test_restart_pagination_restore_and_result(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)/'days/op/public-site'
            raw = fixture(100)
            arc = tr.Archive(folder, 'days')
            for start in range(0, 250, 50):
                raw['events'] = [{'kind': 'pact', 'team': 'green', 'tick': n, 'text': f'Pact #{n} accepted'} for n in range(start, start+50)]
                arc.save(tr.project(raw, 'days', 100))
            arc.close()
            arc = tr.Archive(folder, 'days')
            arc.save(tr.project(raw, 'days', 100))
            self.assertEqual(arc.db.execute('SELECT count(*) FROM events').fetchone()[0], 251)
            raw['result'] = {'reason': 'edge', 'kind': 'solo', 'tick': raw['teams'][0]['tick'], 'winners': ['green'], 'scores': {'green':1.5}, 'text':'DO NOT PUBLISH'}
            arc.save(tr.project(raw, 'days', 100)); arc.close()
            state = tr.load(d)[0][0]
            self.assertEqual(state['status'], 'ended')
            self.assertEqual(state['result']['text'], 'Green reached the edge alone')
            self.assertEqual([len(p) for p in tr.event_pages(folder,state)], [100,100,51])
            arc = tr.Archive(folder, 'days')
            raw['result'] = None
            for t in raw['teams']: t['tick'] = 1000
            arc.save(tr.project(raw, 'days', 100)); arc.close()
            self.assertTrue(any(e['kind'] == 'restore' for p in tr.event_pages(folder,tr.load(d)[0][0]) for e in p))

    def test_legacy_archive_uses_only_public_facts(self):
        sys.path.insert(0,str(SITE.parent/'tools/mt'))
        import archive_site
        view = {'t':'2026-11-14 12:00:00', 'teams':[{'team':'green','agents':[], 'score':{'tick':1000}, 'errors':{}, 'tells':['DO NOT PUBLISH']}],
                'contacts':[], 'pacts':[], 'game':{'standings':[], 'config':{'deadline_tick':999},'alerts':['DO NOT PUBLISH']}}
        s = archive_site.snapshot(view,'old-test')
        self.assertIsNone(s['teams'][0]['race'])
        self.assertNotIn('DO NOT PUBLISH',json.dumps(s))
        self.assertNotIn('deadline',json.dumps(s))

    def test_publisher_archives_the_same_public_projection(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            raw = fixture()
            raw['operator'] = {'text': 'DO NOT PUBLISH'}
            (folder/'raw.json').write_text(json.dumps(raw))
            p = subprocess.run([sys.executable, str(SITE/'push_live.py'), '--team-tests', '--team-run-id', 'days',
                                '--team-archive-dir', str(folder/'archive'), '--source', (folder/'raw.json').as_uri(),
                                '--once', '--print'], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            payload = json.loads(p.stdout)
            self.assertEqual(payload['team_run']['teams'][0]['coins'], 0)
            self.assertNotIn('DO NOT PUBLISH', p.stdout)
            saved = json.loads((folder/'archive/state.json').read_text())
            self.assertEqual(saved['teams'], payload['team_run']['teams'])

    def test_browser(self):
        found = playwright()
        if not found:
            if os.environ.get('POG_REQUIRE_BROWSER') == '1':
                self.fail('Playwright and cached Chromium are required')
            self.skipTest('no cached Playwright/Chromium; set PLAYWRIGHT to the module directory')
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp); runs = d/'runs'; runs.mkdir(); make(runs)
            content = dict(json.loads((SITE/'content/site.json').read_text()),archive=False,run_start='pub1')
            (d/'content.json').write_text(json.dumps(content))
            raw = fixture()
            state = tr.project(raw,'days',raw['now'])
            folder = runs/'days/op/public-site'; arc = tr.Archive(folder,'days')
            for n in range(120):
                raw['events'] = [{'kind':'pact','team':'green','tick':n,'text':f'Pact #{n} accepted'}]
                arc.save(tr.project(raw,'days',raw['now']))
            arc.close()
            out = d/'dist'
            built = subprocess.run([sys.executable,str(SITE/'build.py'),'--out',str(out),'--runs-dir',str(runs),'--content',str(d/'content.json')],capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stderr[-2000:])
            class Quiet(SimpleHTTPRequestHandler):
                def log_message(self,*args): pass
            server = ThreadingHTTPServer(('127.0.0.1',0),partial(Quiet,directory=str(out)))
            thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
            (d/'state.json').write_text(json.dumps(state))
            (d/'browser.cjs').write_text(BROWSER)
            try:
                result = subprocess.run(['node',str(d/'browser.cjs'),found[0],found[1],f'http://127.0.0.1:{server.server_port}',str(d/'state.json'),os.environ.get('MT304_ARTIFACTS','')],capture_output=True,text=True,timeout=90)
                self.assertEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
                print(result.stdout)
            finally:
                server.shutdown();server.server_close();thread.join()


BROWSER = r'''
const fs=require('fs'), assert=require('assert'), pw=require(process.argv[2]);
const [exe,base,file,art]=process.argv.slice(3);
(async()=>{
 const browser=await pw.chromium.launch({executablePath:exe});
 let state=JSON.parse(fs.readFileSync(file));
 const page=await browser.newPage({viewport:{width:1280,height:1000}});
 const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.route('**/*',route=>route.request().url().includes('/v1/state') ? route.fulfill({json:{team_run:state}}) : route.request().url().startsWith(base) ? route.continue() : route.abort());
 await page.goto(base+'/teams/');
 await page.getByRole('heading',{name:'#1 · Green',exact:true}).waitFor();
 assert((await page.locator('#team-run-status').innerText()).includes('3d 0h 0m'));
 assert((await page.locator('[data-team="green"] .team-run-coins').innerText()).startsWith('0 coin'));
 assert((await page.locator('[data-team="blue"] .team-run-coins').innerText()).startsWith('999,999 coin'));
 assert((await page.locator('#team-run-events').innerText()).includes('Traded iron plates'));
 if(art) await page.screenshot({path:art+'/team-run-desktop.png',fullPage:true});
 await page.setViewportSize({width:390,height:900});
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 if(art) await page.screenshot({path:art+'/team-run-mobile.png',fullPage:true});
 state.events.push({kind:'market',team:'green',tick:10,text:'<img src=x onerror="window.injected=true">'});
 state.result={reason:'edge',kind:'solo',tick:state.tick,text:'Green reached the edge alone',scores:{green:1.5}};
 await page.reload();await page.getByRole('heading',{name:'Game over',exact:true}).waitFor();
 assert(await page.locator('#team-run-events img').count()===0);
 assert(!await page.evaluate(()=>window.injected));
 state.result=null;state.now-=120;await page.reload();
 await page.getByRole('heading',{name:'Green',exact:true}).waitFor();
 assert((await page.locator('#team-run-status').innerText()).includes('Updates unavailable'));
 await page.goto(base+'/teams/days/');
 await page.getByRole('button',{name:'Older events'}).waitFor();
 assert((await page.locator('#team-run-status').innerText()).includes('Archived snapshot'));
 assert(await page.locator('.team-run-history li').count()===100);
 await page.getByRole('button',{name:'Older events'}).click();
 await page.waitForFunction(()=>document.querySelectorAll('.team-run-history li').length===21);
 assert((await page.locator('#team-run-events').innerText()).includes('Pact #0'));
 assert.deepEqual(errors,[]);await browser.close();console.log('Playwright: desktop, phone, stale feed, game over, escaping and archive pagination passed');
})().catch(e=>{console.error(e);process.exit(1)});
'''

if __name__ == '__main__':
    unittest.main()
