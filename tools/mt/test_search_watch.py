"""tools/mt/search_watch.py: transcripts of each kind, the term rules, single hits, counts per hour, the supervisor hook."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))
import search_watch as W  # noqa: E402

CFG = W.config()
TEAMS = {'yellow': ['grok', 'grok2'], 'blue': ['muse', 'muse2'], 'green': ['gemini', 'gemini2']}
# What agents searched in past shifts (report-mt302): game lookups, none of which may flag.
PAST = ['Factorio 2.0 underground belt max distance tiles yellow basic',
        'Factorio 2.0 artillery turret automatic targeting minimum range nearest spawner worm',
        'Factorio Space Age first pentapod egg how to obtain when none left Gleba',
        'Factorio 2.0 artificial jellynut soil what tiles can it be placed on landfill',
        'Factorio space age medium strafer pentapod health range speed',
        'Factorio gleba-spawner-small health pentapod egg drop site:wiki.factorio.com',
        'Factorio 2.0 agricultural science pack freshness lab research progress half spoiled',
        'Factorio 2.0 agricultural tower planting radius area tiles yumako',
        'Factorio 2.0 quality module bonus probability uncommon per craft formula',
        'Factorio 2.0 circuit network read item spoilage percentage belt inserter enable',
        'Factorio Space Age railgun turret range footprint size wiki',
        'Factorio Space Age thruster exhaust plume damage length tiles wiki',
        'Factorio turbo underground belt maximum distance tiles Space Age',
        'Factorio fusion reactor fusion power cell consumption rate how long does one cell last plasma',
        'https://wiki.factorio.com/index.php?title=Thruster&curid=50581&oldid=216612',
        'Factorio green circuit blue circuit ratio red belt', 'Factorio blue science base layout',
        'Factorio enemy base attack turret creep', 'Factorio multiplayer blueprint book sharing']


def jl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as f:
        for r in rows:
            f.write(json.dumps(r) + '\n')


def grok_search(cid, query, t, sources=()):
    return {'timestamp': t, 'method': 'session/update', 'params': {'update': {
        'sessionUpdate': 'tool_call_update', 'toolCallId': cid, 'status': 'completed', 'title': 'Web search:',
        'rawOutput': {'action': {'type': 'search', 'query': query,
                                 'sources': [{'type': 'url', 'url': u} for u in sources]}}}}}


def grok_open(cid, url, t):
    return {'timestamp': t, 'params': {'update': {'sessionUpdate': 'tool_call_update', 'toolCallId': cid,
                                                  'rawOutput': {'action': {'type': 'open_page', 'url': url}}}}}


def grok_shell(cid, command, t):
    return {'timestamp': t, 'params': {'update': {'sessionUpdate': 'tool_call', 'toolCallId': cid,
                                                  'title': 'run_terminal_command', 'rawInput': {'command': command}}}}


def muse_calls(t, calls):
    return {'recorded_at': int(t * 1e6), 'payload': {'event': {'kind': 'assistant_tool_calls_committed', 'tool_calls': [
        {'id': cid, 'call_id': cid, 'name': name, 'args': json.dumps(args)} for cid, name, args in calls]}}}


def agy_calls(step, t, calls):
    return {'step_index': step, 'type': 'PLANNER_RESPONSE',
            'created_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t)),
            'tool_calls': [{'name': n, 'args': {k: json.dumps(v) for k, v in a.items()}} for n, a in calls]}


class Terms(unittest.TestCase):
    def test_project_and_operator_terms_flag_alone(self):
        t = W.Terms(CFG, TEAMS, 'yellow')
        for text, label in [('Player of Games factorio', 'project'), ('playerofgames youtube', 'project'),
                            ('https://factorio.nickwinter.net/live', 'site'), ('Nick Winter AI', 'operator'),
                            ('github.com/nwinter/factorio-ai-party', 'repo'), ('factorio ai party stream', 'repo'),
                            ('youtube @PlayerOfGames', 'channel'), ('account-c.app', 'operator'),
                            ('AI party game agents', 'ai-party')]:
            self.assertIn(label, t.match(text), text)

    def test_past_game_lookups_never_flag(self):
        t = W.Terms(CFG, TEAMS, 'yellow')
        for q in PAST:
            self.assertEqual(t.match(q), [], q)
        self.assertEqual(W.Terms(CFG, None, None).match(PAST[0]), [], 'default team colors too')

    def test_ai_run_terms_need_all_three(self):
        t = W.Terms(CFG, TEAMS, 'yellow')
        self.assertIn('ai-factorio-run', t.match('LLM agents playing Factorio live stream'))
        self.assertIn('ai-factorio-run', t.match('factorio AI teams competition'))
        self.assertIn('ai-factorio-run', t.match('Factorio Learning Environment'))
        self.assertEqual(t.match('Factorio AI biter behaviour'), [], 'no team or stream word')
        self.assertEqual(t.match('Factorio multiplayer server setup'), [], 'no AI word')

    def test_rival_colors_and_names_but_not_own(self):
        y, b = W.Terms(CFG, TEAMS, 'yellow'), W.Terms(CFG, TEAMS, 'blue')
        self.assertEqual(y.match('where is the blue team base'), ['team-color:blue'])
        self.assertEqual(b.match('where is the blue team base'), [], 'own color')
        self.assertIn('team-color:green', y.match('team green factorio'))
        self.assertEqual(y.match('yellow team plan'), [], 'own color')
        self.assertEqual(y.match('green circuits'), [])
        self.assertEqual(y.match('gemini factorio agent'), ['team-name:gemini'])
        self.assertEqual(W.Terms(CFG, TEAMS, 'green').match('gemini factorio agent'), [], 'own agent name')
        self.assertEqual(y.match('gemini api pricing'), [], 'a name needs a context word')
        named = W.Terms(CFG, TEAMS, 'yellow', [('blue', 'Ferrum'), ('yellow', 'Vale')])
        self.assertEqual(named.match('Ferrum factorio'), ['team-name:Ferrum'])
        self.assertEqual(named.match('Vale factorio'), [])


class Run(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.root = root
        self.op = root/'runs'/'r302w'/'op'
        self.op.mkdir(parents=True)
        self.wake = root/'search-wake.jsonl'
        self.t0 = time.time() - 600
        folders = {team: root/f'play-{team}'/'runs'/'r302w' for team in TEAMS}
        for f in folders.values():
            f.mkdir(parents=True)
        kinds = {'yellow': 'grok', 'blue': 'muse', 'green': 'agy'}
        self.state = dict(started=self.t0, agents={n: dict(name=n, team=team, kind=kinds[team], folder=str(folders[team]))
                                                   for team, ns in TEAMS.items() for n in ns})
        roots = {'grok': [str(root/'grokroot')], 'agy': [str(root/'agyroot')], 'muse': [], 'claude': [], 'codex': []}
        self.roots = patch.object(W.tokens, '_roots', roots)
        self.roots.start()
        # Grok: the workspace's own home
        ws = folders['yellow']/'grok'
        self.grok = ws/'.grok-home'/'sessions'/quote(str(ws), safe='')/'s1'/'updates.jsonl'
        # Muse: the workspace's native root
        native = root/'pg-test'
        (folders['blue']/'muse').mkdir()
        (folders['blue']/'muse'/'.native-root').write_text(str(native) + '\n')
        self.muse = native/'data'/'muse'/'sessions'/'2026'/'11'/'14'/'m1'/'session.jsonl'
        # agy: a conversation that names runs/r302w/gemini
        self.agy = root/'agyroot'/'brain'/'conv1'/'.system_generated'/'logs'/'transcript.jsonl'
        jl(self.agy, [{'step_index': 0, 'type': 'USER_INPUT', 'content': ('cwd runs/r302w/gemini ' * 60)}])

    def tearDown(self):
        self.roots.stop()
        self.tmp.cleanup()

    def scan(self):
        with patch.object(W, 'WAKE', self.wake):
            return W.scan_run(self.op, self.state)

    def lines(self, path):
        return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []

    def test_each_kind_hits_once_and_counts_per_hour(self):
        t = self.t0 + 60
        jl(self.grok, [grok_search('c1', 'Factorio 2.0 belt throughput', t),
                       grok_search('c2', 'Player of Games factorio stream', t + 1),
                       grok_search('c3', 'factorio rocket silo', t + 2, ['https://factorio.nickwinter.net/']),
                       grok_open('c4', 'https://wiki.factorio.com/Belt', t + 3),
                       grok_shell('c5', 'curl -s http://127.0.0.1:8080/x; ./fh call status', t + 4),
                       grok_search('c6', 'where is the blue team base', t + 5)])
        jl(self.muse, [muse_calls(t + 10, [('m1', 'web_search', {'query': 'Factorio gleba spoilage'}),
                                           ('m2', 'web_fetch', {'url': 'https://github.com/nwinter/factorio-ai-party'}),
                                           ('m3', 'bash', {'command': 'ls'})])])
        jl(self.agy, [agy_calls(1, t + 20, [('search_web', {'query': 'yellow team factorio grok'}),
                                            ('read_url_content', {'Url': 'https://wiki.factorio.com/Inserter'}),
                                            ('run_command', {'CommandLine': 'curl https://www.youtube.com/@PlayerOfGames'})])])
        hits = self.scan()
        got = sorted((h['agent'], h['kind'], tuple(h['labels'])) for h in hits)
        self.maxDiff = None
        self.assertEqual(got, [('gemini', 'search', ('ai-factorio-run', 'team-color:yellow', 'team-name:grok')),
                               ('gemini', 'shell', ('project', 'channel')),
                               ('grok', 'result', ('operator', 'site')),
                               ('grok', 'search', ('project',)),
                               ('grok', 'search', ('team-color:blue',)),
                               ('muse', 'fetch', ('operator', 'repo', 'ai-party', 'ai-factorio-run'))])
        wake = self.lines(self.wake)
        self.assertEqual(len(wake), 6)
        self.assertEqual(set(wake[0]), {'t', 'from', 'text'})
        self.assertTrue(all(w['from'] == 'search-watch' and w['text'].startswith('search-watch r302w: ') for w in wake))
        alerts = self.lines(self.op/'alerts.jsonl')
        self.assertEqual([a['event'] for a in alerts], ['search-hit'] * 6)
        self.assertEqual(len(self.lines(self.op/'search-hits.jsonl')), 6)
        hours = json.loads((self.op/'search-watch.json').read_text())['hours']
        hr = W.hour(t)
        self.assertEqual(hours['grok'][hr], {'search': 4, 'open': 1, 'shell': 1})
        self.assertEqual(hours['muse'][hr], {'search': 1, 'fetch': 1})
        self.assertEqual(hours['gemini'][hr], {'search': 1, 'fetch': 1, 'shell': 1})
        # Nothing new: nothing written. A restarted watcher reads the same state.
        self.assertEqual(self.scan(), [])
        self.assertEqual(len(self.lines(self.wake)), 6)
        # The same query again under a new call: counted, not told again. A new one: told.
        jl(self.grok, [grok_search('c7', 'Player  of Games factorio stream', t + 3700),
                       grok_search('c8', 'nickwinter factorio', t + 3701)])
        hits = self.scan()
        self.assertEqual([h['text'] for h in hits], ['nickwinter factorio'])
        hours = json.loads((self.op/'search-watch.json').read_text())['hours']['grok']
        self.assertEqual(hours[W.hour(t + 3700)], {'search': 2})
        self.assertEqual(len(self.lines(self.wake)), 7)

    def test_partial_last_line_waits_and_replaced_file_never_double_counts(self):
        t = self.t0 + 60
        jl(self.grok, [grok_search('c1', 'player of games', t)])
        with self.grok.open('a') as f:
            f.write(json.dumps(grok_search('c2', 'nick winter factorio', t + 1))[:40])
        self.assertEqual(len(self.scan()), 1)
        with self.grok.open('a') as f:
            f.write(json.dumps(grok_search('c2', 'nick winter factorio', t + 1))[40:] + '\n')
        self.assertEqual([h['text'] for h in self.scan()], ['nick winter factorio'])
        text = self.grok.read_text()
        self.grok.unlink()
        self.grok.write_text(text)  # replaced (a new inode): read again from the start
        self.assertEqual(self.scan(), [])
        hours = json.loads((self.op/'search-watch.json').read_text())['hours']['grok']
        self.assertEqual(sum(r.get('search', 0) for r in hours.values()), 2)

    def test_report_reads_past_folders_without_writing(self):
        jl(self.grok, [grok_search('c1', 'Factorio belts', self.t0), grok_open('c2', 'https://wiki.factorio.com/Belt', self.t0)])
        folder = self.state['agents']['grok']['folder']
        Path(folder, 'team.txt').write_text('grok|Grok 4.7 (Grok Build)\n')
        rows = W.report([folder])
        self.assertEqual(rows[0]['counts']['grok'], {'search': 1, 'open': 1})
        self.assertEqual([c['text'] for c in rows[0]['calls']], ['Factorio belts', 'https://wiki.factorio.com/Belt'])
        self.assertEqual(rows[0]['hits'], [])
        self.assertFalse((self.op/'search-watch.json').exists())


class Supervisor(unittest.TestCase):
    def test_hook_throttles_and_a_failure_only_alerts(self):
        import full_run
        state = dict(agents={'a': dict(name='a', team='t', kind='grok', folder='/nonexistent')})
        with patch.object(full_run, '_search_at', 0.0), \
                patch.object(full_run.search_watch, 'scan_run', side_effect=RuntimeError('bad log')) as scan, \
                patch.object(full_run, 'alert') as alert:
            full_run.searches(Path('/unused'), state)
            full_run.searches(Path('/unused'), state)
            self.assertEqual(scan.call_count, 1, 'once a minute')
            full_run.searches(Path('/unused'), state, force=True)
            self.assertEqual(scan.call_count, 2, 'the end scan is not throttled')
            self.assertEqual([c.args[1] for c in alert.call_args_list], ['search-watch-error'] * 2)
            with patch.dict(os.environ, {'POG_SEARCH_WATCH': '0'}):
                full_run.searches(Path('/unused'), state, force=True)
            self.assertEqual(scan.call_count, 2, 'off')


if __name__ == '__main__':
    unittest.main()
