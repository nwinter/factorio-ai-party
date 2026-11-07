#!/usr/bin/env python3
"""Countdown reaches the public API and both built live pages with one shared formatter."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
from push_live import public_state


class CountdownSiteTest(unittest.TestCase):
    def test_public_projection_and_clear(self):
        target = {'goal': 'Asterion onward', 'at': '2026-11-07 07:00 PST', 'at_epoch': 1794063600}
        self.assertEqual(public_state({'run_target': dict(target, note='private', by='private')})['run_target'], target)
        for value in (None, [], 'bad'):
            self.assertIsNone(public_state({'run_target': value})['run_target'])
        self.assertIsNone(public_state({})['run_target'])

    def test_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'runs').mkdir()
            subprocess.run([sys.executable, str(SITE / 'build.py'), '--runs-dir', str(root / 'runs'),
                            '--out', str(root / 'dist')], check=True, capture_output=True, text=True)
            shared = SITE.parent / 'tools/stream/static/target-countdown.js'
            self.assertEqual((root / 'dist/static/target-countdown.js').read_bytes(), shared.read_bytes())
            for page in ('index.html', 'live/index.html'):
                html = (root / 'dist' / page).read_text()
                self.assertIn('id="run-target"', html)
                self.assertLess(html.index('/static/target-countdown.js'), html.index('/static/live.js'))
                self.assertLess(html.index('id="run-target"'), html.index('class="live-top"'))
            # This file-only feature adds no endpoint or Worker deployment.
            source = (SITE / 'static/live.js').read_text()
            self.assertIn('targetCountdown.update(live ? s.run_target : null, age)', source)
            self.assertIn('targetCountdown.update(null)', source)


if __name__ == '__main__':
    unittest.main()
