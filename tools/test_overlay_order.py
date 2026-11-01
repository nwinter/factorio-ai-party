#!/usr/bin/env python3
"""The watchdog diagnoses composition even when page/SSE/speech are healthy, with no reload/reorder."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))
import overlay_check as O
from stream import scene_order as S


class WatchdogOrderTest(unittest.TestCase):
    def test_cover_and_recovery_report_without_control_calls(self):
        now = 1000
        st = {'now': now, 'up': 800, 'pages': {'main': {'open': 1, 'seen': now, 'connected': 900,
              'rendered': now, 'panel_px': 1032}}}
        items = [dict(sceneItemId=k, sceneItemIndex=k, sourceName=n, sceneItemEnabled=True)
                 for k, n in enumerate(['background', 'stream overlay', 'stream cam1'])]
        covered = S.report(items, 'stream')
        items[1]['sceneItemIndex'], items[2]['sceneItemIndex'] = 2, 1
        good = S.report(items, 'stream')
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {'POG_TEST': '1'}), \
             patch.object(O, 'read', return_value=st), patch.object(O, 'ensure_enabled', return_value=None), \
             patch.object(O, 'obs', side_effect=AssertionError('no mutation command allowed')), \
             patch.object(O, 'cameras', return_value=None):
            a = SimpleNamespace(service='offline', state=str(Path(d)/'state.json'), world=None, again=600, stale=120)
            for order, rc, expected in [(covered, 1, 'ORDER: overlay order NOT top'),
                                        (covered, 1, ''), (good, 0, 'top enabled item')]:
                buf = io.StringIO()
                with patch.object(O, 'composition', return_value=order), contextlib.redirect_stdout(buf):
                    self.assertEqual(O.watch(a, clock=lambda: now), rc)
                if expected: self.assertIn(expected, buf.getvalue())
                else: self.assertEqual(buf.getvalue(), '')
            record = json.loads(Path(a.state).read_text())['order_report']
            self.assertTrue(record['ok']); self.assertEqual(record['checked_at'], now)
            with patch.object(O, 'composition', return_value=covered), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(O.status(a), 1)
            self.assertIn('overlay connected', out.getvalue())
            self.assertIn('stream cam1', out.getvalue())

    def test_read_errors_are_bad_and_tests_do_not_contact_obs(self):
        with patch.dict(os.environ, {'POG_TEST': '1'}):
            os.environ.pop('POG_OC_ORDER', None)
            self.assertIsNone(O.composition())
        self.assertTrue(S.line({'error': 'connection refused'})[1])
        self.assertIn('UNKNOWN', S.line({'error': 'connection refused'})[0])


if __name__ == '__main__':
    unittest.main()
