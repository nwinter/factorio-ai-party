"""(mt309) The bake-off sprint tools: the fixed score, spawn rotation, burn conversion and the meter."""
import json
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
            state = dict(roster=roster, start_at=now - 3600)
            panes = Panes({'p1': 'idle', 'p2': 'working', 'p3': 'working', 'p4': 'working'},
                          {'p1': '> ', 'p2': '', 'p3': '> ', 'p4': 'esc to interrupt'})
            sprint.idle_prompts(op, state, panes, now)
            self.assertEqual(sorted(p for p, _ in panes.sent), ['p1', 'p3'])
            self.assertNotIn('teammate', panes.sent[0][1])
            sprint.idle_prompts(op, state, panes, now + 60)          # no second prompt within 180 s
            self.assertEqual(len(panes.sent), 2)
            self.assertEqual(len((op/'idle-prompts.jsonl').read_text().splitlines()), 2)


class Stage2(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
