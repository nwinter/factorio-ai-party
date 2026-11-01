#!/usr/bin/env python3
"""Browser telemetry ingestion: bounded data, separate capture sessions, real handler and log."""
import json
from pathlib import Path
import sys
import tempfile
import shutil
import subprocess
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from http.server import ThreadingHTTPServer
sys.path.insert(0, str(Path(__file__).resolve().parent))
from overlay_health import OverlayHealth
from serve import AudioHub, Hub, make_handler


class HealthTest(unittest.TestCase):
    def test_browser_retry_primitive(self):
        if not shutil.which("node"):
            self.skipTest("node unavailable")
        subprocess.run(["node", str(Path(__file__).with_name("overlay_recovery_selftest.mjs"))], check=True, timeout=10)

    def test_bounded_sessions_and_diagnostics(self):
        h = OverlayHealth()
        for i in range(20):
            h.record({'session': f's{i}', 'page': 'main', 'capture': i == 0, 'errors': [
                {'message': 'x' * 1000, 'count': float('nan')} for _ in range(30)]})
        sessions = h.status()['sessions']
        self.assertEqual(len(sessions), 16)
        self.assertEqual(sessions[0]['session'], 's4')
        self.assertEqual(len(sessions[-1]['errors']), 20)
        self.assertEqual(len(sessions[-1]['errors'][0]['message']), 600)
        self.assertIsNone(sessions[-1]['errors'][0]['count'])
        for bad in ([], {}, {'session': '../a', 'page': 'main'}, {'session': 's', 'page': 'a' * 25}):
            with self.assertRaises(ValueError):
                h.record(bad)

    def test_real_endpoint_log_and_preview_does_not_replace_capture(self):
        with tempfile.TemporaryDirectory() as d:
            audio = AudioHub(str(Path(d) / 'audio-played.jsonl'))
            server = ThreadingHTTPServer(('127.0.0.1', 0), make_handler(Hub(), lambda: [], audio=audio))
            threading.Thread(target=server.serve_forever, daemon=True).start()
            base = f'http://127.0.0.1:{server.server_port}'
            def post(body):
                with urlopen(Request(base + '/overlay/health', json.dumps(body).encode(), {'Content-Type': 'application/json'})) as r:
                    return r.status
            try:
                for capture, session in ((True, 'obs'), (False, 'preview')):
                    self.assertEqual(post({'session': session, 'page': 'main', 'capture': capture,
                        'classes': 'fx-overlay onecam', 'layers': {'bar': {'visible': True}, 'caption': {'visible': False}},
                        'errors': [{'kind': 'layout', 'message': 'HTTP 503'}]}), 200)
                with urlopen(base + '/overlay/status') as r:
                    data = json.load(r)
                self.assertIn('pages', data)
                self.assertEqual([r['capture'] for r in data['health']['sessions']], [True, False])
                rows = [json.loads(s) for s in (Path(d) / 'overlay-health.jsonl').read_text().splitlines()]
                self.assertEqual(len(rows), 2)
                self.assertTrue(rows[0]['layers']['bar']['visible'])
                self.assertGreater(rows[0]['received_at'], 0)
                for bad, code in (([], 400), ({'session': 'a', 'page': 'main', 'errors': ['x' * 40000]}, 413)):
                    with self.assertRaises(HTTPError) as raised:
                        post(bad)
                    self.assertEqual(raised.exception.code, code)
                    raised.exception.close()
            finally:
                server.shutdown()
                server.server_close()


if __name__ == '__main__':
    unittest.main()
