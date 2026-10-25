#!/usr/bin/env python3
"""The agents' wait cap (tools/sleepcap/): python3 tools/test_sleepcap.py

Runs with a 1 s cap (POG_SLEEP_CAP_SECONDS=1) instead of 60 s.
- Under tools/sleepcap/run: `sleep 3` in bash -c, bash -lc (path_helper reorders PATH: the exported function covers
  it), sh -c and zsh -c, `python3 -c "import time; time.sleep(3)"`, and a sleep from a Python subprocess wait 1 s and
  print the line once; zsh -lc is reported (not covered). Short waits, bad arguments, POG_SLEEP_CAP=0 (./fh, ./shot)
  and our own scripts (POG_SLEEP_CAP_EXEMPT) keep their waits. The interpreter's own sitecustomize still runs.
- Per harness: Claude's pane command runs under run and its SessionStart hook puts the shim first through
  CLAUDE_ENV_FILE (after context.py's hooks); Codex's workspace config sets the variables (shell_environment_policy);
  Grok's run script, Muse's and agy's launch go through run; ./fh and ./shot set POG_SLEEP_CAP=0.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SC = os.path.join(ROOT, "tools", "sleepcap")
RUN = os.path.join(SC, "run")
LINE = "./fh sleep N waits longer and wakes on tells, mentions and attacks"
sys.path.insert(0, SC)
import setup as sc_setup  # noqa: E402


def timed(cmd, env=None, cap="1"):
    e = dict(os.environ, POG_SLEEP_CAP_SECONDS=cap, POG_TEST="1")
    for k in ("POG_SLEEP_CAP", "POG_SLEEPCAP_BIN", "POG_SLEEP_CAP_EXEMPT"):
        e.pop(k, None)
    e.update(env or {})
    t = time.time()
    r = subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=60)
    return time.time() - t, r


def capped(cmd, env=None):
    took, r = timed(cmd, env)
    return took < 2.5 and r.stderr.count(LINE) == 1, took, r


def shells():
    covered = {"bash -c": ["bash", "-c", "sleep 3"], "bash -lc": ["bash", "-lc", "sleep 3"], "sh -c": ["sh", "-c", "sleep 3"],
               "zsh -c": ["zsh", "-c", "sleep 3"], "sleep 2m": ["bash", "-c", "sleep 2m"],
               "python3 -c": ["python3", "-c", "import time; time.sleep(3)"],
               "python3 from time import sleep": ["python3", "-c", "from time import sleep; sleep(3)"],
               "python3 subprocess sleep": ["python3", "-c", "import subprocess; subprocess.run(['sleep', '3'])"]}
    for name, cmd in covered.items():
        ok, took, r = capped([RUN] + cmd)
        assert ok, (name, round(took, 1), r.stderr)
    # A Python loop of long sleeps prints the line once.
    took, r = timed([RUN, "python3", "-c", "import time\nfor _ in range(2): time.sleep(3)"])
    assert took < 3.5 and r.stderr.count(LINE) == 1, (took, r.stderr)
    # zsh login shells: /etc/zprofile's path_helper puts /bin first and zsh imports no functions.
    ok, took, _ = capped([RUN, "zsh", "-lc", "sleep 3"])
    print(f"shells: ok (bash -c, bash -lc, sh -c, zsh -c, python3; zsh -lc {'capped' if ok else 'NOT capped'})")


def untouched():
    # Short waits, bad arguments, the cap off (./fh, ./shot), and our own scripts.
    took, r = timed([RUN, "bash", "-c", "sleep 0.3"])
    assert 0.25 < took < 1 and LINE not in r.stderr, (took, r.stderr)
    took, r = timed([RUN, "bash", "-c", "sleep abc"])
    assert r.returncode != 0 and LINE not in r.stderr, r
    took, r = timed([RUN, "bash", "-c", "export POG_SLEEP_CAP=0; sleep 1.6; python3 -c 'import time; time.sleep(1.6)'"])
    assert took >= 3.1 and LINE not in r.stderr, (took, r.stderr)
    tmp = tempfile.mkdtemp(prefix="sleepcap")
    try:
        ours = os.path.join(tmp, "tools")
        os.makedirs(ours)
        open(os.path.join(ours, "wait.sh"), "w").write("#!/bin/bash\nsleep 1.6\n")
        open(os.path.join(ours, "wait.py"), "w").write("import time\ntime.sleep(1.6)\n")
        os.chmod(os.path.join(ours, "wait.sh"), 0o755)
        # run sets the exemption to this checkout's tools/, bin/, vendor/; the test points it at its own folder
        cmd = f"export POG_SLEEP_CAP_EXEMPT={ours}; {ours}/wait.sh; python3 {ours}/wait.py"
        took, r = timed([RUN, "bash", "-c", cmd])
        assert took >= 3.1 and LINE not in r.stderr, (took, r.stderr)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # The interpreter's own sitecustomize still runs (Homebrew's adds its site-packages to sys.path).
    probe = "import sys; print([p for p in sys.path if 'site-packages' in p])"
    _, plain = timed(["python3", "-c", probe])
    _, wrapped = timed([RUN, "python3", "-c", probe])
    assert plain.stdout == wrapped.stdout, (plain.stdout, wrapped.stdout)
    print("untouched: ok (short, bad arguments, POG_SLEEP_CAP=0, our scripts, the interpreter's sitecustomize)")


def claude():
    tmp = tempfile.mkdtemp(prefix="sleepcap")
    try:
        os.makedirs(os.path.join(tmp, ".claude"))
        compact = {"matcher": "compact", "hooks": [{"type": "command", "command": "python3 context.py session-compact"}]}
        json.dump({"hooks": {"SessionStart": [compact]}}, open(os.path.join(tmp, ".claude", "settings.json"), "w"))
        sc_setup.claude(tmp)
        sc_setup.claude(tmp)  # once only
        starts = json.load(open(os.path.join(tmp, ".claude", "settings.json")))["hooks"]["SessionStart"]
        assert starts[0] == compact and len(starts) == 2 and "matcher" not in starts[1], starts
        hook = starts[1]["hooks"][0]["command"].strip("'")
        envfile = os.path.join(tmp, "env.sh")
        open(envfile, "w").close()
        # The hook writes nothing outside a capped launch, and the PATH line inside one.
        subprocess.run([hook], env=dict(os.environ, CLAUDE_ENV_FILE=envfile), check=True)
        assert open(envfile).read() == ""
        subprocess.run([RUN, hook], env=dict(os.environ, CLAUDE_ENV_FILE=envfile), check=True)
        assert open(envfile).read().startswith("export PATH=" + os.path.join(SC, "bin")), open(envfile).read()
        # As Claude Code runs a command: a login profile reordered PATH, then the env file is sourced.
        took, r = timed([RUN, "zsh", "-lc", f"source {envfile}; command -v sleep; sleep 3"])
        assert r.stdout.strip() == os.path.join(SC, "bin", "sleep") and took < 2.5, (r.stdout, took)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    src = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
    assert "$claude_vars '$sleepcap_run' /Users/owner/.local/bin/claude" in src
    context, cap = src.index('tools/context.py" setup claude'), src.index('tools/sleepcap/setup.py" claude')
    assert context < cap, "the hook goes in after context.py writes the hooks"
    print("claude: ok (pane command under run; SessionStart hook through CLAUDE_ENV_FILE)")


def codex():
    tmp = tempfile.mkdtemp(prefix="sleepcap")
    try:
        os.makedirs(os.path.join(tmp, ".codex"))
        open(os.path.join(tmp, ".codex", "config.toml"), "w").write("model_context_window = 272000\n")
        sc_setup.codex(tmp)
        sc_setup.codex(tmp)  # once only
        text = open(os.path.join(tmp, ".codex", "config.toml")).read()
        cfg = tomllib.loads(text)
        assert cfg["model_context_window"] == 272000 and text.count("[shell_environment_policy]") == 1
        env = cfg["shell_environment_policy"]["set"]
        assert env["PATH"].split(":")[0] == os.path.join(SC, "bin") and env["POG_SLEEP_CAP"] == "1"
        assert env["PYTHONPATH"].split(":")[0] == os.path.join(SC, "py") and "BASH_FUNC_sleep%%" in env
        # Codex's commands with these variables: bash -lc and python3 capped.
        for cmd in (["bash", "-lc", "sleep 3"], ["bash", "-c", "sleep 3"], ["python3", "-c", "import time; time.sleep(3)"]):
            ok, took, r = capped(cmd, env)
            assert ok, (cmd, took, r.stderr)
        ok, _, _ = capped(["zsh", "-lc", "sleep 3"], env)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    src = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
    assert 'tools/sleepcap/setup.py" codex "$dir"' in src
    print(f"codex: ok (workspace shell_environment_policy; bash -lc and python3 capped, zsh -lc {'capped' if ok else 'NOT capped'})")


def grok_muse_agy():
    tmp = tempfile.mkdtemp(prefix="sleepcap")
    try:
        # Grok: the launch's own run script, with a stand-in for the grok binary that sleeps.
        stub = os.path.join(tmp, "grok")
        open(stub, "w").write("#!/bin/bash\nsleep 3\n")
        os.chmod(stub, 0o755)
        script = (f". '{ROOT}/tools/profile-flags.sh'; grok_bin='{stub}'; "
                  f"grok_run_script '{tmp}' \"'$sleepcap_run'\" m low /dev/null rules")
        subprocess.run(["bash", "-c", script], check=True, cwd=ROOT)
        run = open(os.path.join(tmp, ".grok-run.sh")).read()
        assert f"'{RUN}' '{stub}'" in run, run
        ok, took, r = capped([os.path.join(tmp, ".grok-run.sh")])
        assert ok, (took, r.stderr)
        # agy: the loop's first turn runs agy under run; the loop's own quota sleep does not.
        loop = subprocess.run([os.path.join(ROOT, "tools", "launch-agent.sh"), "--agy-loop", tmp, "gemini", "0", "/dev/null"],
                              capture_output=True, text=True, check=True, env=dict(os.environ, POG_TEST="1"))
        text = open(os.path.join(tmp, ".agy-loop.sh")).read()
        assert f"'{RUN}' agy \"$@\"" in text and '*) sleep "$q" ;;' in text, text
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    src = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
    assert "exec env $muse_env '$sleepcap_run' muse" in src
    print("grok, muse, agy: ok (launch under run; agy's own quota wait untouched)")


def fh_and_shot():
    src = open(os.path.join(ROOT, "tools", "new-run.sh")).read()
    fh = src.split('cat > "$dir/fh" <<EOS', 1)[1].split("EOS", 1)[0]
    shot = src.split('cat > "$dir/shot" <<EOS', 1)[1].split("EOS", 1)[0]
    assert "export POG_SLEEP_CAP=0" in fh and "export POG_SLEEP_CAP=0" in shot
    print("fh and shot: ok (POG_SLEEP_CAP=0)")


if __name__ == "__main__":
    shells()
    untouched()
    claude()
    codex()
    grok_muse_agy()
    fh_and_shot()
