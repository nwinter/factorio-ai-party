#!/usr/bin/env python3
"""Offline check for tools/supervise.sh with a fake herdr that always reports the agent idle: an agent whose journal
has a request in the last 2 minutes is working and is never nudged (shake3: Grok and Muse were nudged mid-turn); one
whose last request is older is nudged. Claude Code's idle means its turn ended (shake4), so a claude agent is nudged
anyway. After the deadline an agent whose turn has ended is asked once for its final summary.
python3 tools/test_supervise.py"""
import datetime
import os
import re
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUPERVISE = os.path.join(ROOT, "tools", "supervise.sh")

FAKE_HERDR = r'''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_HERDR_LOG"], "a") as log: log.write(" ".join(args[:2]) + "\n")
if args[:2] == ["pane", "get"]: print('{"pane":"p1","agent_status":"idle"}')
'''


def iso(seconds_ago):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds_ago)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)


def run(last_request_ago, kind=None, deadline_in=240, resting_for=None):
    """Supervise for a few seconds against a journal whose last request is that old; return supervisor.log."""
    tmp = tempfile.mkdtemp()
    bindir, ws = os.path.join(tmp, "bin"), os.path.join(tmp, "ws")
    os.makedirs(bindir)
    os.makedirs(ws)
    herdr = os.path.join(bindir, "herdr")
    open(herdr, "w").write(FAKE_HERDR)
    os.chmod(herdr, 0o755)
    open(os.path.join(ws, "deadline.txt"), "w").write(
        time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(time.time() + deadline_in)) + "\n")
    if kind:
        open(os.path.join(ws, ".context-hooks"), "w").write(kind + " 0 0 0\n")
    if resting_for is not None:  # the agy loop's rest (tools/agy-quota.py resting.json)
        open(os.path.join(ws, "resting.json"), "w").write(
            '{"since": %d, "until": %d, "reason": "pace", "sleep_s": 4500}' % (time.time() - 60, time.time() + resting_for))
    with open(os.path.join(ws, "journal.jsonl"), "w") as j:
        if last_request_ago is not None:
            j.write('{"at":"%s","event":"request","request":{"id":"a","action":"status","bot":"grok","args":{}}}\n'
                    % iso(last_request_ago))
            # A later response (a long --wait ending) is not a request.
            j.write('{"at":"%s","event":"response","response":{"id":"a","ok":true}}\n' % iso(0))
    env = dict(os.environ, POG_TEST="1", PATH=bindir + os.pathsep + os.environ["PATH"], FAKE_HERDR_LOG=os.path.join(tmp, "herdr.log"),
               POG_SUPERVISE_QUIET="1", POG_SUPERVISE_POLL="1")
    proc = subprocess.Popen(["bash", SUPERVISE, "p1", ws], env=env)
    time.sleep(4)
    proc.terminate()
    proc.wait()
    log = open(os.path.join(ws, "supervisor.log")).read() if os.path.exists(os.path.join(ws, "supervisor.log")) else ""
    calls = open(os.path.join(tmp, "herdr.log")).read() if os.path.exists(os.path.join(tmp, "herdr.log")) else ""
    return log, calls


def main():
    log, calls = run(10)
    assert "nudge 1" not in log and "agent prompt" not in calls, (log, calls)
    assert "skip nudge (status idle): last request 1" in log, log
    print("working agent (request 10 s ago): not nudged")
    log, calls = run(300)
    assert "nudge 1 (status idle" in log and "agent prompt" in calls, (log, calls)
    print("idle agent (request 5 min ago): nudged")
    log, calls = run(10, "claude")
    assert "nudge 1 (status idle" in log and "skip nudge" not in log, log
    print("claude agent idle (request 10 s ago): nudged, its turn has ended")
    log, calls = run(None)
    assert "nudge 1 (status idle" in log, log
    print("no journal yet: nudged")
    log, calls = run(10, deadline_in=-120)
    assert "nudge 1" not in log and "after the deadline (status idle): asking for the final summary" in log, log
    assert calls.count("agent prompt") == 1, calls
    print("after the deadline, turn ended: asked once for the final summary")
    log, calls = run(300, resting_for=3600)
    assert "nudge 1" not in log and "agent prompt" not in calls and "skip nudges: resting until" in log, (log, calls)
    assert log.count("skip nudges") == 1, log  # logged once per rest
    print("resting agent (pacing its quota): not nudged")
    log, calls = run(300, resting_for=-30)
    assert "nudge 1 (status idle" in log, log
    print("a rest that has ended: nudged as before")
    # (d22 batch108 BR1) a quota rest of two days (Grok's weekly limit): the log names the day it ends
    log, calls = run(300, resting_for=2 * 86400)
    assert "nudge 1" not in log and re.search(r"skip nudges: resting until (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d\d:\d\d ", log), log
    print("a two-day rest: not nudged, its day in the log")
    # the agent's own request after the rest began (it can play after all): the rest is over, nudged as before
    log, calls = run(30, "claude", resting_for=3600)
    assert "skip nudges" not in log and "nudge 1 (status idle" in log, log
    print("a request after the rest began: the rest is over")


if __name__ == "__main__":
    sys.exit(main())
