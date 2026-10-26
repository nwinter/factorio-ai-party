#!/usr/bin/env python3
"""Codex tool hooks for an agent workspace (d26 batch250 BC: the busy notice for Astra, Sol and Luna).

  tools/codex_hooks.py setup DIR ROUTE   write DIR/.codex/hooks.json and record its hooks as trusted in the route's
                                         CODEX_HOME/config.toml; prints one line for the start log
  tools/codex_hooks.py check DIR ROUTE   print each hook of DIR's and its trust status (Codex's own hooks/list)

The hooks record each model tool call's start and end in DIR/.tool-call.json (tools/toolcall.py), as Claude Code's,
Grok's and Muse's do; nothing else. They print nothing, so they never allow, deny or change a call or its output.

Codex 0.164 loads a project's .codex/hooks.json (in a trusted project: run dirs sit inside the player-of-games repo)
but runs a hook only when CODEX_HOME/config.toml holds [hooks.state."PATH:EVENT:GROUP:HANDLER"] trusted_hash equal to
the hook's current hash. An untrusted hook is skipped without a word (codex exec), and a hook edited later reads
"modified" and is skipped too. Trust in the workspace's own config or a -c override does not count. The hash is the
one Codex reports (`codex app-server` hooks/list, currentHash); it covers the handler, not the path. setup trusts only
hooks whose command is one this file writes, and drops the entries of other runs' workspaces (one shift's at a time).
"""
import json
import os
import re
import subprocess
import sys
import threading
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CODEX = "/opt/homebrew/bin/codex"
AI_SESSION = os.path.expanduser("~/.local/bin/ai-session")
CONTEXT = os.path.join(ROOT, "tools", "context.py")
# Codex's hook events and their trust-key names
HOOKS = {
    "PreToolUse": ("pre_tool_use", f"python3 {CONTEXT} hook pre-tool --record-only"),
    "PostToolUse": ("post_tool_use", f"python3 {CONTEXT} hook post-tool --record-only"),
}
TIMEOUT = 5    # seconds: a hook past it fails and the call goes on (Codex holds the call that long); the recorder takes ~60 ms


def hooks_path(d):
    return os.path.join(os.path.abspath(d), ".codex", "hooks.json")


def write_hooks(d):
    path = hooks_path(d)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump({"hooks": {event: [{"hooks": [{"type": "command", "command": cmd, "timeout": TIMEOUT}]}]
                             for event, (_, cmd) in HOOKS.items()}}, f, indent=2)
        f.write("\n")
    return path


def codex_home(route):
    """The route's CODEX_HOME from ai-session's routes.json (codex: ~/.codex, codex-b: ~/.codex-account-b)."""
    config = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(AI_SESSION))), "config", "routes.json")
    r = json.load(open(config))["routes"][route]
    if r.get("harness") != "codex":
        raise ValueError(f"route {route} is not a Codex route")
    return os.path.expanduser(r["root"])


def hooks_list(d, home, codex=None, timeout=30):
    """Codex's own view of the hooks for a session in d: [{key, command, sourcePath, currentHash, trustStatus, ...}]."""
    proc = subprocess.Popen([codex or CODEX, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, cwd=d, env=dict(os.environ, CODEX_HOME=home))
    msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "pog", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "hooks/list", "params": {"cwds": [os.path.abspath(d)]}}]
    # stdin stays open until the reply: the server stops at its end, before answering
    timer = threading.Timer(timeout, proc.kill)
    timer.start()
    try:
        proc.stdin.write("".join(json.dumps(m) + "\n" for m in msgs))
        proc.stdin.flush()
        for line in proc.stdout:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("id") == 2:
                if "result" not in o:
                    raise RuntimeError(f"hooks/list: {o.get('error')}")
                return [h for entry in o["result"]["data"] for h in entry.get("hooks", [])]
        raise RuntimeError("hooks/list: no reply" + (f" in {timeout} s" if not timer.is_alive() else ""))
    finally:
        timer.cancel()
        proc.kill()
        proc.wait()


