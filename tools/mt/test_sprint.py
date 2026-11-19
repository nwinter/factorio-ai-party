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
             'windows': [{'key': 'weekly_all:Weekly', 'label': 'Weekly', 'percent': 1.0, 'duration_minutes': 10080}]}]}
        a = meter.accounts(brief, now)
        self.assertEqual(a['grok']['windows']['grok:weekly']['percent'], 10.0)
        self.assertAlmostEqual(a['grok']['windows']['grok:weekly']['used_usd'], round(0.10 * 300 / 4.333, 2))
        self.assertIsNone(a['muse']['windows']['muse:10080']['percent'])
        self.assertNotIn('claude_account_b', json.dumps(a))


if __name__ == '__main__':
    unittest.main()
