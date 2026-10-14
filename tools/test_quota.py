#!/usr/bin/env python3
"""Tests for tools/quota_check.py and tools/agy-quota.py (run: python3 tools/test_quota.py)."""
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import quota_check  # noqa: E402

TEAM = "astra\tcodex\tcodex-b\tgpt-6-astra\tlow\tA\tCodex\ngemini\tagy\t-\tgemini-3.8-flash-high\t-\tG\tAntigravity\n"


def brief(gemini_pct, reset_in):
    now = 1_791_710_460   # 2026-10-11 05:21 PDT, shake5's start
    w = lambda label, pct, reset: {"label": label, "percent": pct, "resets_at": now + reset, "duration_minutes": 300}
    return now, {"profiles": [
        {"id": "codex_account_b", "command": "codex-b", "windows": [w("Codex · Weekly", 13, 86400)]},
        {"id": "agy_local", "command": "agy", "windows": [w("Gemini · 5-hour", gemini_pct, reset_in),
                                                           w("Claude/GPT · 5-hour", 0, 3600)]}]}


def main():
    with tempfile.TemporaryDirectory() as d:
        team = os.path.join(d, "team.tsv")
        open(team, "w").write(TEAM)
        # Gemini at 95%, resetting in 1h54m; at 8%/h (agent/quota-burn.tsv) it runs dry 37.5 minutes into a one-hour shift.
        now, b = brief(95, 6840)
        lines = quota_check.check(b, team, 60, now)
        warn = [l for l in lines if l.startswith("WARNING")]
        assert len(warn) == 1 and "Gemini · 5-hour" in warn[0], lines
        assert f"at about {time.strftime('%H:%M', time.localtime(now + 5 / 8 * 3600))}" in warn[0], warn
        assert not any("Claude/GPT" in l for l in lines), "agy's Claude/GPT window does not count for Gemini"
        assert any(l.startswith("quota codex_account_b (astra)") and l.endswith("ok (about 14% at "
                   + time.strftime("%H:%M", time.localtime(now + 3600)) + ")") for l in lines), lines
        # Full now, resetting 20 minutes into a two-hour run: warns (dry now).
        now, b = brief(100, 1200)
        warn = [l for l in quota_check.check(b, team, 120, now) if l.startswith("WARNING")]
        assert len(warn) == 1 and "run dry now" in warn[0] and "it resets at" in warn[0], warn
        # Plenty of room: no warning.
        now, b = brief(10, 6000)
        assert not [l for l in quota_check.check(b, team, 60, now) if l.startswith("WARNING")]
        # An unknown route warns instead of failing.
        open(team, "a").write("x\tclaude\tnosuch\thaiku\tlow\tX\tClaude Code\n")
        assert any("no ai-usage profile" in l for l in quota_check.check(b, team, 60, now))
        # The script prints a data note first and never fails.
        bf = os.path.join(d, "brief.json")
        json.dump(b, open(bf, "w"))
        out = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "quota_check.py"), team, "60", "--brief", bf,
                              "--now", str(now)], capture_output=True, text=True)
        assert out.returncode == 0 and out.stdout.startswith("quota data: from "), out
    print("quota_check: ok")
    agy_loop()


# A fake agy: logs its arguments; run 1 hits the quota (resets in 2 s), run 2 plays, run 3 hits a quota that resets
# after the deadline. agy writes one log per run naming its workspace, as the real one does.
FAKE_AGY = r'''#!/usr/bin/env python3
import os, sys, time
calls = os.path.join(os.environ["FAKE_DIR"], "calls.log")
n = sum(1 for _ in open(calls)) + 1 if os.path.exists(calls) else 1
open(calls, "a").write(" ".join(sys.argv[1:3]) + "\n")
def quota(reset):
    t = time.localtime()
    stamp = time.strftime("%m%d %H:%M:%S", t)
    log = os.path.join(os.environ["POG_AGY_LOGS"], f"cli-{n}.log")
    open(log, "w").write(
        f"I{stamp}.000001       1 server.go:334] Creating CLI server backend: product=antigravity "
        f"workspaceDirs=[{os.path.realpath(os.getcwd())}] appDataDir=x\n"
        f"E{stamp}.000002   31004 errorreport.go:224] agent executor error: generating and executing: "
        f"RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade. Resets in {reset}.\n")
if n == 1:
    quota("2s")
elif n == 2:
    time.sleep(1.5)
else:
    quota("5h0m0s")
'''


