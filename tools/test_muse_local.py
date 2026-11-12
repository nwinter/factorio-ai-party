#!/usr/bin/env python3
"""Provider failure stops the loop; the deadline terminates the owned client."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('muse_local', Path(__file__).with_name('muse-local.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Loop(unittest.TestCase):
    def invoke(self, child):
        with tempfile.TemporaryDirectory() as tmp:
            previous = Path.cwd()
            try:
                os.chdir(tmp)
                Path('prompt').write_text('Play until the deadline.')
                with patch.dict(os.environ, POG_SCOPE_ACTIVE='1'), \
                     patch.object(runner.sys, 'argv', ['muse-local', 'prompt']), \
                     patch.object(runner, 'deadline', return_value=time.time()+100), \
                     patch.object(runner.signal, 'signal'), \
                     patch.object(runner.subprocess, 'Popen', return_value=child) as launch:
                    result = runner.main()
                    self.assertEqual(launch.call_count, 1)
                    return result
            finally:
                os.chdir(previous)

    def test_provider_error_does_not_retry(self):
        self.assertEqual(self.invoke(Mock(wait=Mock(return_value=42))), 42)

    def test_deadline_reaps_owned_client(self):
        child = Mock(pid=12345, wait=Mock(side_effect=[subprocess.TimeoutExpired('muse', 100), 0]))
        with patch.object(runner.os, 'killpg') as kill:
            self.assertEqual(self.invoke(child), 0)
            kill.assert_called_once_with(12345, runner.signal.SIGTERM)
            self.assertEqual(child.wait.call_count, 2)


if __name__ == '__main__':
    unittest.main()
