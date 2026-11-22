#!/usr/bin/env python3
"""Launch one isolated 2.1 test in a detached session so its helpers survive.

Uses start-mt.sh unchanged for roster/quota/privacy/camera behavior. Set its
POG_MT_PUBLIC/POG_MT_YOUTUBE/POG_RESUME/POG_MT_SAVE options in the environment.
Inspect the printed start log; this command starts no streaming or site push.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('run');p.add_argument('minutes',type=int)
    p.add_argument('--roster',type=Path,default=ROOT/'agent/mt/teams-test.tsv')
    p.add_argument('--execute',action='store_true')
    p.add_argument('--run-mode',choices=['test','full'],default='test')
    # (mt309) Stage 2's two-hour sprints: a test run may be 120 minutes only when the caller says so.
    p.add_argument('--max-minutes',type=int,choices=[90,120],default=90)
    a=p.parse_args()
    assert re.fullmatch(r'[A-Za-z0-9_-]{1,16}',a.run) and a.minutes>=1
    assert a.run_mode=='full' or a.minutes<=a.max_minutes, f'test runs are bounded to {a.max_minutes} minutes'
    assert a.roster.is_file()
    op=ROOT/'runs'/a.run/'op'
    assert not (op/'launch-process.json').exists() and not (op/'panes.txt').exists(),'run already started; choose a new ID'
    env=dict(os.environ,MT_DIR='/Users/owner/pog-mt21',MT_FACTORIO_APP='/Users/owner/code/factorio-mac-2.1.24/factorio.app',
             MT_EXPECT_VERSION='2.1.24',MT_RCON_PORT='27475',MT_GAME_PORT='34475',
             MT_MODS_FILE=str(ROOT/'agent/mt/mods-2.1.24.tsv'),POG_KB='space-age-2.1.24',
             POG_MT_TREE='/Users/owner/code/personal/player-of-games/worktrees/pog-p21')
    env.setdefault('POG_MT_FRESH_SAVE','/Users/owner/code/personal/player-of-games/artifacts/port21-p3/mt-baseline21.zip')
    env['POG_RUN_MODE']=a.run_mode
    if a.run_mode=='full':
        env.setdefault('POG_GAME_TEST','0')
        env.setdefault('POG_IDLE_NUDGE','1')
    cmd=['bash',str(ROOT/'tools/mt/start-mt.sh'),a.run,str(a.minutes),str(a.roster.resolve())]
    if not a.execute:
        subprocess.run(cmd,cwd=ROOT,env=dict(env,POG_DRY_RUN='1'),check=True)
        return
    from run_state import claim
    claim()
    state=subprocess.check_output(['bash',str(ROOT/'tools/mt/imac_mt.sh'),'status'],cwd=ROOT,env=env,text=True)
    assert state.startswith('not running'),'one private server at a time; stop the current run'
    op.mkdir(parents=True,exist_ok=True)
    with (op/'start-public.log').open('a') as log:
        child=subprocess.Popen(cmd,cwd=ROOT,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    (op/'launch-process.json').write_text(json.dumps({'pid':child.pid,'run':a.run,'minutes':a.minutes,'run_mode':a.run_mode,'command':cmd,'version':'2.1.24'},indent=2))
    print('launcher',child.pid,op/'start-public.log')


if __name__=='__main__':main()