def agy_loop():
    with tempfile.TemporaryDirectory() as d:
        ws, logs, bindir = os.path.join(d, "ws"), os.path.join(d, "logs"), os.path.join(d, "bin")
        for p in (ws, logs, bindir):
            os.makedirs(p)
        open(os.path.join(bindir, "agy"), "w").write(FAKE_AGY)
        os.chmod(os.path.join(bindir, "agy"), 0o755)
        open(os.path.join(ws, "deadline.txt"), "w").write(time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(time.time() + 1800)) + "\n")
        prompt = os.path.join(d, "prompt.md")
        open(prompt, "w").write("Play.\n")
        subprocess.run(["bash", os.path.join(ROOT, "tools", "launch-agent.sh"), "--agy-loop", ws, "gemini-x", "200000",
                        prompt], check=True)
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], FAKE_DIR=d, POG_AGY_LOGS=logs,
                   POG_AGY_SLACK="0", POG_AGY_MIN_WAIT="1", POG_AGY_RETRY_WAIT="0")
        t0 = time.time()
        r = subprocess.run([os.path.join(ws, ".agy-loop.sh")], env=env, capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, r.stderr
        calls = open(os.path.join(d, "calls.log")).read().splitlines()
        # The first prompt again after the quota wait (no conversation began), then Continue; the last 429 stops it.
        assert calls == ["-p Play.", "-p Play. The deadline is 30 minutes away.", "-c -p"] or \
            (len(calls) == 3 and calls[0] == "-p Play." and calls[1].startswith("-p Play. The deadline is")
             and calls[2] == "-c -p"), calls
        events = [json.loads(l) for l in open(os.path.join(ws, "context.log"))]
        assert [e["event"] for e in events] == ["agy-quota", "agy-quota-stop"], events
        assert "Individual quota reached" in events[0]["error"] and events[0]["sleep"] >= 1, events
        assert time.time() - t0 < 30, "slept on the quota, did not spin"
    print("agy loop on a quota error: ok")


# A fake agy for the turn timeout: logs the prompt's first words and the --print-timeout it got; its context grows
# 30K a turn (a fresh -p turn starts at 30K); runs 1, 2 and 4 last until the timeout (a turn the timeout ends), run
# 3 ends by itself at once, run 6 hits a quota that resets after the deadline (the loop stops).
FAKE_AGY_TIMEOUT = r'''#!/usr/bin/env python3
import os, sys, time
d = os.environ["FAKE_DIR"]
calls = os.path.join(d, "calls.log")
n = sum(1 for _ in open(calls)) + 1 if os.path.exists(calls) else 1
args = sys.argv[1:]
timeout = args[args.index("--print-timeout") + 1] if "--print-timeout" in args else "-"
prompt = args[args.index("-p") + 1]
open(calls, "a").write(("-c " if "-c" in args else "") + " ".join(prompt.split()[:4]) + " | " + timeout + "\n")
tok = os.path.join(d, "tokens")
cur = int(open(tok).read()) if os.path.exists(tok) else 0
open(tok, "w").write(str(30000 if "-c" not in args else cur + 30000))
if n == 6:
    stamp = time.strftime("%m%d %H:%M:%S", time.localtime())
    open(os.path.join(os.environ["POG_AGY_LOGS"], f"cli-{n}.log"), "w").write(
        f"I{stamp}.000001       1 server.go:334] Creating CLI server backend: product=antigravity "
        f"workspaceDirs=[{os.path.realpath(os.getcwd())}] appDataDir=x\n"
        f"E{stamp}.000002   31004 errorreport.go:224] agent executor error: RESOURCE_EXHAUSTED (code 429): "
        f"Individual quota reached. Resets in 5h0m0s.\n")
elif n != 3 and timeout != "-":
    time.sleep(float(timeout.rstrip("s")))
'''


def agy_turn_timeout():
    """The operator's launch-line edit (--print-timeout ${POG_AGY_TURN_S:-300}s on the agy line) ends each turn after
    turn_s: a turn that ran into it is continued with one short line; one that ended by itself gets the full
    Continue; past compact_at the next turn is a fresh conversation (docs/studies/2026-10-13-agent-minds.md Q3.1)."""
    launch = os.environ.get("POG_TEST_LAUNCH_AGENT") or os.path.join(ROOT, "tools", "launch-agent.sh")
    src = open(launch).read()
    agy_line = next((l for l in src.splitlines() if " agy \"\\$@\" " in l), "")
    if "--print-timeout" not in agy_line:
        print("agy turn timeout: SKIPPED (the agy line has no --print-timeout yet: the operator's edit)")
        return
    with tempfile.TemporaryDirectory() as d:
        ws, logs, bindir = os.path.join(d, "ws"), os.path.join(d, "logs"), os.path.join(d, "bin")
        for p in (ws, logs, bindir):
            os.makedirs(p)
        open(os.path.join(bindir, "agy"), "w").write(FAKE_AGY_TIMEOUT)
        os.chmod(os.path.join(bindir, "agy"), 0o755)
        tokens = os.path.join(bindir, "tokens")  # the context size the fake reports (context.py agy-tokens's stand-in)
        open(tokens, "w").write('#!/usr/bin/env bash\ncat "$FAKE_DIR/tokens" 2>/dev/null || echo 0\n')
        os.chmod(tokens, 0o755)
        open(os.path.join(ws, "deadline.txt"), "w").write(time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(time.time() + 1800)) + "\n")
        prompt = os.path.join(d, "prompt.md")
        open(prompt, "w").write("Play.\n")
        subprocess.run(["bash", launch, "--agy-loop", ws, "gemini-x", "100000",
                        prompt], check=True, env=dict(os.environ, POG_AGY_TURN_S="4"))
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], FAKE_DIR=d, POG_AGY_LOGS=logs,
                   POG_AGY_SLACK="0", POG_AGY_MIN_WAIT="1", POG_AGY_RETRY_WAIT="0", POG_AGY_TOKENS_CMD=tokens)
        r = subprocess.run([os.path.join(ws, ".agy-loop.sh")], env=env, capture_output=True, text=True, timeout=90)
        assert r.returncode == 0, r.stderr
        calls = open(os.path.join(d, "calls.log")).read().splitlines()
        assert calls == ["Play. | 4s",                                      # 30K, ran into the timeout
                         "-c Continue where you were: | 4s",               # 60K, ran into it again
                         "-c Continue where you were: | 4s",               # 90K, ended by itself
                         "-c Continue: the deadline in | 4s",              # 120K
                         "Play. This is a | 4s",                           # past 100K: a fresh conversation
                         "-c Continue where you were: | 4s"], calls        # (its quota stops the loop)
        events = [json.loads(l)["event"] for l in open(os.path.join(ws, "context.log"))]
        assert events == ["agy-fresh", "agy-quota-stop"], events
    print("agy turn timeout: ok (short continue after a timed-out turn, full after one that ended, fresh past the limit)")


if __name__ == "__main__":
    main()
    agy_turn_timeout()
