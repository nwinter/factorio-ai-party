#!/usr/bin/env python3
"""Team play never receives a run timer or the spectator ranking; ordinary worlds keep their clock."""
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
import brief
import context
import refresh_workspaces
import testsafe


class PrivateClock(unittest.TestCase):
    def test_workspace_and_recovery(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            shutil.copytree(ROOT/'agent',root/'agent')
            (root/'tools').mkdir()
            for name in ('new-run.sh','brief.py'):
                shutil.copy2(ROOT/'tools'/name,root/'tools'/name)
            shutil.copytree(ROOT/'tools/disclosure',root/'tools/disclosure')
            for name, continuous in [('normal',False),('ongoing',True)]:
                env=testsafe.env(POG_WS=name,POG_BOT=name,POG_BROKER='1',POG_CONTINUOUS='1' if continuous else '0')
                p=subprocess.run(['bash',str(root/'tools/new-run.sh'),'test','n',name,'10'],env=env,capture_output=True,text=True)
                self.assertEqual(p.returncode,0,p.stderr)
                ws=Path(p.stdout.strip());core=(ws/'AGENTS.md').read_text();fh=(ws/'fh').read_text()
                self.assertEqual((ws/'deadline.txt').exists(),not continuous)
                if continuous:
                    self.assertNotRegex(core,r'(?i)deadline|time limit|ranked|ranking')
                    self.assertNotIn('deadline.txt',fh)
                    self.assertIn('FH_CONTINUOUS=1',fh)
                    self.assertIsNone(context.seconds_left(str(ws)))
                    self.assertNotRegex(context.notes_block(str(ws),'Continue.'),r'(?i)deadline|time limit|ranking')
                    # Recovery, including overflow detail, contains no clock label or missing-clock hint.
                    recovered=context.brief(str(ws),'Continue.')
                    self.assertNotRegex(recovered,r'(?i)deadline|time limit|ranking')
                    refresh_workspaces.refresh(str(ws),None)
                    for path in [ws/'AGENTS.md',ws/'ref/analysis.md',ws/'ref/team.md']:
                        self.assertNotRegex(path.read_text(),r'deadline.txt|deadline minus|time left in the shift')
                else:
                    self.assertIn('deadline.txt',core)
                    self.assertIn('FH_DEADLINE_FILE=',fh)
                    self.assertIsNotNone(context.seconds_left(str(ws)))

    def test_native_continuation_and_resume_prompts(self):
        src=(ROOT/'tools/launch-agent.sh').read_text()
        begin=src.index('agy_continuous_script() {')
        end=src.index('\nagy_loop_script() {',begin)
        with tempfile.TemporaryDirectory() as d:
            script=Path(d)/'generate.sh'
            script.write_text('root="$1"\ndir="$2"\nmodel=gemini\nlimit=10000\nproxy_env=""\nsleepcap_run=/usr/bin/env\n'+src[begin:end]+'\nagy_continuous_script\n')
            subprocess.run(['bash',str(script),str(ROOT),d],env=testsafe.env(),check=True)
            generated=(Path(d)/'.agy-loop.sh').read_text()
            self.assertNotRegex(generated,r'(?i)deadline|time limit|ranked|ranking')
            subprocess.run(['bash','-n',str(Path(d)/'.agy-loop.sh')],check=True)
            resume=subprocess.check_output(['bash',str(ROOT/'tools/launch-agent.sh'),'--resume-sentence'],env=testsafe.env(POG_CONTINUOUS=1),text=True)
            self.assertNotRegex(resume,r'(?i)deadline|time limit|ranked|ranking')

    def test_short_21_tests_use_operator_owned_shift_bound(self):
        src=(ROOT/'tools/mt/start-mt.sh').read_text()
        self.assertIn('export POG_CONTINUOUS=1 POG_PANE_WATCH=1',src)
        self.assertIn('shift_limit=1',src)
        self.assertIn('--max-shifts "$shift_limit"',src)
        self.assertIn('POG_FULL_SHIFTS:-0',src)


if __name__=='__main__':unittest.main()
