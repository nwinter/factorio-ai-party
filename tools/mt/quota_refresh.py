#!/usr/bin/env python3
"""Read the dashboard quota cache; use a rare fallback if its refresh stops."""
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
CACHE_MAX_AGE=900
FALLBACK_AGE=600  # Two expected dashboard refreshes missed; allow time to recover.
FALLBACK_EVERY=1800

def stale(brief,now):
    return not 0<=now-brief.get('generated_at',0)<=CACHE_MAX_AGE

def unavailable(brief,routes,now):
    profiles={r.get('command'):r for r in brief.get('profiles',[])}
    def missing(route):
        p=profiles.get(route,{})
        observed=p.get('observed_at') or brief.get('generated_at',0)
        return stale(brief,now) or not p or p.get('stale') or not p.get('available',True) or not 0<=now-observed<=CACHE_MAX_AGE
    return sorted(r for r in routes if missing(r))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run')
    p.add_argument('--fallback-every',type=int,default=FALLBACK_EVERY,help='minimum seconds between fallback attempts (at least 600)')
    p.add_argument('--reader-timeout',type=int,default=240,help='bounded fallback deadline in seconds (at most 300)')
    p.add_argument('--reader',nargs='+',default=COMMAND,help='quota reader argv; must emit the normal ai-usage brief JSON')
    a=p.parse_args()
    if a.fallback_every<600 or not 1<=a.reader_timeout<=300:p.error('fallback interval must be >=600 and timeout 1..300')
    op=op_dir(a.run);stop=threading.Event();last_alert=0
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:stop.set())
    fallback=read(op/'quota-fallback.json',{})
    with lock(op/'quota-refresh.lock'):
        while not stop.is_set():
            pinned();state=read(op/'full-run.json',{})
            if state.get('phase')=='stopped':return
            error=None;brief={}
            try:
                brief=read(CACHE,{})
                now=time.time()
                if now-brief.get('generated_at',0)>=FALLBACK_AGE and (not fallback or now-fallback.get('at',0)>=a.fallback_every):
                    fallback=dict(at=now,reader=a.reader,phase='started');write(op/'quota-fallback.json',fallback)
                    result=subprocess.run(a.reader,capture_output=True,text=True,timeout=a.reader_timeout)
                    fallback.update(phase='finished',exit=result.returncode,elapsed=time.time()-now);write(op/'quota-fallback.json',fallback)
                    if result.returncode:raise RuntimeError(f'quota refresh exit {result.returncode}')
                    brief=json.loads(result.stdout)
                routes={r['kind'] if r['route']=='-' else r['route'] for r in state.get('agents',{}).values()}
                unknown=unavailable(brief,routes,time.time())
                if stale(brief,time.time()) or unknown:raise RuntimeError(f'quota telemetry stale/unavailable: {unknown}')
            except Exception as e:
                error=str(e)
                if fallback.get('phase')=='started':
                    fallback.update(phase='failed',error=error,elapsed=time.time()-fallback['at']);write(op/'quota-fallback.json',fallback)
                if time.time()-last_alert>=900:alert(op,'quota-telemetry-unavailable',error);last_alert=time.time()
            now=time.time()
            write(op/'quota-health.json',dict(at=now,error=error,cache=str(CACHE),generated_at=brief.get('generated_at'),
                  age_seconds=now-brief.get('generated_at',0),stale=stale(brief,now),fallback_at=fallback.get('at')))
            stop.wait(60)

if __name__=='__main__':main()
