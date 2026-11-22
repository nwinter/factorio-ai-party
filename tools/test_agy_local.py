#!/usr/bin/env python3
"""(mt309) tools/agy-local.py's turn-end cut, against a fake agy that writes a stream and a transcript as agy does.

The fake (probed against agy, Nov 20): init, a tool step ACTIVE, then in the transcript a planner response with the
tool call, a GENERIC RUNNING row and a final planner response without tool calls (the turn ends); the stream holds
the rest back until the background task ends. 'wait' mode never ends it (a long fh --wait); 'short' mode ends it
after 2 s, writes agy's SYSTEM_MESSAGE wake row and a second final response, then a result.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
mode = os.environ['FAKE_MODE']; conv = 'c0ffee'
tr = Path(os.environ['POG_AGY_BRAIN'])/conv/'.system_generated/logs'; tr.mkdir(parents=True, exist_ok=True)
tr = tr/'transcript.jsonl'
def out(row): print(json.dumps(row), flush=True)
def rec(row):
    with tr.open('a') as f: f.write(json.dumps(row) + '\n')
out({'event': 'init', 'conversation_id': conv})
child = subprocess.Popen(['sleep', '60' if mode == 'wait' else '2'])
Path(os.environ['FAKE_CHILD']).write_text(str(child.pid))
out({'event': 'step_update', 'step_update': {'step_index': 2, 'state': 'ACTIVE', 'step_type': 'tool',
     'tool_info': {'parameters': {'CommandLine': './fh call walk --wait'}}}})
rec({'step_index': 1, 'source': 'MODEL', 'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'tool_calls': [{'name': 'run_command'}]})
rec({'step_index': 2, 'source': 'MODEL', 'type': 'GENERIC', 'status': 'RUNNING'})
rec({'step_index': 3, 'source': 'MODEL', 'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'content': 'WAITING'})
child.wait()
out({'event': 'step_update', 'step_update': {'step_index': 2, 'state': 'DONE', 'step_type': 'tool'}})
rec({'step_index': 4, 'source': 'SYSTEM', 'type': 'SYSTEM_MESSAGE', 'status': 'DONE'})
time.sleep(1)
rec({'step_index': 5, 'source': 'MODEL', 'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'content': 'walked'})
out({'event': 'result', 'result': {'status': 'SUCCESS', 'response': 'walked'}})
'''


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # a zombie child of the (ended) fake counts as gone
    return 'Z' not in subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout


class TurnEndCut(unittest.TestCase):
    def run_fake(self, mode, grace='3'):
        tmp = Path(tempfile.mkdtemp()); fake = tmp/'agy'; fake.write_text(FAKE); fake.chmod(0o755)
        ws = tmp/'ws'; ws.mkdir()
        env = dict(os.environ, POG_AGY_BIN=str(fake), POG_AGY_BRAIN=str(tmp/'brain'), FAKE_MODE=mode,
                   FAKE_CHILD=str(tmp/'child'), POG_AGY_IDLE_CUT_S=grace)
        t0 = time.time()
        p = subprocess.run([sys.executable, str(ROOT/'tools/agy-local.py'), '-p', 'go'], cwd=ws, env=env,
                           capture_output=True, text=True, timeout=40)
        took = time.time() - t0
        events = [json.loads(l) for l in (ws/'.agy-events.jsonl').read_text().splitlines()]
        return p, took, events, int((tmp/'child').read_text()), ws

    def test_cut_ends_agy_and_its_background_task(self):
        p, took, events, child, ws = self.run_fake('wait')
        cut = [e['cut'] for e in events if 'cut' in e]
        self.assertEqual(len(cut), 1, events)
        self.assertEqual(cut[0]['background'], ['./fh call walk --wait'])
        self.assertGreaterEqual(cut[0]['waited_s'], 3)
        self.assertLess(took, 15)                       # not the 60 s task
        time.sleep(0.5); self.assertFalse(alive(child))  # the background task went with it
        self.assertIn('ended agy after', p.stderr)
        self.assertEqual(json.loads((ws/'.agy-session.json').read_text())['id'], 'c0ffee')  # -c resumes the same one

    def test_task_inside_grace_is_delivered_without_a_cut(self):
        p, took, events, child, ws = self.run_fake('short', grace='6')
        self.assertFalse([e for e in events if 'cut' in e], events)
        self.assertEqual(p.returncode, 0); self.assertIn('walked', p.stdout)

    def test_zero_turns_the_cut_off(self):
        p, took, events, child, ws = self.run_fake('short', grace='0')
        self.assertFalse([e for e in events if 'cut' in e])


if __name__ == '__main__':
    unittest.main()
