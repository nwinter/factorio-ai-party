#!/usr/bin/env python3
"""Stop only helpers whose current command still belongs to this run."""
import argparse
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time

from run_state import ROOT,op_dir,read,write

SCRIPTS={'full_run.py','quota_refresh.py','autosave.py','team_views.py','viewer_inbox.py',
         'imac_cam.py','score-loop.sh','chat-log.py','netgate.py','serve.py','full_tools.py',
         'fh_broker.py','game_test.py','supervise.sh'}

def owned(args,run,folders):
    script=any(Path(a).name in SCRIPTS for a in args)
    bound=run in args or any(a==str(p) or a.startswith(str(p)+'/') for a in args for p in folders)
    return script and bound

def stop(run,execute=False):
    op=op_dir(run);work=read(op/'workspaces.json',{})
    folders=[ROOT/'runs'/run]+[Path(v['dir']).resolve() for v in work.values()]
    files=[op/'helpers.pid']+[p/name for p in folders[1:] for name in ('helpers.pid','broker.pid','supervisors.pid')]
    pids={int(line) for p in files if p.exists() for line in p.read_text().splitlines() if line.isdigit()}
    rows=[]
    for pid in sorted(pids):
        if pid in (0,1,os.getpid(),os.getppid()):continue
        result=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True,timeout=10)
        if result.returncode:status='already exited'
        elif not owned(shlex.split(result.stdout),run,folders):status='different owner; untouched'
        else:
            status='owned; would stop'
            if execute:
                subprocess.run(['pkill','-TERM','-P',str(pid)],capture_output=True,timeout=10)
                try:os.kill(pid,signal.SIGTERM)
                except ProcessLookupError:pass
                status='owned; stop requested'
        rows.append(dict(pid=pid,status=status))
    if execute:write(op/'helpers-stop.json',dict(at=time.time(),helpers=rows))
    return rows

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--execute',action='store_true')
    a=p.parse_args()
    for row in stop(a.run,a.execute):print(row['pid'],row['status'])