def key_header(key):
    return f"[hooks.state.{json.dumps(key)}]"


def edit_trust(config, add, drop=lambda key: False):
    """config.toml text with [hooks.state."KEY"] trusted_hash set for each of `add` ({key: hash}) and the tables of
    keys for which drop(key) is true removed. Other text, and other keys of an updated table, stay as they are."""
    header = re.compile(r'^\[hooks\.state\.("(?:[^"\\]|\\.)*")\]\s*$')
    tables = [[]]   # the text before the first table, then one list of lines per table, from its header line
    for line in config.splitlines():
        if line.startswith("["):
            tables.append([])
        tables[-1].append(line)
    out, done = [], set()
    for table in tables:
        m = header.match(table[0]) if table else None
        key = json.loads(m.group(1)) if m else None
        if key is not None and key not in add and drop(key):
            out += [l for l in table[1:] if l.lstrip().startswith("#")]   # a comment there may head the next table
            continue
        if key in add:
            body = [l for l in table[1:] if not re.match(r"\s*trusted_hash\s*=", l)]
            table = [table[0], f"trusted_hash = {json.dumps(add[key])}"] + body
            done.add(key)
        out += table
    for key, h in add.items():
        if key not in done:
            if out and out[-1].strip():
                out.append("")
            out += [key_header(key), f"trusted_hash = {json.dumps(h)}"]
    return "\n".join(out).rstrip("\n") + "\n"   # no blank line left at the end by a dropped table


def run_of(key):
    """The run (runs/RUN/AGENT/.codex/hooks.json) of a trust key under this repo's runs/, else None."""
    m = re.match(re.escape(os.path.join(ROOT, "runs")) + r"/([^/]+)/[^/]+/\.codex/hooks\.json:", key)
    return m.group(1) if m else None


def trust(d, home, commands=None, codex=None):
    """Record d's hooks with one of `commands` (default: ours) as trusted in home/config.toml. Returns
    (trusted event names, [other hooks of d's file left untrusted])."""
    commands = {cmd for _, cmd in HOOKS.values()} if commands is None else set(commands)
    path = hooks_path(d)
    run = os.path.basename(os.path.dirname(os.path.abspath(d)))
    listed = [h for h in hooks_list(d, home, codex) if h.get("sourcePath") == path]
    add = {h["key"]: h["currentHash"] for h in listed if h.get("command") in commands and h.get("currentHash")}
    other = [h["key"] for h in listed if h["key"] not in add]
    config_path = os.path.join(home, "config.toml")
    text = open(config_path).read()
    new = edit_trust(text, add, drop=lambda key: run_of(key) not in (None, run))
    tomllib.loads(new)   # never write a config Codex cannot read
    if new != text:
        tmp = f"{config_path}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            f.write(new)
        os.chmod(tmp, os.stat(config_path).st_mode & 0o777)
        os.replace(tmp, config_path)
    return sorted(h["eventName"] for h in listed if h["key"] in add), other


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("setup", "check"):
        sys.exit(__doc__)
    cmd, d, route = sys.argv[1:]
    if cmd == "check":
        for h in hooks_list(d, codex_home(route)):
            print(f"{h['trustStatus']:10} {h['key']}  {h.get('command')}")
        return
    write_hooks(d)
    try:
        home = codex_home(route)
        events, other = trust(d, home)
        if len(events) != len(HOOKS) or other:
            raise RuntimeError(f"trusted {events or 'none'}, untrusted {other or 'none'}")
    except Exception as e:
        # The file goes: an untrusted hook puts Codex's TUI on a "Hooks need review" dialog before the first turn.
        # Without it the agent starts as before, with no record and no busy notice.
        os.remove(hooks_path(d))
        print(f"codex hooks: not set ({type(e).__name__}: {e})")
        return
    print(f"codex hooks: {', '.join(events)} trusted in {home.replace(os.path.expanduser('~'), '~')}/config.toml")


if __name__ == "__main__":
    main()
