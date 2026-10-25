#!/usr/bin/env python3
"""An operator's quota rest, and start-team's for an account at its limit (d22 batch108 BR1, Grok's weekly limit at
20:04, reset Sat 15:59): python3 tools/test_quota_rest.py

1. tools/quota_rest.py RUN AGENT --until "YYYY-MM-DD HH:MM" writes resting.json and pushes the rest (until_s past a
   day, until_day for another date) to the world and bot ./fh names; --done ends it (resting-last.json, done pushed);
   past 7 days, in the past or a bad argument: refused, nothing written; a failed push: exit 1, the file kept.
2. --at-limit: each team member whose account quota_check reads at 99% or more with its reset ahead gets a quota rest
   until that reset; one below, a stale profile or a reset behind: nothing; --dry-run writes nothing.
3. tools/start-team.sh: the dry run's plan names the rests (5a.); the run itself saves the quota brief and writes the
   rests after the agents launch, before the supervisors and the idle nudger start.
No RCON and no live quota data: send_operator is replaced, the briefs are fixtures, POG_REST_PUSH=off for the CLI.
"""
import json
import testsafe  # noqa: E402  (d24 batch186: what a test runs a repo script with)
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import quota_rest  # noqa: E402

TOOL = os.path.join(ROOT, "tools", "quota_rest.py")
FH = '''#!/usr/bin/env bash
export POG_WORLD=n POG_FH_SOCKET="/x/runs/shift61/.sock/grok.sock"
exec "/x/bin/fh" "$@" --bot grok --journal "/x/runs/shift61/grok/journal.jsonl"
'''
TEAM = ("# name\tkind\troute\tmodel\teffort\tlabel\tharness\n"
        "astra\tcodex\t-\tgpt-6-astra\tlow\tGPT-6 Astra\tCodex\n"
        "grok\tgrok\t-\tgrok-4.7\tlow\tGrok 4.7\tGrok Build\n"
        "gemini\tagy\t-\tgemini-3.8-flash-high\t-\tGemini 3.8 Flash\tAntigravity\n")


def brief(now, grok_pct=99.0, grok_reset=158000, stale=False):
    w = lambda label, pct, reset: {"label": label, "percent": pct, "resets_at": now + reset, "duration_minutes": 10080}
    return {"generated_at": now, "profiles": [
        {"id": "grok_personal", "command": "grok", "stale": stale, "windows": [w("Grok · Weekly", grok_pct, grok_reset)]},
        {"id": "codex_account_a", "command": "codex", "windows": [w("Codex · Weekly", 50, 86400)]},
        # agy's Claude/GPT window at its limit does not count for Gemini
        {"id": "agy_local", "command": "agy", "windows": [w("Gemini · Weekly", 40, 3600), w("Claude/GPT · 5-hour", 100, 3600)]}]}


def cli(*args, env=None):
    e = dict(os.environ, POG_REST_PUSH="off", **(env or {}))
    return subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True, env=e, timeout=60)


def operator():
    with tempfile.TemporaryDirectory() as run:
        g = os.path.join(run, "grok")
        os.makedirs(g)
        open(os.path.join(g, "fh"), "w").write(FH)
        sent = []
        quota_rest.aq.send_operator = lambda world, req: sent.append((world, req))
        os.environ.pop("POG_REST_PUSH", None)
        now = time.time()
        until = now + 158039   # 20:04 Thursday to Sat 15:59
        line, ok = quota_rest.mark(g, until, "quota")
        assert ok and line.endswith("; pushed") and quota_rest.when(until) in line, line
        row = json.load(open(os.path.join(g, "resting.json")))
        assert row["reason"] == "quota" and abs(row["until"] - until) <= 1 and row["resets"] == quota_rest.when(until)
        (world, req), = sent
        a = req["args"]
        assert world == "n" and req["operator"] and req["action"] == "rest" and a["agent"] == "grok", req
        assert a["reason"] == "quota" and 158000 <= a["until_s"] <= 158039 and a["until_day"] in quota_rest.aq.DAYS, a
        assert a["until_clock"] == time.strftime("%H:%M", time.localtime(row["until"])), a
        # --done: resting-last.json, done pushed
        line, ok = quota_rest.done(g)
        assert ok and "rest ended" in line and not os.path.exists(os.path.join(g, "resting.json"))
        assert os.path.exists(os.path.join(g, "resting-last.json")) and sent[-1][1]["args"] == {"agent": "grok", "done": True}
        assert "no rest on record" in quota_rest.done(g)[0]
        # past 7 days or behind now: nothing written
        line, ok = quota_rest.mark(g, now + 8 * 86400, "quota")
        assert not ok and "at most 7 days" in line and not os.path.exists(os.path.join(g, "resting.json")), line
        assert not quota_rest.mark(g, now - 60, "quota")[1]
        # a failed push: said, the file kept, not ok
        def boom(world, req):
            raise RuntimeError("{'code': 'action_failed', 'message': 'until_s must be 1..86400 seconds'}")
        quota_rest.aq.send_operator = boom
        line, ok = quota_rest.mark(g, until, "quota")
        assert not ok and "not pushed: RuntimeError" in line and os.path.exists(os.path.join(g, "resting.json")), line
        # the command line: a run directory, --until local time, --reason; --done; refusals exit 2
        os.remove(os.path.join(g, "resting.json"))
        t = time.localtime(now + 2 * 86400)
        r = cli(run, "grok", "--until", time.strftime("%Y-%m-%d %H:%M", t), "--reason", "quota")
        assert r.returncode == 0 and "resting until " + quota_rest.aq.DAYS[t.tm_wday] in r.stdout, (r.stdout, r.stderr)
        assert "not pushed: off" in r.stdout and json.load(open(os.path.join(g, "resting.json")))["reason"] == "quota"
        r = cli(run, "grok", "--done")
        assert r.returncode == 0 and "rest ended" in r.stdout, r.stdout
        assert cli(run, "grok", "--until", "Sat 15:59").returncode == 2
        assert cli(run, "grok", "--until", "2026-10-24 15:59", "--reason", "nap").returncode == 2
        assert cli(run, "grok").returncode == 2
        assert cli(run, "nobody", "--done").returncode == 2
    print("operator command: ok (write, push, done, refusals)")


