#!/usr/bin/env python3
"""tools/agy_memguard.py (d22 09:27: one agy turn of Gemini's grew to 21 GiB and filled the Mac's swap):
python3 tools/test_agy_memguard.py

1. Which processes it watches: only descendants of a real "bash .../runs/RUN/NAME/.agy-loop.sh" (the loop and its
   subshell are never killed); the loop's path as text in another command line (an editor, a grep, an argument) is
   not a loop; --root keeps it to one directory.
2. The cap on the footprint (rss when the footprint cannot be read); TERM, then KILL after the grace period.
3. Real processes in a scratch runs/ tree (--once --root, a tiny cap): a loop's child that ignores TERM is killed
   (log: TERM then KILL; context.log: event agy-memguard), a process with the loop's path in its arguments is not.
4. One per Mac: a running guard holds the lock (running() finds its pid and log); a second exits at once; a guard
   started by hand before the lock is found by its command line.
5. tools/start-team.sh: a team with an agy agent has the guard in its plan (POG_DRY_RUN=1: running or not on this
   Mac, and its log under the run).
"""
import json, os, signal, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import agy_memguard as g  # noqa: E402

GiB = 2**30


def which():
    rows = {
        10: (1, 0, "/bin/bash /Users/w/code/pog/runs/shift57/gemini/.agy-loop.sh"),
        11: (10, 0, "bash /Users/w/code/pog/runs/shift57/gemini/.agy-loop.sh"),  # the loop's subshell
        12: (11, 0, "/opt/homebrew/bin/agy --model gemini-3-pro --print-timeout 300s"),
        13: (12, 0, "git ls-files --others --exclude-standard"),
        20: (1, 0, "vim /Users/w/code/pog/runs/shift57/gemini/.agy-loop.sh"),
        21: (20, 0, "/opt/homebrew/bin/agy --model x"),
        22: (1, 0, "grep bash /Users/w/code/pog/runs/shift57/gemini/.agy-loop.sh"),
        23: (1, 0, "bash -c 'bash /Users/w/code/pog/runs/shift57/gemini/.agy-loop.sh'"),
        24: (23, 0, "agy"),
        30: (1, 0, "/opt/homebrew/bin/agy --model mine"),  # the owner's own agy session
    }
    ws = "/Users/w/code/pog/runs/shift57/gemini"
    assert g.loop_of(12, rows) == ws and g.loop_of(13, rows) == ws
    for pid in (10, 11, 20, 21, 22, 23, 24, 30):
        assert g.loop_of(pid, rows) is None, pid
    sizes = {12: 21 * GiB, 13: 3 * GiB, 21: 30 * GiB, 30: 30 * GiB, 10: 9 * GiB, 11: 9 * GiB}
    assert g.over_cap(rows, 4 * GiB, size=sizes.get) == [(12, 21 * GiB, ws)]
    assert g.over_cap(rows, 2 * GiB, size=sizes.get) == [(12, 21 * GiB, ws), (13, 3 * GiB, ws)]
    assert g.over_cap(rows, 4 * GiB, root="/Users/w/code/other", size=sizes.get) == []
    # no footprint read: the rss from ps
    rows2 = {**rows, 13: (12, 5 * GiB, "git ls-files --others")}
    assert g.over_cap(rows2, 4 * GiB, size=lambda pid: None) == [(13, 5 * GiB, ws)]
    print("which: ok")


def term_then_kill():
    sent, alive, said = [], {7: True}, []

    def kill(pid, sig):
        sent.append(sig)
        if not alive.get(pid):
            raise ProcessLookupError
        if sig == signal.SIGTERM and pid == 7:
            alive[pid] = False  # it ends on TERM
    assert g.stop(7, 1.0, said.append, kill, lambda s: None) == "TERM" and sent[0] == signal.SIGTERM
    assert signal.SIGKILL not in sent and not said
    sent.clear()
    alive[8] = True  # it ignores TERM

    def kill2(pid, sig):
        sent.append(sig)
        if sig == signal.SIGKILL:
            alive[pid] = False
    assert g.stop(8, 1.0, said.append, kill2, lambda s: None) == "KILL", sent
    assert sent[0] == signal.SIGTERM and sent[-1] == signal.SIGKILL and said == ["pid 8: KILL"], (sent, said)
    print("term then kill: ok")


