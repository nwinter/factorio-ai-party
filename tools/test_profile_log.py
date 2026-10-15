#!/usr/bin/env python3
"""tools/profile_log.py ranks the harness profiler's server-log lines."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import profile_log  # noqa: E402

P = '  812.345 Script @agent-harness/runtime:30: agent-harness profile '
LOG = '\n'.join([
    'unrelated line',
    P + 'second tick=600 n=2 key=dispatch observe/sleep_check time=Duration: 1.500000ms',
    P + 'second tick=600 n=1 key=event 97 time=Duration: 0.200000ms',
    P + 'second tick=600 n=63 key=* time=Duration: 9.700000ms',
    P + 'second tick=660 n=1 key=dispatch defense time=Duration: 640.000000ms',
    P + 'second tick=660 n=1 key=part board.team time=Duration: 600.000000ms',
    P + 'second tick=660 n=61 key=* time=Duration: 648.000000ms',
    P + 'heap tick=600 kb=40960 grew_kb=3072 fell_kb=0',
    P + 'heap tick=660 kb=20480 grew_kb=1024 fell_kb=21504',
    P + 'total ticks=120 n=2 key=dispatch observe/sleep_check time=Duration: 1.500000ms',
    P + 'total ticks=120 n=1 key=dispatch defense time=Duration: 640.000000ms',
    P + 'total ticks=120 n=1 key=part board.team time=Duration: 600.000000ms',
    P + 'total ticks=120 n=1 key=event 97 time=Duration: 0.200000ms',
    P + 'total ticks=120 n=124 key=* time=Duration: 657.700000ms',
    P + 'done from_tick=600 to_tick=720 (elapsed) keys=5 second_lines=6 dropped=0',
    P + 'second tick=780 n=1 key=dispatch status time=Duration: 0.100000ms',
])


class ProfileLogTest(unittest.TestCase):
    def test_ranks_the_finished_run(self):
        found = profile_log.runs(LOG)
        self.assertEqual(len(found), 2)
        out = profile_log.report(found[0], 20).splitlines()
        self.assertEqual(out[0], 'run from tick 600 to 720 (elapsed) keys=5 second_lines=6 dropped=0')
        self.assertTrue(out[2].startswith('dispatch defense'), out)
        self.assertIn('640.00', out[2])
        self.assertTrue(out[3].startswith('part board.team'))
        self.assertTrue(out[5].startswith('event 97'))
        self.assertNotIn('* ', '\n'.join(out[2:6]))
        self.assertIn('  tick 660: 648.00 ms over 61 calls; dispatch defense 640.00 ms (n=1), part board.team 600.00 ms (n=1); '
                      'heap fell 21.0 MB (a garbage collection finished)', out)
        self.assertIn('  tick 600: 9.70 ms over 63 calls; dispatch observe/sleep_check 1.50 ms (n=2), event 97 0.20 ms (n=1)', out)
        self.assertEqual(out[-1], 'Lua heap: 20.0-40.0 MB, grew 2.00 MB a second; it fell in 1 of 2 seconds: tick 660 (21.0 MB)')

    def test_unfinished_run_sums_its_seconds(self):
        out = profile_log.report(profile_log.runs(LOG)[-1], 5)
        self.assertIn('not finished', out)
        self.assertIn('dispatch status', out)


if __name__ == '__main__':
    unittest.main()
