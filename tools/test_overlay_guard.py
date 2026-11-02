#!/usr/bin/env python3
"""batch413: late service/tunnel, blank/stale capture, reload budget and bounded source reads; all OBS stubbed."""
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import overlay_guard as G
import overlay_check as O


class Clock:
    def __init__(self): self.now = 1000
    def __call__(self): return self.now
    def sleep(self, seconds): self.now += seconds


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.a = SimpleNamespace(state=self.tmp.name + '/state.json', again=600,
                                 wait=0, service='http://stub.invalid', stale=120, world=None)
        self.clock = Clock()
        self.calls = []
        self.env = patch.dict(os.environ, POG_TEST='1')
        self.env.start()
        self.addCleanup(self.env.stop)

    def obs(self, cmd):
        self.calls.append(cmd)
        return True, 'stub accepted'

    def reload(self, wait=0):
        return G.reload_once(self.a, self.obs, wait=wait, clock=self.clock, sleep=self.clock.sleep)

    def script(self, name, text):
        path = Path(self.tmp.name) / name
        path.write_text('#!' + sys.executable + '\n' + text)
        path.chmod(0o755)
        return str(path)

    def test_late_service_and_late_tunnel(self):
        for failures in (["refused", "empty", "ready"], ["tunnel", "tunnel", "ready"]):
            with self.subTest(failures=failures):
                budget = Path(self.a.state + '.reload')
                budget.unlink(missing_ok=True)
                self.calls.clear()
                # Actual subprocess seam: the remote curl stub can fail or return HTTP 200 with no snapshot.
                phases = Path(self.tmp.name) / 'phases.json'
                phases.write_text(json.dumps(failures))
                ready = self.script('ready', f'''import json, pathlib, sys
p = pathlib.Path({str(phases)!r})
phases = json.loads(p.read_text()); phase = phases.pop(0); p.write_text(json.dumps(phases))
if phase in ('refused', 'tunnel'): sys.exit(7)
print('{{}}' if phase == 'empty' else '{{"tick": 42, "agents": []}}')
''')
                with patch.dict(os.environ, POG_OC_READY=ready):
                    ok, detail = self.reload(wait=10)
                self.assertTrue(ok, detail)
                self.assertEqual(self.calls, ['reload-overlay'])
                self.assertEqual(json.loads(phases.read_text()), [])

    def test_remote_endpoint_and_invalid_snapshot(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(G.subprocess, 'run') as run:
            run.return_value = SimpleNamespace(stdout='{"tick": 1, "agents": []}')
            self.assertTrue(G.tunnel_ready()[0])
            cmd = run.call_args.args[0]
            self.assertEqual(cmd[-2], 'pogwin')
            self.assertIn('curl.exe --fail', cmd[-1])
            self.assertIn('http://127.0.0.1:8787/state.json', cmd[-1])
            for body in ('{}', '[]', '<html>error</html>'):
                run.return_value.stdout = body
                self.assertFalse(G.tunnel_ready()[0])

    def test_timeout_does_not_spend_reload_budget(self):
        with patch.object(G, 'tunnel_ready', return_value=(False, 'offline')):
            self.assertFalse(self.reload(wait=6)[0])
        self.assertEqual(self.clock.now, 1006)
        self.assertFalse(Path(self.a.state + '.reload').exists())
        self.assertEqual(self.calls, [])

    def test_shared_cooldown_failed_request_and_minimum(self):
        with patch.object(G, 'tunnel_ready', return_value=(True, 'stub ready')):
            self.assertTrue(self.reload()[0])
            self.assertIn('cooldown', self.reload()[1])
            # A second process/namespace uses the same persisted file, even with --again 0.
            self.a.again = 0
            self.clock.sleep(179)
            self.assertFalse(self.reload()[0])
            self.clock.sleep(1)
            def timeout(cmd):
                self.calls.append(cmd)
                raise subprocess.TimeoutExpired(cmd, 60)
            result = G.reload_once(self.a, timeout, clock=self.clock)
            self.assertFalse(result[0])
            self.assertIn('FAILED', result[1])
            self.assertFalse(self.reload()[0])
            self.assertEqual(self.calls, ['reload-overlay', 'reload-overlay'])
            Path(self.a.state + '.reload').write_text('broken')
            self.assertIn('budget unavailable', self.reload()[1])

    def st(self, **health):
        return {'now': self.clock(), 'up': 800, 'pages': {'main': {
            'open': 1, 'connected': 900, 'seen': self.clock(), 'rendered': self.clock()}},
            'health': {'sessions': [dict(page='main', capture=True, received_at=self.clock(),
                                         state_age_s=0, **health)]}}

    def test_health_ignores_preview_and_portrait(self):
        st = self.st()
        self.assertIsNone(G.health_problem(st))
        st['health']['sessions'][0]['received_at'] = 800
        st['health']['sessions'] += [dict(page='main', capture=False, received_at=1000),
                                     dict(page='portrait', capture=True, received_at=1000)]
        self.assertIn('no OBS main health report', G.health_problem(st))
        st = self.st()
        st['health']['sessions'][0]['state_age_s'] = 121
        self.assertIn('state stale', G.health_problem(st))
        st['health']['sessions'][0].update(state_age_s=None, age_s=121)
        self.assertIn('received no state', G.health_problem(st))
        st['health']['sessions'] = []
        self.assertIn('no OBS main health report', G.health_problem(st))
        st['up'] = 999
        self.assertIsNone(G.health_problem(st))

    def test_screenshot_request_and_cost_bound(self):
        # Stub the actual OBS client and check source, dimensions and retry policy.
        png = b'\x89PNG\r\n\x1a\n' + b'x' * 1000
        with patch.dict(os.environ, {}, clear=True), patch('stream.obsws.OBS') as cls:
            client = cls.return_value
            client.call.return_value = {'imageData': 'data:image/png;base64,' + base64.b64encode(png).decode()}
            result = G.source_shot()
            self.assertTrue(result['near_empty'])
            self.assertEqual(result['bytes'], len(png))
            client.call.assert_called_once_with('GetSourceScreenshot', {'sourceName': 'stream overlay',
                'imageFormat': 'png', 'imageWidth': 480, 'imageHeight': 270}, retry=False)
            client.close.assert_called_once()
        state = {}
        with patch.object(G, 'source_shot', return_value=result) as shot:
            for n in range(60):
                self.assertIsNone(G.sample_source(state, 1000 + n))
            self.assertEqual(shot.call_count, 1)
            self.assertIn('near-empty', G.sample_source(state, 1060))
            self.assertEqual(shot.call_count, 2)
            shot.return_value = {'error': 'timeout'}
            self.assertIsNone(G.sample_source(state, 1120))

    def test_watch_recovers_once_with_fresh_stream_and_render(self):
        st = self.st()
        st['health']['sessions'] = []  # JS never loaded, but another page may keep the aggregate stream fresh
        with patch.object(O, 'read', return_value=st), patch.object(O, 'obs', side_effect=self.obs), \
             patch.object(O, 'watch_more', return_value=0), \
             patch.object(G, 'tunnel_ready', return_value=(True, 'stub ready')), \
             patch.object(G, 'source_shot', return_value={'bytes': 10000, 'near_empty': False}):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(O.watch(self.a, self.clock, self.clock.sleep), 1)
                self.assertEqual(O.watch(self.a, self.clock, self.clock.sleep), 1)
            self.assertEqual(self.calls, ['enable-overlay', 'reload-overlay', 'enable-overlay'])
            self.assertIn('reload-overlay attempt', out.getvalue())
            self.assertIn('cooldown', out.getvalue())
            st['health'] = self.st()['health']
            self.assertEqual(O.watch(self.a, self.clock, self.clock.sleep), 0)
            self.assertIsNone(O.load_state(self.a.state)['failed'])

    def test_blank_source_with_healthy_telemetry(self):
        with patch.object(O, 'read', side_effect=lambda url: self.st()), patch.object(O, 'obs', side_effect=self.obs), \
             patch.object(O, 'watch_more', return_value=0), \
             patch.object(G, 'tunnel_ready', return_value=(True, 'stub ready')), \
             patch.object(G, 'source_shot', return_value={'bytes': 1024, 'near_empty': True}) as shot:
            self.assertEqual(O.watch(self.a, self.clock, self.clock.sleep), 0)
            self.assertEqual(O.watch(self.a, self.clock, self.clock.sleep), 0)
            self.assertEqual(shot.call_count, 1)
            self.clock.sleep(60)
            self.assertEqual(O.watch(self.a, self.clock, self.clock.sleep), 1)
            self.assertEqual(self.calls.count('reload-overlay'), 1)
            self.assertEqual(shot.call_count, 2)
            self.clock.sleep(60)
            shot.return_value = {'bytes': 50000, 'near_empty': False}
            self.assertEqual(O.watch(self.a, self.clock, self.clock.sleep), 0)
            self.assertIsNone(O.load_state(self.a.state)['failed'])

    def test_parallel_prepare_and_startup_order(self):
        log = Path(self.tmp.name) / 'calls'
        obs = self.script('obs', f'''import sys
with open({str(log)!r}, 'a') as f: f.write('obs ' + ' '.join(sys.argv[1:]) + '\\n')
print('active=True')
''')
        ready = self.script('ready', f'''import json
with open({str(log)!r}, 'a') as f: f.write('ready\\n')
print(json.dumps({{'tick': 42, 'agents': []}}))
''')
        env = dict(os.environ, POG_OC_READY=ready, POG_OC_OBS=obs, POG_OC_STATE=self.a.state)
        check = str(Path(O.__file__).resolve())
        cmd = [sys.executable, check, 'prepare', '--wait', '0']
        processes = [subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for _ in range(2)]
        outputs = [p.communicate(timeout=10) for p in processes]
        self.assertEqual(sorted(p.returncode for p in processes), [0, 1], outputs)
        self.assertEqual(log.read_text().count('obs reload-overlay'), 1)
        self.assertIn('cooldown', ''.join(out for out, err in outputs))
        Path(self.a.state + '.reload').unlink()
        log.write_text('')
        # Real shell and startup CLI; only the page's render report is stubbed.
        overlay = self.script('overlay', f'''import sys, time
sys.path.insert(0, {str(Path(check).parent)!r})
import overlay_check as O
def read(service):
    now = time.time()
    return {{'now': now, 'pages': {{'main': {{'open': 1, 'seen': now, 'connected': now, 'rendered': now, 'panel_px': 1032}}}}}}
O.read = read
sys.exit(O.main())
''')
        env.update(POG_OS_OBS=obs, POG_OS_OVERLAY=overlay, POG_OS_READY_WAIT='0')
        root = Path(O.__file__).resolve().parent.parent
        r = subprocess.run(['bash', str(root / 'tools/obs-steps.sh')], env=env, cwd=root,
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = log.read_text().splitlines()
        self.assertLess(calls.index('ready'), calls.index('obs stream-scene'))
        self.assertLess(calls.index('ready'), calls.index('obs reload-overlay'))
        self.assertLess(calls.index('obs reload-overlay'), calls.index('obs start'))
        self.assertEqual(calls.count('obs reload-overlay'), 1)
        self.assertIn('reload-overlay accepted', r.stdout)


if __name__ == '__main__':
    unittest.main()
