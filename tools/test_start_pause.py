#!/usr/bin/env python3
"""Run start-team in a disposable checkout with stub launch/RCON/OBS/helpers; never contact a world or a pane.

The real start-cams loop sees connected clients at a fixed game tick. Every startup service and agent observes the
pause; resume follows the started log, even with failed launches. A failed deployment or later start releases it too.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import testsafe
from test_launch_resilience import write_exec

ROOT = Path(__file__).resolve().parent.parent
STUB = r'''
import json, os, signal, sys, time
from pathlib import Path

root = Path(os.environ["STUB_DIR"])
args = sys.argv[1:]
name = Path(sys.argv[0]).name
state = root / "paused"
resumed = bool(os.environ.get("POG_RESUME"))
failure = os.environ.get("FAIL_STAGE", "")

def event(stage, held=False):
    paused = state.exists()
    with (root / "events.jsonl").open("a") as f:
        f.write(json.dumps({"stage": stage, "paused": paused}) + "\n")
    if held:
        assert paused == resumed, (stage, paused, resumed)

if name == "python3":
    if args[0] in ("-", "-c") or args[0] in ("tools/cams.py", "tools/resume_guard.py"):
        os.execv(os.environ["REAL_PYTHON"], [os.environ["REAL_PYTHON"], *args])
    script, args = args[0], args[1:]
    if script == "tools/pog.py":
        assert args[:2] == ["--world", "stub-start"]
        cmd = args[2]
        if cmd == "pause":
            state.touch()
            event("pause")
            if failure == "pause": sys.exit(42)  # applied, reply lost
            print("paused at 123456")
        elif cmd == "resume":
            event("resume")
            if failure == "resume-once" and not (root / "retry").exists():
                (root / "retry").touch()
                sys.exit(1)
            state.unlink(missing_ok=True)
            log = (root / "runs/next/start.log").read_text()
            (root / "log-at-resume").write_text(log)
            print("resumed at 123456")
        elif cmd == "score":
            event("score", held=True)
            print(json.dumps({"tick": 1 if failure == "old-save" else 123456}))
        elif cmd == "rcon":
            event("shift-start", held=True)
            print('{}')
        else: raise AssertionError(args)
    elif script == "tools/code_check.py":
        print("FAILED" if failure == "deploy" and "--deploy-reply" in args else "ok stub")
    elif script == "tools/team_bots.py":
        event("bots", held=True)
        if failure == "bots": sys.exit(43)
        if failure == "term": os.kill(os.getppid(), signal.SIGTERM)
    elif script == "tools/quota_rest.py":
        event("rests", held=True)
    elif script in ("tools/quota_check.py", "tools/run_target.py", "tools/shift_times.py", "tools/progress.py",
                    "tools/expedition.py", "tools/full_tools.py"):
        print("1" if script == "tools/shift_times.py" else "stub")
    else: raise AssertionError(script)
elif name == "fh":
    if args[0] == "deploy": event("deploy", held=True)
    elif args != ["call", "describe"]: raise AssertionError(args)
    print('{}')
elif name == "winps.sh":
    script = Path(args[0]).name
    if script == "resume-save.ps1":
        print("space_age=0" if "-Check" in args else "copied=yes\nsave=prev.zip\nsave_time=now\nwhy=stop save")
    elif script == "new-instance.ps1": print("FullName stub")
    elif script == "start-client.ps1":
        event("camera-start", held=True)
        (root / "camera-joined").touch()
    elif script == "client-running.ps1": print("running")
    elif script not in ("stop-world.ps1", "start-server.ps1"): raise AssertionError(args)
elif name == "cam-rcon":
    event("camera-read", held=True)
    assert "connected" in args[0] and "tick" not in args[0], args
    print("joined" if (root / "camera-joined").exists() else "not yet")
elif name in ("cam-obs", "obs-steps.sh", "obs-restart.sh"):
    event(name, held=True)
    print("OBS answers")
elif name == "launch-agent.sh":
    agent = args[2]
    event("launch-" + agent, held=True)
    if agent == os.environ.get("FAIL_NAME") or os.environ.get("FAIL_NAME") == "all":
        print("stub launch failed", file=sys.stderr)
        sys.exit(1)
    d = root / "runs/next" / agent
    d.mkdir(parents=True)
    (d / "deadline.txt").write_text("stub deadline\n")
    print(f"w1:p{agent} w1:t1 {d}")
elif name == "clear-prompts.sh":
    event("prompts", held=True)
    if failure == "prompts": sys.exit(44)
elif name == "nohup":
    # Record the service launch; start no real daemon, tunnel, supervisor or subprocess.
    stage = "helper:" + " ".join(args[:2])
    event(stage, held="supervise" not in stage and "idle_nudge" not in stage and "score-loop" not in stage)
elif name == "sleep":
    # Give the stub background launches time to finish; never wait game ticks.
    time.sleep(0.3 if args == ["8"] else 0.01)
elif name == "git": print("stubcommit")
elif name == "scp": pass
else: raise AssertionError((name, args))
'''


def run_case(**over):
    with tempfile.TemporaryDirectory(prefix="pog-start-pause-") as tmp:
        d = Path(tmp)
        (d / "tools").mkdir()
        (d / "bin").mkdir()
        (d / "stubs").mkdir()
        for name in ("start-team.sh", "start-cams.sh", "cams.py", "shift_times.py", "resume_guard.py", "full_tools.py"):
            shutil.copy2(ROOT / "tools" / name, d / "tools" / name)
        for path in ("stubs/python3", "stubs/nohup", "stubs/sleep", "stubs/git", "stubs/scp", "stubs/cam-rcon",
                     "stubs/cam-obs", "bin/fh", "tools/winps.sh", "tools/launch-agent.sh", "tools/obs-restart.sh",
                     "tools/obs-steps.sh", "tools/clear-prompts.sh"):
            write_exec(d / path, f"#!{sys.executable}\n" + STUB)
        prev = d / "runs/prev"
        (prev / "astra").mkdir(parents=True)
        (prev / "astra/notes.md").write_text("previous shift\n")
        (prev / "stopped.json").write_text(json.dumps({"tick": 123456, "save": "prev.zip"}))
        team = d / "team.tsv"
        team.write_text("astra\tcodex\t-\tm\tlow\tAstra\tCodex\nsol\tcodex\t-\tm\tlow\tSol\tCodex\n")
        env = testsafe.env(PATH=f"{d}/stubs:{os.environ['PATH']}", STUB_DIR=tmp, REAL_PYTHON=sys.executable,
                           POG_RESUME="prev", POG_RESUME_DIR=str(prev), POG_TEAM_FILE=str(team),
                           POG_WORLD_NAME="stub-start", POG_CASTER="0", POG_ANALYST="0", POG_PUSH_LIVE="0",
                           POG_MAPFRAMES="0", POG_TRUSTED_PLAYERS="", POG_CAMS="1", POG_IDLE_NUDGE="0",
                           POG_CAM_RCON=str(d / "stubs/cam-rcon"), POG_CAM_OBS=str(d / "stubs/cam-obs"))
        env.update(over)
        r = subprocess.run(["bash", str(d / "tools/start-team.sh"), "next", "10", "--stream"],
                           env=env, capture_output=True, text=True, cwd=d, timeout=30)
        events = [json.loads(x) for x in (d / "events.jsonl").read_text().splitlines()]
        stages = [x["stage"] for x in events]
        log = (d / "runs/next/start.log").read_text()
        assert "AssertionError" not in r.stdout + r.stderr, (r.stdout, r.stderr)
        assert not (d / "paused").exists(), (stages, log, r.stderr)
        if not env["POG_RESUME"]:
            assert r.returncode == 0 and "pause" not in stages and "resume" not in stages, (stages, log, r.stderr)
        elif over.get("FAIL_STAGE") in ("deploy", "bots", "old-save", "pause", "term", "prompts"):
            assert r.returncode != 0 and stages[-1] == "resume", (stages, log, r.stderr)
            assert "started:" not in log and "start failed (exit " in log and "startup paused " in log, log
            if over.get("FAIL_STAGE") == "term": assert r.returncode == 143, (r.returncode, log)
        else:
            assert r.returncode == 0, (log, r.stderr)
            at = stages.index("resume")
            for stage in ("deploy", "camera-start", "camera-read", "cam-obs", "obs-restart.sh", "obs-steps.sh",
                          "bots", "launch-astra", "launch-sol", "rests"):
                assert stages.index("pause") < stages.index(stage) < at, (stage, stages)
            if over.get("FAIL_NAME") != "all": assert stages.index("prompts") < at, stages
            assert any(s.startswith("helper:python3 tools/stream/serve.py") for s in stages[:at]), stages
            count = 0 if over.get("FAIL_NAME") == "all" else 1 if over.get("FAIL_NAME") else 2
            assert f"started: {count}/2 agents" in (d / "log-at-resume").read_text(), log
            lines = log.splitlines()
            started = next(i for i, line in enumerate(lines) if " started: " in line)
            next_line = lines[started + 1]
            assert "startup paused " in next_line or "resume attempt 1 failed" in next_line, log
            assert "resumed at 123456; startup paused " in log and f"after started: {count}/2 agents" in log, log
            if count != 2: assert "resuming despite failed launches:" in log, log
        print(f"start pause: ok {over or 'all launched'}")


if __name__ == "__main__":
    run_case()
    run_case(FAIL_NAME="sol")
    run_case(FAIL_NAME="all")
    for failure in ("deploy", "bots", "old-save", "pause", "term", "prompts", "resume-once"):
        run_case(FAIL_STAGE=failure)
    run_case(POG_RESUME="")
    print("test_start_pause: ok")
