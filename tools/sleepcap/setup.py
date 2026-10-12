#!/usr/bin/env python3
"""Per-harness pieces of the wait cap (tools/sleepcap/run has the rest), written into the agent's workspace:

  tools/sleepcap/setup.py codex DIR    DIR/.codex/config.toml: [shell_environment_policy] set = the cap's variables
                                       (ai-session passes no environment to Codex; PATH is the launch's PATH with the
                                       shim first)
  tools/sleepcap/setup.py claude DIR   DIR/.claude/settings.json: a SessionStart hook that puts the shim first on PATH
                                       through CLAUDE_ENV_FILE, which Claude Code sources before every Bash command
                                       (after its shell snapshot, whose PATH a login profile may have reordered)
  tools/sleepcap/setup.py env          the cap's variables, one KEY=VALUE per line (tests)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BIN, PY = os.path.join(HERE, "bin"), os.path.join(HERE, "py")
FUNC = '() {  POG_SLEEP_CALLER="${BASH_SOURCE[1]:-}" "$POG_SLEEPCAP_BIN/sleep" "$@"\n}'  # run's exported `sleep`


def variables(path=None, pythonpath=None):
    path = os.environ.get("PATH", "") if path is None else path
    pythonpath = os.environ.get("PYTHONPATH", "") if pythonpath is None else pythonpath
    parts = [p for p in path.split(os.pathsep) if p and p != BIN]
    extra = {"POG_SLEEP_CAP_SECONDS": os.environ["POG_SLEEP_CAP_SECONDS"]} if os.environ.get("POG_SLEEP_CAP_SECONDS") else {}
    return extra | {
        "POG_SLEEP_CAP": "1",
        "POG_SLEEPCAP_BIN": BIN,
        "POG_SLEEP_CAP_EXEMPT": os.pathsep.join(os.path.join(ROOT, d) for d in ("tools", "bin", "vendor")),
        "PATH": os.pathsep.join([BIN] + parts),
        "PYTHONPATH": os.pathsep.join([PY] + [p for p in pythonpath.split(os.pathsep) if p and p != PY]),
        "BASH_FUNC_sleep%%": FUNC,
    }


def codex(d):
    path = os.path.join(d, ".codex", "config.toml")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = open(path).read() if os.path.exists(path) else ""
    if "[shell_environment_policy]" in text:
        return
    pairs = ", ".join(f"{json.dumps(k)} = {json.dumps(v)}" for k, v in variables().items())
    with open(path, "a") as f:
        f.write("\n# Written by tools/sleepcap/setup.py: shell and Python waits capped at 60 s (tools/sleepcap/run)\n"
                f"[shell_environment_policy]\nset = {{ {pairs} }}\n")


def claude(d):
    path = os.path.join(d, ".claude", "settings.json")
    cfg = json.load(open(path)) if os.path.exists(path) else {}
    hook = {"type": "command", "command": f"'{os.path.join(HERE, 'claude-env.sh')}'"}
    starts = cfg.setdefault("hooks", {}).setdefault("SessionStart", [])
    if not any(h.get("command") == hook["command"] for s in starts for h in s.get("hooks", [])):
        starts.append({"hooks": [hook]})   # no matcher: startup, resume, clear and compact
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    what = sys.argv[1:2]
    if what == ["codex"]:
        codex(sys.argv[2])
    elif what == ["claude"]:
        claude(sys.argv[2])
    elif what == ["env"]:
        for k, v in variables().items():
            print(f"{k}={v}")
    else:
        sys.exit(__doc__)
