import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'tools/mt'),str(ROOT/'tools/stream')]
import workspaces
import viewers
spec=importlib.util.spec_from_file_location('agent_scope',ROOT/'tools/agent-scope.py')
scope=importlib.util.module_from_spec(spec);spec.loader.exec_module(scope)

class DiscoveryTests(unittest.TestCase):
    def test_separate_anonymous_workspaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);root=base/'operator';template=base/'template'
            (root/'runs/fresh/op').mkdir(parents=True)
            (template/'runs/old/green').mkdir(parents=True)
            (template/'runs/old/green/notes.md').write_text('old coloured roster')
            (template/'README.md').write_text('play')
            paths=workspaces.prepare(root,template,'fresh',['green','blue'])
            for team,row in paths.items():
                tree=Path(row['tree']);folder=Path(row['dir'])
                self.assertNotIn(team,str(folder));self.assertEqual(folder.resolve(),folder)
                self.assertEqual((root/'runs/fresh'/team).resolve(),folder)
                self.assertFalse((tree/'runs/old').exists())
                self.assertEqual(list((tree/'runs').iterdir()),[folder])
            self.assertNotEqual(paths['green']['tree'],paths['blue']['tree'])

    def test_environment_contains_no_operator_or_peer_context(self):
        env={'HOME':'/Users/person','PATH':'/bin','POG_TEAM':'green','POG_MT_TEAMS':'green,blue',
             'HERDR_PANE_ID':'another','MT_DIR':'/private/server','POG_DENY_READ':'/private/blue'}
        self.assertEqual(scope.environment(env),{'HOME':'/Users/person','PATH':'/bin'})

    @unittest.skipUnless(sys.platform=='darwin','macOS filesystem boundary')
    def test_actual_project_read_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            policy=Path(tmp)/'scope.sb';policy.write_text(scope.profile(ROOT,Path.home()))
            allowed=subprocess.run(['/usr/bin/sandbox-exec','-f',str(policy),'/bin/cat',str(ROOT/'agent/PLAYBOOK.md')],capture_output=True)
            denied=subprocess.run(['/usr/bin/sandbox-exec','-f',str(policy),'/bin/ls',str(ROOT.parent)],capture_output=True)
            self.assertEqual(allowed.returncode,0,allowed.stderr)
            self.assertNotEqual(denied.returncode,0)
            self.assertNotIn(b'pog-mt294',denied.stdout)
            for private in (Path.home()/'.cache/ai-usage/agent-brief.json',Path.home()/'.zsh_history'):
                if private.exists():
                    r=subprocess.run(['/usr/bin/sandbox-exec','-f',str(policy),'/bin/cat',str(private)],capture_output=True)
                    self.assertNotEqual(r.returncode,0)
                    self.assertFalse(r.stdout)

    def test_operator_feed_has_no_game_relay(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'inbox.jsonl'
            with self.assertRaises(AssertionError):viewers.Feed({},operator_only=True)
            with self.assertRaises(AssertionError):viewers.Feed({},inbox=str(p),relay=object(),operator_only=True)
            feed=viewers.Feed({},inbox=str(p),operator_only=True)
            self.assertIsNone(feed.relay)

    @unittest.skipUnless(sys.platform=='darwin' and Path('/Volumes/POG Media/pog-runs').is_dir(),
                         'macOS archive disk required')
    def test_closed_external_archive_is_not_an_agent_input(self):
        with tempfile.TemporaryDirectory(dir='/Volumes/POG Media/pog-runs',prefix='.scope-test-') as tmp:
            secret=Path(tmp)/'private-notes';secret.write_text('another pair historical notes')
            with tempfile.TemporaryDirectory() as local:
                policy=Path(local)/'scope.sb';policy.write_text(scope.profile(ROOT,Path.home()))
                denied=subprocess.run(['/usr/bin/sandbox-exec','-f',str(policy),'/bin/cat',str(secret)],capture_output=True)
                self.assertNotEqual(denied.returncode,0)
                self.assertFalse(denied.stdout)

if __name__=='__main__':unittest.main()