def real():
    with tempfile.TemporaryDirectory() as root:
        ws = os.path.join(root, "runs", "zz-memguard", "gemini")
        os.makedirs(ws)
        loop = os.path.join(ws, ".agy-loop.sh")
        with open(loop, "w") as f:
            f.write("#!/bin/bash\n" + f"exec 1>/dev/null\n'{sys.executable}' -c 'import signal, time; "
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'\n")
        lp = subprocess.Popen(["bash", loop], start_new_session=True, stderr=subprocess.DEVNULL)
        decoy = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", f"bash {loop}"],
                                 start_new_session=True)
        try:
            child = None
            for _ in range(50):
                rows = g.table()
                child = next((p for p, r in rows.items() if r[0] == lp.pid), None)
                if child:
                    break
                time.sleep(0.1)
            assert child, "the loop's child did not start"
            log = os.path.join(root, "agy-memguard.log")
            r = subprocess.run([sys.executable, os.path.join(HERE, "agy_memguard.py"), "--once", "--root", root,
                                "--cap-gb", "0.0001", "--grace", "1", "--log", log], capture_output=True, text=True,
                               timeout=30)
            assert r.returncode == 0, r.stderr
            text = open(log).read()
            assert f"pid {child} " in text and f"in {ws}: TERM" in text and f"pid {child}: KILL" in text, text
            assert f"pid {decoy.pid}" not in text and f"pid {lp.pid} " not in text, text
            ev = [json.loads(l) for l in open(os.path.join(ws, "context.log"))]
            assert ev[-1]["event"] == "agy-memguard" and ev[-1]["pid"] == child and ev[-1]["ended_by"] == "KILL", ev
            assert ev[-1]["cap_gb"] == 0.0001 and ev[-1]["footprint_gb"] >= 0, ev
            assert decoy.poll() is None, "the decoy was killed"
        finally:
            for p in (lp, decoy):
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                p.wait()
    print("real processes: ok")


def one_per_mac():
    with tempfile.TemporaryDirectory() as root:
        lock, log = os.path.join(root, "guard.lock"), os.path.join(root, "guard.log")
        assert g.running(lock, rows={}) is None
        cmd = [sys.executable, os.path.join(HERE, "agy_memguard.py"), "--lock", lock, "--root", root, "--every", "0.2",
               "--log", log]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(50):
                if os.path.exists(log) and "agy_memguard: cap" in open(log).read():
                    break
                time.sleep(0.1)
            assert g.running(lock, rows={}) == (p.pid, log), g.running(lock, rows={})
            second = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            assert second.returncode == 0 and "already running" in second.stdout, second
            assert open(log).read().count("agy_memguard: cap") == 1
        finally:
            p.terminate()
            p.wait()
        assert g.running(lock, rows={}) is None  # the lock goes with the process
    hand = {123: (1, 0, "/opt/homebrew/Cellar/python@3.14/3.14.8_2/Frameworks/Python.framework/Versions/3.14/Resources/"
                        "Python.app/Contents/MacOS/Python tools/agy_memguard.py --cap-gb 4")}
    assert g.running("/nonexistent/lock", rows=hand) == (123, "(started by hand, no lock)")
    assert g.running("/nonexistent/lock", rows={9: (1, 0, "python3 tools/agy_memguard.py --check")}) is None
    print("one per Mac: ok")


def start_team():
    with tempfile.TemporaryDirectory() as tmp:
        team = os.path.join(tmp, "team.tsv")
        open(team, "w").write("# name\tkind\troute\tmodel\teffort\tlabel\tharness\n"
                              "gemini\tagy\t-\tgemini-3.8-flash-high\t-\tGemini 3.8 Flash\tAntigravity\n")
        qb = os.path.join(tmp, "brief.json")
        json.dump({"profiles": []}, open(qb, "w"))
        env = dict(os.environ, POG_DRY_RUN="1", POG_TEAM_FILE=team, POG_CASTER="0", POG_ANALYST="0",
                   POG_QUOTA_BRIEF=qb, POG_QUOTA_BURN=os.path.join(tmp, "no-burn.tsv"))
        env.pop("POG_RESUME", None)
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "memguard-dry-test", "10"], env=env,
                           capture_output=True, text=True, cwd=ROOT, timeout=300)
        assert r.returncode == 0, r.stderr
        line = next((l for l in r.stdout.splitlines() if l.startswith("4d. ")), "")
        assert line.startswith("4d. agy memory guard (an agy agent in the team): agy memory guard ") and \
            line.endswith("; started if not, log runs/memguard-dry-test/agy-memguard.log"), r.stdout
    assert not os.path.exists(os.path.join(ROOT, "runs", "memguard-dry-test"))  # a dry run touches nothing
    print("start-team plan: ok")


if __name__ == "__main__":
    which()
    term_then_kill()
    real()
    one_per_mac()
    start_team()
    print("agy_memguard: ok")
