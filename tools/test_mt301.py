#!/usr/bin/env python3
"""(mt301, private) The end of the game in the operator's views: the harness's mt_game read, new alerts written once
to op/game-alerts.jsonl, the result banner, and an older harness with no mt_game."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools/mt'))
sys.path.insert(0, str(ROOT / 'tools'))
import team_views  # noqa: E402

GAME = {'standings': [{'team': 'red', 'rank': 1, 'milestones': 3, 'of': 21, 'latest': 'chemical-science-pack', 'tick': 9000},
                      {'team': 'blue', 'rank': 2, 'milestones': 1, 'of': 21, 'wiped': True}],
        'teams': {'blue': {'down_since': 4000, 'wiped': {'tick': 40000}}},
        'config': {'target': 'solar-system-edge', 'deadline_tick': 999999},
        'alerts': [{'seq': 1, 'tick': 40000, 'kind': 'wipe', 'team': 'blue', 'text': 'blue is wiped <script>'},
                   {'seq': 2, 'tick': 41000, 'kind': 'wipe_win_pending', 'team': 'red', 'text': 'red has wiped every other team'}],
        'result': None, 'milestones': 21}


class GameViewTest(unittest.TestCase):
    def test_alerts_once_and_banner(self):
        with tempfile.TemporaryDirectory() as op:
            v = team_views.game_view(GAME, op)
            lines = open(os.path.join(op, team_views.ALERTS)).read().splitlines()
            self.assertEqual([json.loads(l)['seq'] for l in lines], [1, 2])
            team_views.game_view(GAME, op)
            self.assertEqual(len(open(os.path.join(op, team_views.ALERTS)).read().splitlines()), 2, 'each alert once')
            more = dict(GAME, alerts=GAME['alerts'] + [{'seq': 3, 'tick': 50000, 'kind': 'game_over', 'text': 'Game over'}],
                        result={'reason': 'wipe', 'tick': 50000, 'text': 'red wiped every other team', 'scores': {'red': 1.5}})
            v = team_views.game_view(more, op)
            self.assertEqual(len(open(os.path.join(op, team_views.ALERTS)).read().splitlines()), 3)
            page = team_views.page({'t': 'now', 'teams': [], 'game': v})
            self.assertIn('GAME OVER at tick 50000 (wipe): red wiped every other team; scores red 1.5', page)
            self.assertIn('blue is wiped &lt;script&gt;', page)
            self.assertIn('<b>WIPED</b>', page)
            self.assertIn('no powered production since tick 4000', page)
            self.assertIn('deadline tick 999999', page)

    def test_collect_reads_mt_game_and_tolerates_an_older_harness(self):
        class Reader:
            def __init__(self, game): self.game = game
            def op(self, action, args=None, team=None):
                if action == 'mt_game':
                    if isinstance(self.game, Exception): raise self.game
                    return self.game
                if action == 'mt_feed': return {'tick': 1, 'lines': []}
                return {}
            def bots(self): return []
            def profiles(self, agent): return []
            def score(self, force): return {}
        with tempfile.TemporaryDirectory() as op:
            Path(op, 'teams.tsv').write_text('')
            view = team_views.collect(Reader(GAME), op)
            self.assertEqual(view['game']['standings'][0]['team'], 'red')
            self.assertNotIn('game', view['errors'])
            view = team_views.collect(Reader(RuntimeError('mt_game: unknown action')), op)
            self.assertEqual(view['game'], {});self.assertNotIn('game', view['errors'])
            view = team_views.collect(Reader(RuntimeError('boom')), op)
            self.assertEqual(view['errors']['game'], 'boom')


if __name__ == '__main__':
    unittest.main()
