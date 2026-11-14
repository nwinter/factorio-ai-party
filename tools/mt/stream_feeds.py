"""Restart only this run's read-only team feed processes, with exact argv ownership."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
from urllib.parse import urlsplit
from urllib.request import urlopen

from run_state import ROOT, pinned


def owns(argv, config, team, port):
    try:
        return (any(a in ('tools/stream/serve.py',str(ROOT/'tools/stream/serve.py')) for a in argv)
                and all(argv[argv.index(flag)+1]==value for flag,value in
                        [('--run',str(config)),('--world','imac2'),('--team',team),('--port',str(port))]))
    except (ValueError,IndexError):
        return False


def owned_pids(config, team, port):
    found=[]
    for row in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
        fields=row.strip().split(None,1)
        if len(fields)!=2 or 'serve.py' not in fields[1]:
            continue
        try:
            argv=shlex.split(fields[1])
        except ValueError:
            continue
        if owns(argv,config,team,port):
            found.append(int(fields[0]))
    return found


def restart_stale(op):
    pinned()
    tree=Path((op/'launch-tree').read_text().strip())
    for line in (op/'streams.txt').read_text().splitlines():
        if not line.strip():continue
        team,url=line.split();parsed=urlsplit(url)
        if not team.isalnum() or parsed.scheme!='http' or parsed.hostname!='127.0.0.1':
            raise ValueError('invalid feed registration')
        try:
            with urlopen(url.rstrip('/')+'/state.json',timeout=5) as response:
                data=json.load(response)
            if not data.get('poll_error') and 0<=time.time()-data.get('poll_ok',0)<30:
                continue
        except (OSError,ValueError):
            pass
        config=tree/'runs'/op.parent.name/team/'stream.json'
        if not config.is_file():raise RuntimeError('missing team stream config')
        # A recycled helper PID or somebody else's listener is never signalled.
        for pid in owned_pids(config,team,parsed.port):
            os.kill(pid,signal.SIGTERM)
            for _ in range(20):
                try:
                    args=shlex.split(subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True,stderr=subprocess.DEVNULL))
                except (subprocess.CalledProcessError,ValueError):
                    break
                if not owns(args,config,team,parsed.port):break
                time.sleep(.25)
            else:
                raise RuntimeError('owned stale feed did not stop; refusing duplicate')
        with (op/team/'stream-service.log').open('a') as log:
            child=subprocess.Popen([sys.executable,str(ROOT/'tools/stream/serve.py'),'--world','imac2','--team',team,
                 '--run',str(config),'--port',str(parsed.port),'--poll','5','--no-camera','--no-highlights',
                 '--no-replays','--no-night','--no-cuts','--log-dir',str(op/team/'stream-logs')],
                 cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        with (op/'helpers.pid').open('a') as handle:handle.write(str(child.pid)+'\n')
