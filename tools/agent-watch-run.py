#!/usr/bin/env python3
"""Owned native client lifetime receipt for the host supervisor (no game reads)."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    folder=Path(sys.argv[1]);script=Path(sys.argv[2])
    path=folder/'.client-state.json'
    child=subprocess.Popen([str(script)],start_new_session=True)
    state=dict(pid=os.getpid(),child=child.pid,script=str(script),started=time.time(),phase='running')
    def save():
        temp=path.with_suffix('.tmp');temp.write_text(json.dumps(state));temp.replace(path)
    save()
    def stop(signum,frame):
        try:os.killpg(child.pid,signal.SIGTERM)
        except ProcessLookupError:pass
    for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP):signal.signal(sig,stop)
    result=child.wait()
    state.update(phase='exited',exit=result,ended=time.time());save()
    return result

if __name__=='__main__':sys.exit(main())
