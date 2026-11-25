"""(mt309) The bake-off sprint tools: the fixed score, spawn rotation, burn conversion and the meter."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import meter
import sprint


def row(tick, research=(), entities=None, produced=None):
    return {'t': 'x', 'score': {'tick': tick, 'research_done': list(research), 'entities': entities or {}, 'produced': produced or {}}}


class Score(unittest.TestCase):
    def test_version_is_fixed(self):
        # Stage 1 runs are scored with version 1; a formula change must raise SCORE_VERSION, never re-score.
        self.assertEqual(sprint.SCORE_VERSION, 1)
        self.assertEqual([g[0] for g in sprint.GATES], ['power', 'automation', 'automated-red-science', 'military',
                                                        'turret', 'green-science', 'pumpjack', 'oil-processing'])

    def test_nothing_done_scores_zero(self):
        s = sprint.score_rows([row(1000), row(1000 + 90 * 3600)], 1000, 90)
        self.assertEqual(s['total'], 0.0)
        self.assertFalse(s['basic_automation'])

    def test_gates_time_and_rate(self):
        t0 = 5000
        rows = [row(t0),
                row(t0 + 10 * 3600, entities={'steam-engine': 1}),
                row(t0 + 30 * 3600, research=['automation'], entities={'steam-engine': 1}),
                row(t0 + 60 * 3600, research=['automation'], entities={'steam-engine': 1, 'lab': 1, 'assembling-machine-1': 2},
                    produced={'automation-science-pack': 25, 'iron-plate': 1000, 'copper-plate': 500}),
                row(t0 + 90 * 3600, research=['automation', 'military'], entities={'steam-engine': 1, 'lab': 1,
                    'assembling-machine-1': 2, 'electric-mining-drill': 4},
                    produced={'automation-science-pack': 60, 'iron-plate': 3000, 'copper-plate': 1500}),
                row(t0 + 95 * 3600, research=['automation', 'military', 'logistic-science-pack'])]   # after the end
        s = sprint.score_rows(rows, t0, 90)
        self.assertEqual(s['gates'], {'power': 10.0, 'automation': 30.0, 'automated-red-science': 60.0, 'military': 90.0})
        self.assertTrue(s['basic_automation'])
        self.assertEqual(s['plates_per_min'], 100.0)     # 3,000 plates in the last 30 minutes
        self.assertEqual(s['research'], 2)
        gates = 40 + 5 * ((1 - 10 / 90) + (1 - 30 / 90) + (1 - 60 / 90) + 0)
        self.assertAlmostEqual(s['points']['gates'], round(gates, 1))
        self.assertEqual(s['points']['drills'], 4)

    def test_hand_crafted_science_is_not_automated(self):
        rows = [row(0), row(3600 * 20, research=['automation'], entities={'lab': 1}, produced={'automation-science-pack': 50})]
        self.assertNotIn('automated-red-science', sprint.score_rows(rows, 0, 90)['gates'])


class Plan(unittest.TestCase):
    ARMS = [dict(arm=a, kind=k, route=r, model=m, effort='medium', label=a, harness=h) for a, k, r, m, h in (
        ('opus', 'claude', 'claude', 'opus', 'Claude Code'), ('sonnet', 'claude', 'claude', 'sonnet', 'Claude Code'),
        ('neon', 'agy', '-', 'gemini-4-neon-medium', 'Antigravity'), ('carbon', 'agy', '-', 'gemini-4-carbon-medium', 'Antigravity'),
        ('flash', 'agy', '-', 'gemini-3.8-flash-high', 'Antigravity'), ('grok', 'grok', '-', 'grok-4.7', 'Grok Build'),
        ('muse', 'muse', '-', 'muse-spark-1.3', 'Muse Code'))]

    def test_accounts_kept_apart_and_spawns_rotated(self):
        runs = sprint.plan_runs(self.ARMS, 3)
        self.assertEqual(len(runs), 3)
        self.assertEqual(sorted(a['arm'] for r in runs for a in r), sorted(a['arm'] for a in self.ARMS))
        for r in runs:
            accts = [sprint.account(a) for a in r]
            self.assertEqual(len(accts), len(set(accts)), r)       # 3 agy arms over 3 runs: one each
            self.assertEqual(len({a['team'] for a in r}), len(r))
        self.assertEqual([a['team'] for a in runs[1]][:1], ['yellow'])   # run 2's first slot moves on one spawn

    def test_gray_swan_refused(self):
        with tempfile.NamedTemporaryFile('w', suffix='.tsv', delete=False) as f:
            f.write('x\tclaude\tclaude-b\topus\tmedium\tOpus\tClaude Code\n')
        with self.assertRaises(AssertionError):
            sprint.read_arms(f.name)


    def test_codex_turn_end_from_its_rollout(self):
        import full_run
        with tempfile.TemporaryDirectory() as tmp:
            home, folder = Path(tmp)/'home', Path(tmp)/'runs'
            (home/'sessions/2026').mkdir(parents=True); (folder/'astra').mkdir(parents=True)
            ws = os.path.abspath(folder/'astra')
            ev = lambda t, kind: json.dumps(dict(timestamp=t, type='event_msg', payload=dict(type=kind)))
            f = home/'sessions/2026/rollout-x.jsonl'
            f.write_text(json.dumps(dict(type='session_meta', payload=dict(cwd=ws))) + '\n' + ev('2026-11-22T01:44:20.000Z', 'task_started')
                         + '\n' + ev('2026-11-22T01:51:59.000Z', 'task_complete') + '\n')
            a = dict(kind='codex', folder=str(folder), name='astra', started=0)
            done = 1795312319.0
            idle = lambda screen, now: full_run.codex_idle(a, screen, now, home=home)
            self.assertTrue(idle('› Ask Codex to do anything', done + 130))
            self.assertFalse(idle('› Ask Codex to do anything', done + 60))           # under 120 s
            a['nudge_s'] = 20                                                           # note-mt309-p
            self.assertTrue(idle('› Ask Codex to do anything', done + 25))
            self.assertFalse(idle('› Ask Codex to do anything', done + 10))
            a['nudge_s'] = 120
            self.assertFalse(idle('• Working (11s • esc to interrupt)', done + 130))   # a turn running
            with f.open('a') as g:
                g.write(ev('2026-11-22T02:02:13.000Z', 'task_started') + '\n')
            self.assertFalse(idle('› Ask Codex to do anything', done + 900))           # a new turn began

    def test_codex_window_limit_ends_a_codex_sprint(self):
        acc = lambda pct: {'codex': {'windows': {'codex:10080:primary': {'percent': pct}}}}
        codex, grok = [dict(kind='codex', arm='astra')], [dict(kind='grok', arm='grok')]
        self.assertIsNone(sprint.codex_at_limit(acc(98.0), codex))
        self.assertEqual(sprint.codex_at_limit(acc(99.0), codex), 'codex codex:10080:primary at 99.0%')
        self.assertIsNone(sprint.codex_at_limit(acc(100.0), grok))
        self.assertIsNone(sprint.codex_at_limit({'error': 'x'}, codex))

    def test_meter_check_keeps_only_the_roster_accounts(self):
        # (note-mt309-t) Grok and Muse are out: a check of the three arms logs their accounts only
        import meter as M
        w = lambda p: {'windows': {'k': {'percent': p}}}
        real = M.accounts; M.accounts = lambda: {'claude': w(61), 'codex': w(65), 'agy': w(6), 'grok': w(3), 'muse': w(5)}
        try:
            with tempfile.TemporaryDirectory() as t:
                st = dict(roster=[dict(kind='agy', route='-'), dict(kind='codex', route='codex'), dict(kind='claude', route='claude')])
                acc = sprint.meter_check(Path(t), st)
                self.assertEqual(set(acc), {'claude', 'codex', 'agy'})
                logged = json.loads((Path(t)/'meter-checks.jsonl').read_text())['accounts']
                self.assertEqual(set(logged), {'claude', 'codex', 'agy'})
        finally:
            M.accounts = real

    def test_two_agents_on_one_force(self):
        row = lambda t, n: dict(team=t, arm=n)
        sprint.check_roster([row('green', 'hydrogen'), row('green', 'grok')])
        for bad in ([row('green', 'a'), row('green', 'b'), row('green', 'c')], [row('red', 'a')],
                    [row('green', n) for n in 'ab'] + [row('blue', 'c'), row('yellow', 'd')]):
            with self.assertRaises(AssertionError):
                sprint.check_roster(bad)


class Burn(unittest.TestCase):
    def test_claude_list_dollars_and_percent(self):
        tok = dict(input=10_000_000, cache_read=9_000_000, cache_write=500_000, output=100_000)
        m = sprint.meter('claude', 'claude', 'claude-opus-5-5', tok)
        usd = (500_000 * 4 + 100_000 * 20 + 500_000 * 5 + 9_000_000 * 0.20) / 1e6
        self.assertAlmostEqual(m['list_usd'], round(usd, 2))
        self.assertAlmostEqual(m['pct']['weekly'], round(usd * sprint.CAL['claude']['weekly_pct_per_list_usd'], 3))
        self.assertNotIn('weekly_fable', m['pct'])
        self.assertIn('weekly_fable', sprint.meter('claude', 'claude', 'claude-fable-5-2', tok)['pct'])

    def test_codex_ignores_cached_input(self):
        a = sprint.meter('codex', 'codex', 'gpt-6-astra', dict(input=1_000_000, cache_read=0, cache_write=0, output=0))
        b = sprint.meter('codex', 'codex', 'gpt-6-astra', dict(input=51_000_000, cache_read=50_000_000, cache_write=0, output=0))
        self.assertEqual(a['pct'], b['pct'])
        self.assertIsNone(a['plan_usd'])           # tier unknown: no guessed price
        self.assertEqual(set(a['plan_usd_if']), {'100', '200', '500'})

    def test_other_clis_have_no_token_calibration(self):
        self.assertIsNone(sprint.meter('grok', '-', 'grok-4.7', dict(input=1, cache_read=0, cache_write=0, output=1))['pct'])

    def test_claude_files_by_escaped_workspace(self):
        self.assertEqual(sprint.escaped('/Users/w/code/a.b/runs/r1/opus'), '-Users-w-code-a-b-runs-r1-opus')


class BurnFiles(unittest.TestCase):
    def test_grok_hidden_home_and_agy_brain(self):
        # (s1r1d) Grok's logs sit in the hidden .grok-home, agy's in the CLI home's brain/: both read None before
        import os, time
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); run = t/'tree'/'runs'/'s9'
            g = run/'grok'/'.grok-home'/'logs'; g.mkdir(parents=True)
            (g/'unified.jsonl').write_text(json.dumps({'msg': 'shell.turn.inference_done', 'ts': '2026-11-19T20:00:00Z',
                                                        'ctx': {'prompt_tokens': 100, 'cached_prompt_tokens': 60,
                                                                'completion_tokens': 7}}) + '\n')
            (run/'neon').mkdir()
            conv = t/'agyhome'/'brain'/'c1'/'.system_generated'/'logs'; conv.mkdir(parents=True)
            (conv/'transcript.jsonl').write_text(json.dumps({'type': 'USER', 'content': f'cwd {run}/neon runs/s9/neon'}) + '\n'
                                                 + json.dumps({'type': 'PLANNER_RESPONSE', 'created_at': '2026-11-19T20:00:00Z',
                                                               'input_tokens': 50, 'cache_read_tokens': 30, 'output_tokens': 5}) + '\n')
            sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'stream'))
            import tokens as T
            old = os.environ.get('POG_TOKEN_ROOTS'); os.environ['POG_TOKEN_ROOTS'] = json.dumps({'agy': [str(t/'agyhome')]}); T._roots = None
            try:
                gt = sprint.arm_tokens('grok', sprint.arm_files('grok', '-', run/'grok', start=time.time() - 3600))
                at = sprint.arm_tokens('agy', sprint.arm_files('agy', '-', run/'neon', start=time.time() - 3600))
            finally:
                T._roots = None
                os.environ.pop('POG_TOKEN_ROOTS') if old is None else os.environ.__setitem__('POG_TOKEN_ROOTS', old)
            self.assertEqual((gt['calls'], gt['input'], gt['cache_read'], gt['output']), (1, 100, 60, 7))
            self.assertEqual((at['calls'], at['input'], at['cache_read'], at['output']), (1, 80, 30, 5))


class Meter(unittest.TestCase):
    def test_delta_adds_across_a_reset(self):
        series = [(0, 10, 1000), (100, 14, 1000), (200, 2, 900000), (300, 5, 900000)]
        self.assertEqual(meter.delta(series), 4 + 2 + 3)
        self.assertIsNone(meter.delta(series[:1]))

    def test_stale_is_unknown_and_gray_swan_absent(self):
        now = 10_000
        brief = {'profiles': [
            {'id': 'grok_personal', 'available': True, 'stale': False, 'observed_at': now - 100,
             'windows': [{'key': 'grok:weekly', 'label': 'Grok · Weekly', 'percent': 10.0, 'duration_minutes': 10080}]},
            {'id': 'muse_local', 'available': True, 'stale': False, 'observed_at': now - 5000,
             'windows': [{'key': 'muse:10080', 'label': 'Muse · Weekly', 'percent': 3.0, 'duration_minutes': 10080}]},
            {'id': 'claude_account_b', 'available': True, 'stale': False, 'observed_at': now,
             'windows': [{'key': 'weekly_all:Weekly', 'label': 'Weekly', 'percent': 1.0, 'duration_minutes': 10080}]},
            # (mt308 05fe2c753) another host's row (id NAME@HOST), listed after this Mac's: never this Mac's agents
            {'id': 'muse_local@work-laptop', 'command': 'muse', 'available': True, 'stale': False, 'observed_at': now,
             'windows': [{'key': 'muse:10080', 'label': 'Muse · Weekly', 'percent': 77.0, 'duration_minutes': 10080}]}]}
        a = meter.accounts(brief, now)
        self.assertEqual(a['grok']['windows']['grok:weekly']['percent'], 10.0)
        self.assertNotIn('77.0', json.dumps(a))
        self.assertAlmostEqual(a['grok']['windows']['grok:weekly']['used_usd'], round(0.10 * 300 / 4.333, 2))
        self.assertIsNone(a['muse']['windows']['muse:10080']['percent'])
        self.assertNotIn('claude_account_b', json.dumps(a))


class ServerBackup(unittest.TestCase):
    def test_backup_restore_round_trip(self):
        import subprocess, server_backup
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/'pog-mt21'
            (root/'saves').mkdir(parents=True); (root/'mods').mkdir(); (root/'config').mkdir()
            (root/'saves'/'mt.zip').write_bytes(b'prior'); (root/'mods'/'a.zip').write_bytes(b'm')
            (root/'server-settings.json').write_text('{}'); (root/'saves'/'old.zip').write_bytes(b'o')
            script = server_backup.REMOTE.replace(repr(server_backup.MT_DIR), repr(str(root)))
            run = lambda *a: json.loads(subprocess.run([sys.executable, '-', *a], input=script, capture_output=True,
                                                       text=True, check=True).stdout.splitlines()[-1])
            self.assertEqual(run('backup', 'eng-x')['entries'], 7)   # mt.zip, mods, mods/a.zip, config, settings, 2 absent
            (root/'saves'/'mt.zip').write_bytes(b'run'); (root/'saves'/'s1r1.zip').write_bytes(b'r')
            (root/'mods'/'a.zip').write_bytes(b'changed')
            self.assertFalse(run('verify', 'eng-x')['same'])
            self.assertEqual(run('new-saves', 'eng-x')['new'], ['s1r1.zip'])
            res = run('restore', 'eng-x')
            self.assertEqual(res['removed_saves'], ['s1r1.zip'])
            self.assertEqual((root/'saves'/'mt.zip').read_bytes(), b'prior')
            self.assertTrue((root/'saves'/'old.zip').exists())
            self.assertTrue(run('verify', 'eng-x')['same'])


class CodexHome(unittest.TestCase):
    def test_init_trust_archive(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        import codex_pog_home as c
        with tempfile.TemporaryDirectory() as t:
            h = Path(t)/'h'/'home'
            st = c.init(h)
            self.assertTrue(st['file_store']); self.assertFalse(st['logged_in'])
            c.trust(h, '/x/y'); c.trust(h, '/x/y')
            self.assertEqual((h/'config.toml').read_text().count('[projects."/x/y"]'), 1)
            (h/'sessions'/'2026'/'11').mkdir(parents=True); (h/'sessions'/'2026'/'11'/'r.jsonl').write_text('{}')
            c.archive(h, Path(t)/'dest')
            self.assertTrue((Path(t)/'dest'/'2026'/'11'/'r.jsonl').exists())
            self.assertEqual(list((h/'sessions').iterdir()), [])

    def test_scope_allows_pog_home_not_owner_codex(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('agent_scope', Path(__file__).resolve().parents[1]/'agent-scope.py')
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as t:
            home = Path(t); pog = home/'.pog-codex'/'home'
            prof = m.profile(home/'tree', home, None, None, pog)
            self.assertIn(str(pog.resolve()), prof)
            self.assertIn(f'(subpath "{home/".codex"}")', prof)      # the owner's Codex home stays denied


    def test_scope_for_a_team_agy_home(self):
        # (note-mt309-y) a team agy home: no keychain, the owner's agy folders closed after the allows, no browser
        import importlib.util, os
        spec = importlib.util.spec_from_file_location('agent_scope', Path(__file__).resolve().parents[1]/'agent-scope.py')
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as t:
            home = Path(t); team = home/'.pog-agy'/'green'
            prof = m.profile(home/'tree', home, None, None, None, False, team)
            self.assertIn(str(team.resolve()), prof)
            gem = f'(deny file-read* file-write* (subpath "{home/".gemini"}"))'
            self.assertIn(gem, prof); self.assertGreater(prof.index(gem), prof.index(str(team.resolve())))
            self.assertIn('(global-name "com.apple.SecurityServer")', prof)
            self.assertIn('(deny process-exec (literal "/usr/bin/open"))', prof)
            plain = m.profile(home/'tree', home, None, None, None, True)
            self.assertNotIn(gem, plain); self.assertNotIn('com.apple.SecurityServer', plain)
        old = os.environ.get('POG_AGY_HOME')
        try:
            os.environ.pop('POG_AGY_HOME', None); self.assertIsNone(m.agy_home())
            os.environ['POG_AGY_HOME'] = '/tmp/x'; self.assertEqual(m.agy_home(), Path('/tmp/x').resolve())
        finally:
            os.environ.pop('POG_AGY_HOME', None)
            if old is not None:
                os.environ['POG_AGY_HOME'] = old

class TrustPrompt(unittest.TestCase):
    def test_enter_only_once_yes_is_highlighted(self):
        # (s1r1c) a "down" that lands late must not let Enter answer Claude Code's "No, exit"
        import os, subprocess
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); (t/'bin').mkdir(); (t/'ws').mkdir()
            herdr = t/'bin'/'herdr'
            herdr.write_text(f'''#!/bin/sh
echo "$@" >> '{t}/log'
if [ "$2" = read ]; then
  n=$(grep -c "send-keys .* down" '{t}/log'); r=$(grep -c " read " '{t}/log')
  if [ "$n" -gt 0 ] && [ "$r" -ge 5 ]; then printf '%s\\n' ' Quick safety check' '   No, exit' ' ❯ Yes, I trust this folder'
  else printf '%s\\n' ' Quick safety check' ' ❯ No, exit' '   Yes, I trust this folder'; fi
fi
exit 0
''')
            herdr.chmod(0o755)
            r = subprocess.run([str(root/'tools/clear-prompts.sh'), '10', 'w9:p1', str(t/'ws')], capture_output=True, text=True,
                               timeout=30, env=dict(os.environ, PATH=f"{t/'bin'}:{os.environ['PATH']}"))
            self.assertEqual(r.stdout, 'w9:p1 trust\n')
            keys = [l for l in (t/'log').read_text().splitlines() if 'send-keys' in l]
            self.assertEqual(keys, ['pane send-keys w9:p1 down', 'pane send-keys w9:p1 enter'])
            lines = (t/'log').read_text().splitlines()
            self.assertGreaterEqual(sum(' read ' in l for l in lines[:lines.index('pane send-keys w9:p1 enter')]), 5)


class PlayerScopeSkills(unittest.TestCase):
    def test_personal_skills_and_tooling_notes_refused(self):
        # (s1r1d/s1r2) Grok listed and Muse sent its model Nick's ~/.agents/skills; agy has an always-on tooling rule
        import importlib.util, subprocess
        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location('agent_scope', root/'tools/agent-scope.py')
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        home = Path.home()
        agents = (home/'.profiles/agents').resolve()
        with tempfile.TemporaryDirectory(dir=root.parent) as t:
            t = Path(t).resolve(); (t/'own.txt').write_text('x')
            prof = t/'scope.sb'; prof.write_text(m.profile(t, home))
            run = lambda path: subprocess.run(['/usr/bin/sandbox-exec', '-f', str(prof), '/bin/cat', str(path)],
                                              capture_output=True, text=True).returncode
            self.assertEqual(run(t/'own.txt'), 0)
            for p in (home/'.agents/skills/lifelog/SKILL.md', agents/'skills/herdr/SKILL.md', agents/'README.md',
                      home/'.claude/skills/lifelog/SKILL.md', home/'.gemini/antigravity-cli/rules/agent-tooling.md'):
                if p.exists():
                    self.assertNotEqual(run(p), 0, p)
            tool = next((agents/'bin').iterdir(), None) if (agents/'bin').is_dir() else None
            if tool and tool.is_file():
                self.assertEqual(run(tool), 0, tool)        # ~/.local/bin's links into bin/ still work

    def test_muse_gets_a_home_without_user_skills(self):
        # (s2a) Muse read $HOME/.agents/skills and $HOME/.claude/skills on start and died on the deny's EPERM
        import importlib.util, shutil
        home = Path.home()
        if not (home/'.config/muse/auth.json').exists():
            self.skipTest('no Muse login on this machine')
        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location('agent_scope', root/'tools/agent-scope.py')
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as t:
            env = m.native_environment({'PATH': '/usr/bin:/bin'}, Path(t), home, muse=True)
            native = Path((Path(t)/'.native-root').read_text().strip())
            try:
                own = Path(env['HOME'])
                self.assertEqual(own, native/'home')
                self.assertEqual(sorted(p.name for p in own.iterdir()), ['Library'])
                self.assertEqual((own/'Library/Keychains').resolve(), (home/'Library/Keychains').resolve())
                self.assertFalse((own/'.agents').exists() or (own/'.claude').exists())
                self.assertEqual(env['POG_MUSE_BIN'], str(home/'.local/bin/muse'))
                self.assertTrue(env['PATH'].startswith(str(home/'.local/bin')))
            finally:
                shutil.rmtree(native)


class IdlePrompt(unittest.TestCase):
    def test_idle_and_silent_arms_prompted_busy_not(self):
        # (s1r1d) Grok ended its turn at minute 46 and nothing asked it to go on
        import os, time
        class Panes:
            def __init__(self, st, scr): self.st, self.scr, self.sent = st, scr, []
            def status(self, pane): return self.st[pane]
            def read(self, pane): return self.scr[pane]
            def prompt(self, pane, text): self.sent.append((pane, text)); return 'agent prompt', True, ''
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); op = t/'op'; op.mkdir(); now = time.time()
            ws = {}
            for team, arm, age in (('green', 'idle', 300), ('yellow', 'working', 30), ('blue', 'muse', 700), ('red', 'busy', 700)):
                d = t/team/'runs'/'s9'; (d/arm).mkdir(parents=True); j = d/arm/'journal.jsonl'; j.write_text('{}')
                os.utime(j, (now - age, now - age)); ws[team] = {'tree': str(t/team), 'dir': str(d)}
            (op/'workspaces.json').write_text(json.dumps(ws))
            (op/'panes.txt').write_text('green idle p1 claude\nyellow working p2 agy\nblue muse p3 muse\nred busy p4 muse\n')
            roster = [dict(team=tm, arm=a, kind=k) for tm, a, k in (('green', 'idle', 'claude'), ('yellow', 'working', 'agy'),
                                                                      ('blue', 'muse', 'muse'), ('red', 'busy', 'muse'))]
            state = dict(roster=roster, start_at=now - 3600, nudge_s=120)   # the 120 s nudge of Stage 1 and 2
            panes = Panes({'p1': 'idle', 'p2': 'working', 'p3': 'working', 'p4': 'working'},
                          {'p1': '> ', 'p2': '', 'p3': '> ', 'p4': 'esc to interrupt'})
            sprint.idle_prompts(op, state, panes, now)
            self.assertEqual(sorted(p for p, _ in panes.sent), ['p1', 'p3'])
            self.assertNotIn('teammate', panes.sent[0][1])
            sprint.idle_prompts(op, state, panes, now + 60)          # no second prompt within 180 s
            self.assertEqual(len(panes.sent), 2)
            self.assertEqual(len((op/'idle-prompts.jsonl').read_text().splitlines()), 2)
            # (note-mt309-p) a 20 s nudge: 'working' (journal quiet 30 s) is prompted once idle, and the gap between
            # two prompts to one arm is 30 s
            state20 = dict(roster=roster[:2], start_at=now - 3600, nudge_s=20)
            panes20 = Panes({'p1': 'idle', 'p2': 'idle'}, {'p1': '> ', 'p2': '> '})
            sprint.idle_prompts(op, state20, panes20, now)
            self.assertEqual(sorted(p for p, _ in panes20.sent), ['p1', 'p2'])
            sprint.idle_prompts(op, state20, panes20, now + 20)
            self.assertEqual(len(panes20.sent), 2)
            sprint.idle_prompts(op, state20, panes20, now + 31)
            self.assertEqual(len(panes20.sent), 4)
            # (note-mt309-t) 20 s is the default: a run made without --nudge-s nudges as state20 does
            self.assertEqual(sprint.NUDGE_S, 20)

    def test_a_sprint_arm_is_prompted_by_the_sprint_only(self):
        # (note-mt309-z7) ct2: full_run's watch prompted Astra too (16 of its 34 prompts within 15 s of one of the
        # sprint's). The sprint's environment turns the watch's pane prompt and its game-tell nudge off.
        import time, unittest.mock as um, full_run
        self.assertEqual(sprint.SPRINT_PROMPTS, {'POG_IDLE_NUDGE': '0', 'POG_PANE_PROMPT': '0'})
        self.assertIn('POG_PANE_PROMPT', full_run.ENV_KEYS)     # kept in full-env.json for a resumed watch
        with tempfile.TemporaryDirectory() as t:
            a = dict(name='astra', folder=t, kind='codex', pane='p', started=0, restarts=0)
            def watched(env):
                panes = um.Mock(); panes.read.return_value = '> '; panes.status.return_value = 'idle'
                panes.prompt.return_value = ('agent prompt', True, '')
                with um.patch.dict('os.environ', env), um.patch.object(full_run, 'live_client', return_value=True), \
                     um.patch.object(full_run, 'event'), um.patch.object(full_run, 'alert'):
                    full_run.watch_agent(Path(t), dict(agents={'astra': a}), dict(a), time.time(), panes, {}, {})
                return panes.prompt.call_count
            self.assertEqual(watched({}), 1)                       # a full run: the watch prompts an idle pane
            self.assertEqual(watched(sprint.SPRINT_PROMPTS), 0)    # a sprint: never

    def test_codex_subagents_logged_and_in_the_burn(self):
        # (note-mt309-t) spawn_agent stays allowed: each sub-agent rollout is woken once and its tokens count
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); op = t/'runs'/'s9'/'op'; op.mkdir(parents=True); d = t/'runs'/'s9'; (d/'astra').mkdir()
            ws = os.path.abspath(d/'astra')
            (op/'workspaces.json').write_text(json.dumps({'yellow': {'dir': str(d)}}))
            sess = op/'codex-sessions'/'2026'; sess.mkdir(parents=True)
            tok = lambda n: json.dumps(dict(type='token_usage_record', timestamp='2026-11-22T20:00:00.000Z', payload=dict(
                response_id=f'r{n}', usage=dict(input_tokens=n, cached_input_tokens=0, output_tokens=10))))
            (sess/'rollout-main.jsonl').write_text(json.dumps(dict(type='session_meta', payload=dict(cwd=ws))) + '\n' + tok(1000) + '\n')
            state = dict(roster=[dict(team='yellow', arm='astra', kind='codex', route='codex')])
            woke = []
            real, sprint.wake = sprint.wake, woke.append
            try:
                self.assertEqual(sprint.codex_subagents(op, state), {'astra': 0})
                (sess/'rollout-sub.jsonl').write_text(json.dumps(dict(type='session_meta', payload=dict(
                    cwd=ws, thread_source='subagent'))) + '\n' + tok(500) + '\n')
                self.assertEqual(sprint.codex_subagents(op, state), {'astra': 1})
                self.assertEqual(sprint.codex_subagents(op, state), {'astra': 1})     # woken once
            finally:
                sprint.wake = real
            self.assertEqual(len(woke), 1); self.assertIn('astra started 1 Codex sub-agent', woke[0])
            files = sprint.arm_files('codex', 'codex', d/'astra', extra=[op/'codex-sessions'])
            tk = sprint.arm_tokens('codex', files)
            self.assertEqual(tk['subagents'], 1); self.assertEqual(tk['files'], 2)
            self.assertEqual((tk['input'], tk['output']), (1500, 20))     # the sub-agent's tokens in the arm's


class Stage2(unittest.TestCase):
    def test_contact_plan_has_a_nest_in_every_corridor(self):
        # (note-mt309-t) each team: a half nest and a field on the bearing to each neighbour, the same gaps from its
        # base box on every bearing; between.py's corridor (30 degrees of the bearing, nearer than the neighbour)
        import math, stage2_save as S
        S.MAP = 'contact'
        try:
            p = S.plan(); lay = json.loads(S.LAYOUTS['contact'].read_text())
        finally:
            S.MAP = 'stage2'
        T = p['teams']; D = lay['distance']
        self.assertEqual((D, lay['home'], lay['middle']), (S.CONTACT_D, 'toward', False))
        ores = []
        for a, t in T.items():
            self.assertEqual(len(t['nests']), 2); self.assertEqual(len(t['spawners']), 4); self.assertEqual(len(t['worms']), 4)
            for b, d in t['distances'].items():
                self.assertEqual((d['nest_gap'], d['field'] - d['nest']), (S.CONTACT_NEST_GAP, S.CONTACT_FIELD_PAST))
            for k, nest in enumerate(t['nests']):
                f = t['field'][k]; b = f['toward']; sb = T[b]['spawn']
                bear = math.atan2(sb[1] - t['spawn'][1], sb[0] - t['spawn'][0])
                for pt in (nest, f['at']):
                    off = abs((math.degrees(math.atan2(pt[1] - t['spawn'][1], pt[0] - t['spawn'][0]) - bear) + 180) % 360 - 180)
                    self.assertLess(off, 1); self.assertLess(math.dist(pt, t['spawn']), D / 2)
                for n, x, y in t['spawners'][2*k:2*k + 2] + t['worms'][2*k:2*k + 2]:
                    self.assertLessEqual(math.dist((x, y), nest), p['nest_r'])
                mid = ((t['spawn'][0] + sb[0]) / 2, (t['spawn'][1] + sb[1]) / 2)
                self.assertGreater(math.dist(f['at'], mid), f['r'] + 140)      # clear of the shared site (r 20, e 40)
                self.assertGreater(math.dist(f['at'], t['spawn']) - f['r'], p['clear_ore_r'])
                ores.append(f['name'])
        self.assertEqual(sorted(ores), ['copper-ore'] * 3 + ['iron-ore'] * 3)
        self.assertEqual({x['toward'] for x in T['green']['field']}, {'yellow', 'blue'})
        self.assertEqual(p['clear_ore'], ['iron-ore', 'copper-ore', 'crude-oil'])

    def test_ct3_each_team_holds_the_only_supply_of_the_other_s_ore(self):
        # (note-mt309-z7) two teams on ct2's map: corridors either side of the line between the starts, every field
        # and base ore cell of the team's own ore, the other's lacking; the shared site has no iron or copper
        import math, stage2_save as S
        S.MAP = 'ct3'
        try:
            p = S.plan(); lay = json.loads(S.LAYOUTS['ct3'].read_text())
            bases = {n: S.team_base(p, n) for n in p['teams']}
        finally:
            S.MAP = 'stage2'
        T = p['teams']
        self.assertEqual(sorted(T), ['blue', 'green'])
        self.assertEqual(math.dist(T['green']['spawn'], T['blue']['spawn']), S.CT2_D)
        self.assertEqual([q['name'] for s in lay['place_sites'] for q in s['patches']], ['coal', 'stone', 'crude-oil'])
        for n, t in T.items():
            own = S.CT3_ORE[n]; other = [o for o in S.CT3_ORE if o != n][0]
            self.assertEqual(t['lacks'], [S.CT3_ORE[other]])
            self.assertEqual({f['name'] for f in t['field']}, {own})
            self.assertEqual({o[0] for o in bases[n]['ores']}, {own, 'coal'})
            kit = dict(bases[n]['kit']); self.assertEqual(kit[S.PLATE[own]], 600); self.assertNotIn(S.PLATE[S.CT3_ORE[other]], kit)
            o = T[other]['spawn']; bear = math.atan2(o[1] - t['spawn'][1], o[0] - t['spawn'][0])
            offs = sorted(round((math.degrees(math.atan2(x[1] - t['spawn'][1], x[0] - t['spawn'][0]) - bear) + 180) % 360 - 180)
                          for x in t['nests'])
            self.assertEqual(offs, [-S.CT3_SPREAD, S.CT3_SPREAD])
            for x in t['nests']:     # the straight route between the starts passes 70+ tiles from every nest
                v = abs(-(x[0] - t['spawn'][0]) * math.sin(bear) + (x[1] - t['spawn'][1]) * math.cos(bear))
                self.assertGreater(v, 70)
            for d in t['distances'].values():
                self.assertEqual(d['nest_gap'], S.CONTACT_NEST_GAP)
        # the fields a team must keep are the placed ones, by team
        self.assertEqual(sorted(k['what'] for k in p['ct3']['keep_ore']), ['blue field iron-ore'] * 2 + ['green field copper-ore'] * 2)
        self.assertEqual(p['ct3']['no_autoplace'], ['copper-ore', 'iron-ore'])

    def test_agy_neon_meter(self):
        # (note-mt309-y) Neon's Gemini week from output tokens; other Gemini models stay uncalibrated
        tok = dict(input=5_000_000, cache_read=4_000_000, cache_write=0, output=1_000_000)
        m = sprint.meter('agy', '-', 'gemini-4-neon-medium', tok)
        self.assertEqual(m['pct'], {'gemini_weekly': 6.76}); self.assertEqual(m['pct_range'], [5.75, 8.05])
        self.assertIsNone(sprint.meter('agy', '-', 'gemini-4-hydrogen-medium', tok)['pct'])

    def test_ct2_plans(self):
        # (note-mt309-y) ct2: starts CT2_D apart, the corridor design unchanged, each corridor's cleared ground short
        # of the shared sites; the shortage build changes one field per team, so each lacks an ore a neighbour holds
        import math, stage2_save as S
        plans = {}
        for m in ('contact', 'ct2', 'ct2-shortage'):
            S.MAP = m
            try:
                plans[m] = S.plan(); lay = json.loads(S.LAYOUTS[m].read_text())
            finally:
                S.MAP = 'stage2'
            if m != 'contact':
                self.assertEqual(lay['distance'], S.CT2_D)
        base, short = plans['ct2']['teams'], plans['ct2-shortage']['teams']
        lay = json.loads(S.LAYOUTS['ct2'].read_text())
        sites = [(si['x'] + q['dx'], si['y'] + q['dy'], q.get('r', 3)) for si in lay['place_sites'] for q in si['patches']]
        for n, t in base.items():
            for b, d in t['distances'].items():
                self.assertEqual((d['nest_gap'], d['field'] - d['nest']), (S.CONTACT_NEST_GAP, S.CONTACT_FIELD_PAST))
                self.assertLessEqual(d['corridor_end'], d['field'] + 18 + 30)
            for f in t['field']:      # 10+ tiles between a corridor field and any shared-site patch
                self.assertGreater(min(math.dist(f['at'], (x, y)) - r for x, y, r in sites) - f['r'], 10)
            for c in t['corridors']:
                b = math.radians(c['bearing'] + 180)
                self.assertLessEqual(-c['u2'], S.site_edge(t['spawn'], b, c['half']) - S.CONTACT_SITE_GAP)
            self.assertNotIn('lacks', t)
        for n, t in plans['contact']['teams'].items():   # ct1's map: the corridors as built
            for c, f in zip(t['corridors'], t['field']):
                self.assertEqual(-c['u2'], round(t['distances'][f['toward']]['field'] + f['r'] + 30))
        ores = lambda t: {f['name'] for f in t['field']}
        for n, t in short.items():
            self.assertEqual(len(t['lacks']), 1); self.assertNotIn(t['lacks'][0], ores(t))
            self.assertTrue(any(t['lacks'][0] in ores(short[o]) for o in {f['toward'] for f in t['field']}))
            self.assertEqual([(f['r'], f['amount'], f['at']) for f in t['field']], [(f['r'], f['amount'], f['at']) for f in base[n]['field']])
            self.assertEqual(sum(f['name'] != g['name'] for f, g in zip(t['field'], base[n]['field'])), 1)
        self.assertEqual({n: t['lacks'] for n, t in short.items()}, {'green': ['copper-ore'], 'yellow': ['iron-ore'], 'blue': ['copper-ore']})
        p = plans['ct2-shortage']
        self.assertEqual(p['shortage_clear_r'], S.SHORTAGE_CLEAR_R); self.assertEqual(len(p['keep_ore']), len(sites) + 6)
        self.assertNotIn('shortage_clear_r', plans['ct2'])

    def test_plan_is_the_same_at_every_spawn(self):
        import math, stage2_save as S
        p = S.plan()
        self.assertEqual(set(p['teams']), {'green', 'yellow', 'blue'})
        for t in p['teams'].values():
            self.assertEqual(t['distances'], {'nest': 150, 'field': 270, 'nest_to_field': 120})
            for n, x, y in t['spawners'] + t['worms']:
                self.assertLessEqual(math.dist((x, y), t['nest']), p['nest_r'])
            for f in t['field']:   # inside the cleared radius, beyond the nest
                self.assertLess(math.dist(f['at'], t['spawn']) + f['r'], p['clear_enemies'])
        self.assertEqual(S.overlaps(p['base']['entities']), [])
        x1, y1, x2, y2 = p['base']['box']
        for n, x, y, d, _ in p['base']['entities']:
            self.assertTrue(x1 + 2 <= x <= x2 - 2 and y1 + 2 <= y <= y2 - 2, (n, x, y))
        # the base's iron and copper last about an hour at the furnaces' 0.3125 ore/s (note-mt309-d)
        per_cell = 20 * p['base']['ore_per_tile']['iron-ore']
        self.assertAlmostEqual(per_cell / 0.3125 / 60, 60, delta=3)

    def test_summary_times_from_the_start_tick(self):
        with tempfile.TemporaryDirectory() as tmp:
            op = Path(tmp)
            rows = [dict(tick=1000 + 3600*m, at=0, green=dict(spawners=s, worms=w, field_drills_working=d,
                         outside_drills_working={}, lost=l, killed=k, characters_lost=c))
                    for m, s, w, d, l, k, c in ((0, 4, 4, 0, 0, 0, 0), (10, 2, 4, 0, 3, 20, 1), (24, 0, 1, 0, 5, 60, 1),
                                                (40, 0, 0, 2, 6, 70, 1))]
            (op/'stage2.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
            out = sprint.stage2_summary(op, dict(start_tick=1000, roster=[dict(team='green', arm='grok')]))
            g = out['grok']
            self.assertEqual((g['nest_cleared_min'], g['second_field_min'], g['lost'], g['characters_lost']), (24.0, 40.0, 6, 1))
            self.assertEqual((g['first_attack_min'], g['spawn']), (10.0, 'near'))
            # drills 0, 0, 0, 2 over gaps of 10, 14, 16 minutes: 2 x 16 drill-minutes, peak 2, 2 at the end
            self.assertEqual((g['field_drills_peak'], g['field_drill_min'], g['field_drills_end']), (2, 32.0, 2))
            pair = sprint.stage2_summary(op, dict(start_tick=1000, roster=[dict(team='green', arm='hydrogen'),
                                                                     dict(team='green', arm='grok')]))
            self.assertEqual(pair['hydrogen+grok']['field_drill_min'], 32.0)
            self.assertEqual(set(pair), {'hydrogen+grok', 'empty-yellow', 'empty-blue'})

    def test_contact_summary_and_first_contact_woken_once(self):
        # (note-mt309-t) each nest's clear, the first contacts and losses by killer; each pair woken once
        with tempfile.TemporaryDirectory() as tmp:
            op = Path(tmp)/'ct9'/'op'; op.mkdir(parents=True)
            g = lambda n1, n2: dict(spawners=n1 + n2, worms=0, nests=[[n1, 0], [n2, 0]], field_drills_working=0,
                                    outside_drills_working={}, lost=1, killed=1, characters_lost=0)
            rows = [dict(tick=1000, green=g(2, 2), first={}), dict(tick=1000 + 3600*30, green=g(0, 2), first={'chart green>yellow': 1000 + 3600*30}),
                    dict(tick=1000 + 3600*90, green=g(0, 0), first={'chart green>yellow': 1000 + 3600*30, 'shot yellow>green': 1000 + 3600*80},
                         losses={'green': {'enemy': 5, 'yellow': 2}})]
            state = dict(start_tick=1000, save='contact', roster=[dict(team='green', arm='opus')])
            (op/'stage2.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
            out = sprint.stage2_summary(op, state)
            self.assertEqual(out['opus']['nests_cleared_min'], [30.0, 90.0]); self.assertEqual(out['opus']['nest_cleared_min'], 90.0)
            self.assertEqual(out['_contacts'], {'chart green>yellow': 30.0, 'shot yellow>green': 80.0})
            self.assertEqual(out['_losses'], {'green': {'enemy': 5, 'yellow': 2}})
            woke = []; real_wake, real_run = sprint.wake, sprint.subprocess.run
            class R: pass
            def fake(cmd, **kw):
                self.assertEqual(cmd[2:5], ['--map', state['save'], 'measure']); r = R(); r.stdout = json.dumps(rows[fake.i]); fake.i += 1; return r
            fake.i = 0
            sprint.wake, sprint.subprocess.run = woke.append, fake
            try:
                for _ in rows:
                    sprint.stage2_measure(op, {}, state)
            finally:
                sprint.wake, sprint.subprocess.run = real_wake, real_run
            self.assertEqual(woke, ['ct9: first contact chart green>yellow at game minute 30.0',
                                    'ct9: ATTACK between teams: first shot yellow>green (damage) at game minute 80.0'])

    def test_contact_wakes_raids_rival_losses_faults_and_integrity(self):
        # (note-mt309-u) wake at any raid or attack between teams and any harness error; stop on an integrity fault
        state = dict(start_tick=0, roster=[dict(team='green'), dict(team='yellow'), dict(team='blue')])
        woke = []; real = sprint.wake; sprint.wake = woke.append
        try:
            row = lambda tick, n, sp=0, fault=None: dict(tick=tick, first={}, losses={'green': {'enemy': 40, 'yellow': n}},
                                                       post_spills=sp, runtime_fault=fault)
            sprint.contact_wakes('ct9', row(3600, 1), state)
            sprint.contact_wakes('ct9', row(7200, 3), state)               # 1 min later: no second row
            sprint.contact_wakes('ct9', row(3600 + 36000, 5, sp=1), state)  # 10 min later, and a Post raided
            sprint.contact_wakes('ct9', row(3600 + 36600, 5, sp=1, fault='boom'), state)
            sprint.contact_wakes('ct9', row(3600 + 37200, 5, sp=1, fault='boom'), state)
        finally:
            sprint.wake = real
        self.assertEqual(woke, ['ct9: green has lost 1 entities to yellow (game minute 1.0)',
                                'ct9: green has lost 5 entities to yellow (game minute 11.0)',
                                'ct9: RAID: a Post was destroyed (1 spill records; game minute 11.0)',
                                'ct9: HARNESS ERROR runtime_fault: boom (game minute 11.2)'])
        with tempfile.TemporaryDirectory() as t:
            op = Path(t); (op/'autosave.log').write_text('save changed during copy; retry next poll\n')
            self.assertIsNone(sprint.integrity_fault(op))
            (op/'autosave.log').write_text('save ZIP CRC failed\n')
            self.assertEqual(sprint.integrity_fault(op), 'autosave: save ZIP CRC failed')

    def test_market_full_at_the_start(self):
        class R: pass
        calls = []
        def fake(cmd, **kw):
            calls.append(cmd[-1]); r = R(); r.stdout = fake.out; return r
        real = sprint.subprocess.run; sprint.subprocess.run = fake
        woke = []; rw = sprint.wake; sprint.wake = woke.append
        try:
            fake.out = '{"profile":"full"}\n'
            self.assertEqual(sprint.market_full('ct9'), {'profile': 'full'})
            self.assertIn('"profile": "full"', calls[0])
            fake.out = 'REFUSED {"ok":false}'
            with self.assertRaises(SystemExit):
                sprint.market_full('ct9')
        finally:
            sprint.subprocess.run, sprint.wake = real, rw
        self.assertIn('market profile full refused', woke[0])


if __name__ == '__main__':
    unittest.main()
