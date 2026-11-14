#!/usr/bin/env python3
"""Keep quota telemetry fresh independently of the desktop widget."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import threading
import time

from run_state import alert,lock,op_dir,pinned,read,write

CACHE=Path.home()/'.cache/ai-usage/agent-brief.json'
COMMAND=['/Users/owner/.local/bin/ai-usage','agent','--json']

def stale(brief,now):
    return not 0<=now-brief.get('generated_at',0)<=480

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');a=p.parse_args()
    op=op_dir(a.run);stop=threading.Event();last_alert=0
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:stop.set())
    with lock(op/'quota-refresh.lock'):
        while not stop.is_set():
            pinned();state=read(op/'full-run.json',{})
            if state.get('phase')=='stopped':return
            error=None
            try:
                brief=read(CACHE,{})
                if stale(brief,time.time()):
                    result=subprocess.run(COMMAND,capture_output=True,text=True,timeout=120)
                    if result.returncode:raise RuntimeError(f'quota refresh exit {result.returncode}')
                    brief=json.loads(result.stdout)
                routes={r['kind'] if r['route']=='-' else r['route'] for r in state.get('agents',{}).values()}
                profiles={r.get('command'):r for r in brief.get('profiles',[])}
                unknown=[r for r in routes if r not in profiles or profiles[r].get('stale') or not profiles[r].get('available',True)]
                if stale(brief,time.time()) or unknown:raise RuntimeError(f'quota telemetry stale/unavailable: {sorted(unknown)}')
            except Exception as e:
                error=str(e)
                if time.time()-last_alert>=900:alert(op,'quota-telemetry-unavailable',error);last_alert=time.time()
            write(op/'quota-health.json',dict(at=time.time(),error=error,cache=str(CACHE)))
            stop.wait(60)

if __name__=='__main__':main()
