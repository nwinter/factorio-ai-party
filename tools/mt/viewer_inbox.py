#!/usr/bin/env python3
"""One moderated audience feed, stored only in the private operator directory.

The durable JSONL inbox is the subscription hook for future narrators or other
non-playing consumers. This process has no Harness, broker or game relay.
"""
import argparse
import json
from pathlib import Path
import signal
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/stream'))
import viewers

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--minutes',type=int,required=True)
    p.add_argument('--run-mode',choices=['test','full'],default='test')
    viewers.add_args(p);a=p.parse_args()
    assert a.run and '/' not in a.run and not a.run.startswith('.') and a.minutes>=1
    assert a.run_mode=='full' or a.minutes<=90
    assert not a.relay and not a.broadcast_roster,'playing-agent relay is not supported'
    op=ROOT/'runs'/a.run/'op';assert op.is_dir()
    a.operator_only=True
    names=[f[1] for l in (op/'teams.tsv').read_text().splitlines() if l and not l.startswith('#') and len(f:=l.split('\t'))>=2]
    feed=viewers.build(a,agent_names=names,log_dir=str(op/'viewer-logs'),inbox=str(op/'viewer-inbox.jsonl'),
                       deletions=str(op/'viewer-deletions.jsonl'),cursor=str(op/viewers.CURSOR_NAME))
    assert feed and feed.relay is None
    feed.start();stop=False;deadline=time.time()+a.minutes*60
    def halt(*_):
        nonlocal stop
        stop=True
    signal.signal(signal.SIGTERM,halt);signal.signal(signal.SIGINT,halt)
    while not stop and (a.run_mode=='full' or time.time()<deadline):
        try:
            view=json.loads((op/'views.json').read_text())
            aliases=[a.get('display_name') for t in view.get('teams',[]) for a in t.get('agents',[])]
            feed.filt.set_agents(names+[n for n in aliases if isinstance(n,str)])
        except (OSError,ValueError,AttributeError,TypeError):pass
        lane,status=feed.lane()
        tmp=op/'viewers.json.tmp';tmp.write_text(json.dumps({'now':time.time(),'viewers':lane,'viewers_status':status}))
        tmp.replace(op/'viewers.json');time.sleep(1)

if __name__=='__main__':main()
