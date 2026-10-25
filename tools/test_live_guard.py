#!/usr/bin/env python3
"""No test touches the live stream, site or world (d24 batch186, operator 18:38: tools/test_shift_recovery.py's copy of
stop-team.sh stopped the live site pusher on every gate run, 18:03-18:32): python3 tools/test_live_guard.py

The gate runs every test in the live checkout, so a test's ROOT is the live one. Under POG_TEST=1 (tools/testsafe.py
env()) the tools that reach live things refuse their live defaults; checked here with their network and box calls
stubbed, so even a tool without the guard touches nothing:
1. tools/pog.py: Rcon refuses a world's port (PORTS) before connecting;
2. tools/obs.py: client() refuses before reading obs.pw or connecting to 4455;
3. tools/winps.sh and tools/shot-sync.sh: no ssh or scp to pogwin (ssh and scp stand-ins on PATH log any call);
4. tools/start-team.sh marks a plan-only run (POG_DRY_RUN=1 or POG_TEST=1) for tools/shift-change.sh, which counts
   only unmarked start-teams in its checkout; start-team's pusher check counts only this checkout's pushers;
5. every gate test that runs a repo shell script passes testsafe.env() or sets POG_TEST=1 (a scan), apart from those
   listed in ALLOWED with why.
The others are checked where they are exercised: stop-team.sh's OBS (tools/test_shift_recovery.py), new-run.sh's
password copy (tools/test_broker.py), obs-recover.sh's lock (tools/test_obs_restart.py), site/build.py's runs folder
(site/test_live.py).
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import testsafe  # noqa: E402

# tests that name a repo shell script but run none of it against anything (read its text, bash -n, opt-in)
ALLOWED = {
    "tools/test_console_audit.py": "bash -n on stop-team.sh only",
    "tools/test_public_export.py": "a temp git repo whose tools/*.sh are fixture text",
    "tools/test_resume_save.py": "skips unless POG_WIN_TESTS=1 (it uses the real box on purpose)",
    "tools/test_handover.py": "reads the scripts' text",
    "tools/test_rest_carry.py": "reads start-team.sh's text",
    "tools/test_live_guard.py": "this file",
}


def py(code, env):
    return subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=60, cwd=ROOT)


def rcon():
    # the connection itself is a stand-in that fails the check: nothing leaves the process
    code = ("import socket,sys; sys.path.insert(0,'tools')\n"
            "def no(*a, **k): raise AssertionError('connected to ' + repr(a[0]))\n"
            "socket.create_connection = no\n"
            "import pog\n"
            "try:\n    pog.Rcon('127.0.0.1', pog.PORTS['n'], 'x')\n"
            "except SystemExit as e:\n    print('refused:', e)\n")
    r = py(code, testsafe.env())
    assert r.returncode == 0 and "refused: POG_TEST=1: no RCON to port 27025" in r.stdout, r.stdout + r.stderr
    # a test's own fake server (a port no world has) is not refused
    r = py(code.replace("pog.PORTS['n']", "1"), testsafe.env())
    assert "connected to ('127.0.0.1', 1)" in r.stderr, r.stdout + r.stderr
    print("pog.py RCON: ok")


def obs():
    code = ("import sys, types; sys.path.insert(0,'tools')\n"
            "m = types.ModuleType('obsws_python'); m.ReqClient = lambda **k: (_ for _ in ()).throw(AssertionError('OBS'))\n"
            "sys.modules['obsws_python'] = m\n"
            "import builtins; real = builtins.open\n"
            "def guarded(p, *a, **k):\n"
            "    if str(p).endswith('obs.pw'): raise AssertionError('read obs.pw')\n"
            "    return real(p, *a, **k)\n"
            "builtins.open = guarded\n"
            "import obs\n"
            "try:\n    obs.client()\n"
            "except SystemExit as e:\n    print('refused:', e)\n")
    r = py(code, testsafe.env())
    assert r.returncode == 0 and "refused: POG_TEST=1: tools/obs.py does not connect to OBS" in r.stdout, r.stdout + r.stderr
    print("obs.py client: ok")


def box():
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "calls.log")
        for name in ("ssh", "scp"):
            p = os.path.join(tmp, name)
            open(p, "w").write(f'#!/bin/sh\necho "{name} $*" >> "{log}"\n')
            os.chmod(p, 0o755)
        env = testsafe.env(PATH=tmp + os.pathsep + os.environ["PATH"])
        script = os.path.join(tmp, "x.ps1")
        open(script, "w").write("Write-Output hi\n")
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "winps.sh"), script], env=env, capture_output=True,
                           text=True, timeout=60)
        assert r.returncode == 3 and "winps.sh does not reach pogwin in a test run" in r.stderr, r.stdout + r.stderr
        run = os.path.join(tmp, "run")
        os.makedirs(run)
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "shot-sync.sh"), run, "n-client-cam1"], env=env,
                           capture_output=True, text=True, timeout=60)
        assert r.returncode == 3 and "shot-sync.sh does not reach pogwin" in r.stderr, r.stdout + r.stderr
        assert not os.path.exists(log), open(log).read()
    print("winps.sh and shot-sync.sh: ok")


def plans():
    start = open(os.path.join(ROOT, "tools", "start-team.sh")).read()
    change = open(os.path.join(ROOT, "tools", "shift-change.sh")).read()
    mark = 'plan_mark="${TMPDIR:-/tmp}/pog-start-team-plan.$$"'
    assert mark in start and start.index(mark) < start.index("run=$1 minutes=$2"), "start-team marks a plan first"
    assert '[ ! -e "${TMPDIR:-/tmp}/pog-start-team-plan.$p" ]' in change, "shift-change skips a marked start-team"
    assert 'for pid in $(pgrep -f "site/push_live.py --source" || true); do' in start and '-d cwd -Fn' in start
    # a dry run takes its mark away when it ends (POG_DRY_RUN=1 with a run name that stops it at its first check)
    before = set(glob.glob(os.path.join(tempfile.gettempdir(), "pog-start-team-plan.*")))
    with tempfile.TemporaryDirectory() as tmp:
        team = os.path.join(tmp, "team.tsv")
        open(team, "w").write("# name\tkind\troute\tmodel\teffort\tlabel\tharness\n")
        subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "zz-guard", "1"], cwd=ROOT,
                       env=testsafe.env(POG_DRY_RUN="1", POG_TEAM_FILE=team, POG_RESUME="zz-guard"),
                       capture_output=True, text=True, timeout=120)
    after = set(glob.glob(os.path.join(tempfile.gettempdir(), "pog-start-team-plan.*")))
    assert after <= before, sorted(after - before)
    print("start-team plans and pushers: ok")


SCRIPT = re.compile(r'''["']tools["']\s*,\s*["'][\w.-]+\.sh["']|tools/[\w.-]+\.sh''')


def scan():
    bad = []
    for path in sorted(glob.glob(os.path.join(ROOT, "tools", "test_*.py")) + glob.glob(os.path.join(ROOT, "tools", "stream", "test_*.py"))
                       + glob.glob(os.path.join(ROOT, "site", "test_*.py"))):
        rel = os.path.relpath(path, ROOT)
        text = open(path).read()
        if rel in ALLOWED or not SCRIPT.search(text) or not re.search(r"subprocess\.|Popen", text):
            continue
        if "testsafe.env(" not in text and 'POG_TEST="1"' not in text and "POG_TEST='1'" not in text \
                and '"POG_TEST"] = "1"' not in text:
            bad.append(rel)
    assert not bad, "these tests run a repo shell script without testsafe.env() or POG_TEST=1: " + ", ".join(bad)
    print("tests that run scripts: ok")


if __name__ == "__main__":
    rcon()
    obs()
    box()
    plans()
    scan()
    print("test_live_guard: ok")
