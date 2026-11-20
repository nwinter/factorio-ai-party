#!/usr/bin/env python3
"""Agy stream adapter: resume only this workspace's ID, without shared indexes.

(mt309) Turn-end cut. When the agent ends its turn while a command it started still runs as a background task
(typically `./fh ... --wait`), `agy -p` stays alive until the task finishes or --print-timeout kills it, and the
agent waits that long for its next conversation (Stage 1 Carbon: up to minutes a conversation). agy marks the end of
a turn only in its own transcript (brain/<conversation>/.system_generated/logs/transcript.jsonl: a final MODEL
PLANNER_RESPONSE without tool calls, written within about a second). The stream holds a step's rows back until the
background step before it finishes, and its stderr "root agent idle" line comes only for the first wait of a run.
So: a turn has ended when the transcript's last row is such a response, and a background task still runs when a
stream tool step is ACTIVE without a DONE. When both hold for POG_AGY_IDLE_CUT_S seconds (default 20; 0 turns the
cut off) and no new transcript row came, agy and every process under it are ended, its background tasks with them. A task that
finishes inside that time wakes the agent through agy's own system message (a new transcript row), so short waits
still deliver their result in the same conversation. A killed `fh --wait` only stops waiting: the game action it
waited for goes on, and the next conversation (-c, the same conversation) reads it through status.

Every stream row, transcript row and stderr line is logged with its time to .agy-events.jsonl in the workspace (one
JSON object a line; the cut as {"cut": ...}).
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

BRAIN = Path(os.environ.get('POG_AGY_BRAIN') or Path.home()/'.gemini/antigravity-cli/brain')


def tree(pid):
    """pid and every process under it, children first."""
    rows = subprocess.run(['ps', '-A', '-o', 'pid=,ppid='], capture_output=True, text=True).stdout.split('\n')
    kids = {}
    for r in rows:
        f = r.split()
        if len(f) == 2:
            kids.setdefault(int(f[1]), []).append(int(f[0]))
    out, todo = [], [pid]
    while todo:
        q = todo.pop(); out.append(q); todo.extend(kids.get(q, []))
    return out[::-1]


def end(pid, sig):
    for q in tree(pid):
        try:
            os.kill(q, sig)
        except ProcessLookupError:
            pass


def final_response(row):
    return (row.get('source') == 'MODEL' and row.get('type') == 'PLANNER_RESPONSE' and row.get('status') == 'DONE'
            and not row.get('tool_calls'))


class Cut:
    """The turn-end cut's state, fed by the stream (tool steps) and the transcript (rows); due() says when to cut."""

    def __init__(self, grace):
        self.grace, self.active, self.ended_at, self.lock = grace, {}, None, threading.Lock()

    def stream(self, update):
        if update.get('step_type') != 'tool':
            return
        with self.lock:
            i = update.get('step_index')
            if update.get('state') == 'ACTIVE':
                self.active[i] = ((update.get('tool_info') or {}).get('parameters') or {}).get('CommandLine') or update.get('tool_name')
            else:
                self.active.pop(i, None)

    def transcript(self, row, now):
        with self.lock:
            self.ended_at = now if final_response(row) else None

    def due(self, now):
        with self.lock:
            if self.grace > 0 and self.ended_at is not None and self.active and now - self.ended_at >= self.grace:
                return dict(waited_s=round(now - self.ended_at, 1), background=list(self.active.values()))
        return None


def main():
    folder=Path.cwd();marker=folder/'.agy-session.json';args=sys.argv[1:]
    if '-c' in args or '--continue' in args:
        args=[a for a in args if a not in ('-c','--continue')]
        if marker.exists():args=['--conversation',json.loads(marker.read_text())['id'],*args]
        else:args=['--new-project',*args]
    else:args=['--new-project',*args]
    t0=time.time();events=(folder/'.agy-events.jsonl').open('a');elock=threading.Lock()
    def log(**row):
        with elock:
            events.write(json.dumps({'t':round(time.time(),2),**row})+'\n');events.flush()
    log(start=True,args=[a for a in args if a in ('--new-project','--conversation')])
    p=subprocess.Popen([os.environ.get('POG_AGY_BIN') or str(Path.home()/'.local/bin/agy'),'--output-format','stream-json',*args],stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE,text=True)
    cut=Cut(float(os.environ.get('POG_AGY_IDLE_CUT_S','20')));conv={};done=threading.Event()
    def stderr():
        for line in p.stderr:
            log(stderr=line.rstrip()[:300]);print(line,end='',file=sys.stderr,flush=True)
    def transcript():
        seen,path=0,None
        while not done.is_set():
            time.sleep(0.5)
            if not path and conv.get('id'):path=BRAIN/conv['id']/'.system_generated/logs/transcript.jsonl'
            try:lines=path.read_text().splitlines() if path else []
            except OSError:continue
            for line in lines[seen:]:
                try:row=json.loads(line)
                except ValueError:break   # a row still being written: read it next time
                seen+=1;cut.transcript(row,time.time())
                log(tr=row.get('step_index'),source=row.get('source'),type=row.get('type'),status=row.get('status'),
                    calls=len(row.get('tool_calls') or []))
            due=cut.due(time.time())
            if due:
                log(cut=due);print(f"\n[agy-local] turn ended with {len(due['background'])} background task(s) still running; "
                                   f"ended agy after {due['waited_s']} s",file=sys.stderr,flush=True)
                end(p.pid,signal.SIGTERM)
                for _ in range(20):
                    if p.poll() is not None:return
                    time.sleep(0.25)
                end(p.pid,signal.SIGKILL)
                return
    threading.Thread(target=stderr,daemon=True).start();threading.Thread(target=transcript,daemon=True).start()
    state={}; response=[]
    for line in p.stdout:
        try:row=json.loads(line)
        except ValueError:
            print(line,end='',flush=True);continue
        update=row.get('step_update') or {}
        log(event=row.get('event'),step=update.get('step_index'),type=update.get('step_type'),state=update.get('state'),
            finished=(row.get('result') or {}).get('finished_reason'))
        if row.get('event')=='init':
            state={'id':row['conversation_id']};conv['id']=row['conversation_id'];marker.write_text(json.dumps(state)+'\n')
        cut.stream(update)
        if update.get('text_delta'):
            print(update['text_delta'],end='',flush=True);response.append(update['text_delta'])
        result=row.get('result') or {}
        usage=result.get('usage') or update.get('usage')
        if usage and state:
            state['tokens']=usage.get('input_tokens',0)+usage.get('cache_read_tokens',0)
            marker.write_text(json.dumps(state)+'\n')
        if result.get('response') and not response:print(result['response'],flush=True)
        if row.get('event')=='error':print(json.dumps(row),file=sys.stderr,flush=True)
    rc=p.wait();done.set();log(exit=rc,took_s=round(time.time()-t0,1))
    return rc

if __name__=='__main__':sys.exit(main())
