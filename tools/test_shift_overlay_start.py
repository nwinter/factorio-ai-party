#!/usr/bin/env python3
"""batch418: fake-time startup, real shell orchestration, and autopilot's exit contract. No live OBS."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import overlay_check as O
import overlay_guard as G
import shift_change as S
import test_shift_change as T
from test_overlay_guard import Clock


class StartupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.clock = Clock()
        self.calls = []
        self.a = SimpleNamespace(state=self.tmp.name + '/state', again=600, wait=180,
                                 render_wait=30, service='stub', world=None, stale=120)
        self.env = patch.dict(os.environ, POG_TEST='1', POG_OC_SLEEP='2')
        self.env.start()
        self.addCleanup(self.env.stop)

    def run_start(self, service_at=1000, tunnel_at=1000, renders_after=1, missing_status=False, panel_px=1032):
        reloads = []
        def ready():
            return (self.clock() >= max(service_at, tunnel_at),
                    'snapshot ready' if self.clock() >= max(service_at, tunnel_at) else 'service/tunnel offline')
        def obs(cmd):
            self.assertGreaterEqual(self.clock(), max(service_at, tunnel_at))
            self.calls.append(cmd)
            if cmd == 'reload-overlay':
                reloads.append(self.clock())
            return True, 'stub accepted'
        def read(_):
            if missing_status:
                raise O.NoStatus('no status')
            now = self.clock()
            p = dict(open=1, connected=reloads[-1], seen=now)
            if renders_after is not None and len(reloads) >= renders_after:
                p['rendered'] = now
                p['panel_px'] = panel_px
            return dict(now=now, up=service_at, pages={'main': p})
        out = io.StringIO()
        with patch.object(G, 'tunnel_ready', side_effect=ready), patch.object(O, 'obs', side_effect=obs), \
             patch.object(O, 'read', side_effect=read), contextlib.redirect_stdout(out):
            rc = O.startup(self.a, self.clock, self.clock.sleep)
        return rc, out.getvalue(), reloads

    def test_service_twenty_seconds_late_and_tunnel_late(self):
        # Also reproduce shift123: service ready about 20 s beyond the old 120 s gate.
        for service, tunnel in [(1020, 1000), (1140, 1000), (1000, 1040)]:
            with self.subTest(service=service, tunnel=tunnel):
                Path(self.a.state + '.reload').unlink(missing_ok=True)
                self.clock.now = 1000
                self.calls.clear()
                rc, out, reloads = self.run_start(service, tunnel)
                self.assertEqual(rc, 0, out)
                self.assertEqual(reloads, [max(service, tunnel)])
                self.assertEqual(self.calls[:4], ['stream-scene', 'raise-overlay', 'scene stream', 'enable-overlay'])
                self.assertIn('readiness try 11 at +20s', out)
                self.assertIn('connected and rendered', out)

    def test_four_minute_service_is_degraded_then_watchdog_can_reload(self):
        rc, out, reloads = self.run_start(service_at=1240)
        self.assertEqual(rc, 1)
        self.assertEqual(self.clock(), 1180)
        self.assertEqual(self.calls, [])
        self.assertIn('DEGRADED', out)
        self.assertFalse(Path(self.a.state + '.reload').exists())
        self.clock.now = 1240
        st = {'now': 1240, 'up': 1000, 'pages': {}, 'health': {'sessions': []}}
        with patch.object(G, 'tunnel_ready', return_value=(True, 'ready')), \
             patch.object(O, 'read', return_value=st), patch.object(O, 'obs', return_value=(True, 'accepted')) as obs, \
             patch.object(O, 'ensure_enabled', return_value=None), \
             patch.object(G, 'watch_source', return_value=(None, {})), \
             patch.object(O, 'watch_more', return_value=0), contextlib.redirect_stdout(io.StringIO()):
            O.watch(self.a, self.clock, self.clock.sleep)
        self.assertIn(('reload-overlay',), [c.args for c in obs.call_args_list])

    def test_blank_page_gets_exactly_one_more_reload(self):
        rc, out, reloads = self.run_start(renders_after=2)
        self.assertEqual(rc, 0, out)
        self.assertEqual(reloads, [1000, 1030])
        with patch.object(G, 'tunnel_ready', return_value=(True, 'ready')):
            obs = lambda cmd: self.fail('watchdog must respect startup retry budget')
            ok, detail = G.reload_once(self.a, obs, clock=self.clock)
        self.assertFalse(ok)
        self.assertIn('cooldown', detail)
        self.assertTrue(json.loads(Path(self.a.state + '.reload').read_text())['retried'])

    def test_zero_height_render_report_is_blank(self):
        rc, out, reloads = self.run_start(panel_px=0)
        self.assertEqual(rc, 1, out)
        self.assertEqual(len(reloads), 2)
        self.assertIn('DEGRADED', out)

    def test_blank_or_missing_status_is_never_optional(self):
        for missing in (False, True):
            Path(self.a.state + '.reload').unlink(missing_ok=True)
            self.clock.now = 1000
            rc, out, reloads = self.run_start(renders_after=None, missing_status=missing)
            self.assertEqual(rc, 1, out)
            self.assertEqual(reloads, [1000, 1030])
            self.assertEqual(self.clock(), 1060)
            self.assertIn('DEGRADED', out)

    def test_another_start_cannot_bypass_budget(self):
        self.assertEqual(self.run_start()[0], 0)
        rc, out, reloads = self.run_start(renders_after=None, missing_status=True)
        self.assertEqual(rc, 1, out)
        self.assertEqual(reloads, [])
        self.assertIn('cooldown', out)

    def test_scene_builder_has_no_hidden_refresh(self):
        import ast
        tree = ast.parse((Path(__file__).parent / 'obs.py').read_text())
        scene = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'stream_scene')
        self.assertNotIn('refreshnocache', ast.unparse(scene))


class ChangeTest(unittest.TestCase):
    def test_health_overlay_degrades_but_agents_and_obs_still_fail(self):
        with tempfile.TemporaryDirectory() as d:
            team = Path(d) / 'team'; team.write_text('')
            for service_down in (False, True):
                with patch.object(S.urllib.request, 'urlopen', side_effect=O.Down('offline') if service_down else None), \
                     patch.object(S, 'overlay_status', return_value='overlay NOT drawing'), \
                     patch.object(S, 'run_words', return_value='active=True'):
                    # urlopen's mock needs an HTTP 200 response.
                    if not service_down:
                        S.urllib.request.urlopen.return_value.__enter__.return_value.status = 200
                    ok, line = S.health(d, str(team), 1000, obs=['stub'])
                    self.assertTrue(ok, line)
                    self.assertIn('health: DEGRADED', line)
                    with patch.object(S, 'run_words', return_value='active=False'):
                        self.assertFalse(S.health(d, str(team), 1000, obs=['stub'])[0])
                    team.write_text('absent\tmodel\n')
                    self.assertFalse(S.health(d, str(team), 1000, obs=['stub'])[0])
                    team.write_text('')

    def test_change_and_autopilot_contract(self):
        # Real shift-change shell with test_shift_change's existing stubs. Missing service
        # simulates the bounded startup timeout; successful start stub supplies the agents.
        for failed in (False, True):
            tmp, runs, bin_, state = T.setup()
            try:
                Path(runs, 'shake11', 'switches.env').write_text('POG_BROKER=0\n')
                r, calls = T.run(tmp, runs, bin_, state + '.offline', 'shake11', 'shake12', '240', '--stream',
                                 STREAMING='True', START_FAILS='1' if failed else '0', POG_SC_STALL_S='60')
                self.assertEqual(r.returncode, 1 if failed else 0, r.stdout + r.stderr)
                if not failed:
                    self.assertIn('change shake12 DEGRADED', r.stdout)
                    self.assertIn('announce change-degraded shake12', calls)
                    self.assertNotIn('announce change-failed', calls)
                    self.assertIn('health: DEGRADED', Path(runs, 'shake12', 'start.log').read_text())
                else:
                    self.assertIn('announce change-failed shake12', calls)
                self.autopilot(tmp, r.returncode)
            finally:
                shutil.rmtree(tmp)

    def autopilot(self, tmp, result):
        # Execute the deployed operator script in a disposable tree. Only its checkout
        # path and loop bound change; notices, git, shift change and watchdog are stubs.
        source = Path('/Users/owner/code/pog-operator/autopilot.sh')
        if not source.exists():
            print('SKIP operator autopilot replay: local operator script unavailable')
            return
        root = Path(tmp) / 'autopilot'; root.mkdir()
        (root / 'tools').mkdir(); (root / 'runs/shift1/agent').mkdir(parents=True)
        (root / 'runs/shift1/agent/deadline.txt').write_text('2000-01-01 00:00 PST\n')
        (root / 'runs/shift2').mkdir()
        (root / 'runs/shift2/start.log').write_text('started: 9/9\nhealth: DEGRADED (overlay)\n')
        (root / 'runs/shift2/switches.env').write_text('POG_EXPECT_CAMS=1\nPOG_CAMS=1\n')
        script = source.read_text().replace('R=/Users/owner/code/player-of-games', f'R={root}')
        self.assertIn('cur=$next', script)
        script = script.replace('cur=$next', 'cur=$next\n    break')
        (root / 'autopilot.sh').write_text(script)
        commands = {'tools/shift-change.sh': f'exit {result}', 'notice.sh': 'exit 0',
                    'watch-run3.sh': 'echo watchdog > "$(dirname "$0")/watchdog-started"',
                    'git': '[ "$1" != rev-parse ]',
                    'date': 'case "$1" in -j) echo 1000;; +%s) echo 2000;; *) echo 00:00;; esac'}
        for name, body in commands.items():
            p = root / name; p.write_text('#!/bin/bash\n' + body + '\n'); p.chmod(0o755)
        env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'])
        replay = subprocess.run(['bash', str(root / 'autopilot.sh'), 'shift1'], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(replay.returncode, result, replay.stderr)
        log = (root / 'autopilot.log').read_text()
        if result:
            self.assertIn('FAILED', log)
            self.assertNotIn('watchdog shift2 pid', log)
        else:
            self.assertIn('DEGRADED', log)
            self.assertIn('watchdog shift2 pid', log)
            self.assertNotIn('FAILED', log)


if __name__ == '__main__':
    unittest.main(warnings='ignore')