def limits():
    with tempfile.TemporaryDirectory() as tmp:
        team = os.path.join(tmp, "team.tsv")
        open(team, "w").write(TEAM)
        run = os.path.join(tmp, "runs", "shift61")
        for n in ("astra", "grok", "gemini"):
            os.makedirs(os.path.join(run, n))
        now = time.time()
        bf = os.path.join(tmp, "brief.json")
        import quota_check
        assert set(quota_check.at_limit(brief(now), team, now)) == {"grok"}
        assert quota_check.at_limit(brief(now, grok_pct=98.0), team, now) == {}
        assert quota_check.at_limit(brief(now, stale=True), team, now) == {}
        assert quota_check.at_limit(brief(now, grok_reset=-60), team, now) == {}
        json.dump(brief(now), open(bf, "w"))
        r = cli("--at-limit", run, team, "--brief", bf, "--dry-run")
        assert r.returncode == 0 and r.stdout.startswith("quota rest: grok would rest until "), r.stdout
        assert not os.path.exists(os.path.join(run, "grok", "resting.json"))
        r = cli("--at-limit", run, team, "--brief", bf)
        assert r.returncode == 0 and r.stdout.count("quota rest: ") == 1 and "grok: resting until" in r.stdout, r.stdout
        assert "grok_personal Grok · Weekly 99%" in r.stdout, r.stdout
        row = json.load(open(os.path.join(run, "grok", "resting.json")))
        assert row["reason"] == "quota" and abs(row["until"] - (now + 158000)) <= 2, row
        assert not os.path.exists(os.path.join(run, "astra", "resting.json"))
        # nobody at the limit; no saved brief
        json.dump(brief(now, grok_pct=60), open(bf, "w"))
        r = cli("--at-limit", run, team, "--brief", bf)
        assert r.returncode == 0 and r.stdout.startswith("quota rests: no agent's account at its limit"), r.stdout
        r = cli("--at-limit", run, team, "--brief", os.path.join(tmp, "missing.json"))
        assert r.returncode == 0 and "no quota data saved" in r.stdout, r.stdout
    print("at the limit: ok (99% with its reset ahead rests until the reset; the others nothing)")


def start_team():
    src = open(os.path.join(ROOT, "tools", "start-team.sh")).read()
    run_part = src[src.index('rundir="runs/$run"; mkdir -p "$rundir"'):]
    assert 'quota --save "$rundir/quota-brief.json"' in run_part
    at = run_part.index("tools/quota_rest.py --at-limit")
    assert run_part.index('done < "$team"') < at < run_part.index("tools/supervise.sh") < run_part.index("idle_nudge.py")
    assert run_part.index("bin/fh deploy") < at  # the runtime is up for the push
    with tempfile.TemporaryDirectory() as tmp:
        team = os.path.join(tmp, "team.tsv")
        open(team, "w").write(TEAM)
        qb = os.path.join(tmp, "brief.json")
        json.dump(brief(time.time()), open(qb, "w"))
        env = testsafe.env(POG_DRY_RUN="1", POG_TEAM_FILE=team, POG_CASTER="0", POG_ANALYST="0", POG_OBS="0",
                   POG_QUOTA_BRIEF=qb, POG_QUOTA_BURN=os.path.join(tmp, "no-burn.tsv"))
        env.pop("POG_RESUME", None)
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "restdry-test", "10"], env=env,
                           capture_output=True, text=True, cwd=ROOT, timeout=300)
        assert r.returncode == 0, r.stderr
        lines = [l for l in r.stdout.splitlines() if l.startswith("5a. ")]
        assert len(lines) == 1 and lines[0].startswith("5a. quota rest: grok would rest until "), r.stdout
    assert not os.path.exists(os.path.join(ROOT, "runs", "restdry-test"))  # a dry run touches nothing
    print("start-team: ok (the plan names the rests; written after the agents launch, before the supervisors)")


if __name__ == "__main__":
    operator()
    limits()
    start_team()
    print("test_quota_rest: ok")
