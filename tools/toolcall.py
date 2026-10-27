#!/usr/bin/env python3
"""Whether an agent's model is inside a long tool call, for whoever sends it a message (d26 batch238 BT).

batch234 (viewer Aurora site:5021): Opus ran its own script in one 19-minute Bash call. Every tell woke the script's
fh sleep within a second, the script acked it, and the model read nothing until the call ended; Astra's tell replies
said "waking them if asleep" all the while. The harness's own sleeps and acks say nothing about the model, so the
agent CLI's tool hooks record each call in the workspace:

  start  PreToolUse: tools/permit.py (Claude Code, matcher Bash), tools/context.py hook pre-tool (Grok, Muse; Codex
         with --record-only)
  end    PostToolUse: tools/context.py hook post-tool (Claude Code, Grok, Muse; Codex with --record-only)

(d26 batch250) Codex 0.164 runs them from the workspace's .codex/hooks.json once the route's config.toml trusts them
(tools/codex_hooks.py). In code mode they fire for each shell command a cell runs (tool_name Bash, an exec-... id),
and the end comes when the command ends, also after a yield that let the model go on: such a call is dropped when
the model starts another more than STALE_S after it. agy runs no tool hooks here, so it has no record and gets no fact.
DIR/.tool-call.json: {"calls": {ID: {"since": epoch s, "tool": name, "wakes": bool}}, "ended": epoch s}. A call whose
only commands are fh sleep or fh wait (and output filters) ends when a tell wakes it, so it is kept apart (wakes).
The broker (tools/fh_broker.py: a tell's reply) and the viewer relay (tools/stream/viewers.py: a relayed line's
delivery) read it through fact().
"""
import json
import os
import re
import shlex
import time

STATE = ".tool-call.json"
MARKER = ".context-hooks"   # tools/context.py MARKER: an agent workspace
LONG_S = 60      # a call this old or older is told to the sender
STALE_S = 10     # a model starts a new call only after its open ones end (one batch starts together): one still open
                 # when a new one starts later than this lost its end (an interrupted call)
FILTERS = {"tail", "head", "grep", "jq", "cat", "echo", "printf", "wc", "sort", "uniq", "true", "rg"}
CONTROL = {";", "&&", "||", "|", "&", "(", ")", ";;", "\n"}
REDIRECT = re.compile(r"\s\d*(?:>>?|<|&>)&?\s*[^\s;|&()]+")


def call_id(payload):
    """The hook payload's id for the call (Claude Code and Grok: tool_use_id; Muse: tool_call_id), or None."""
    for key in ("tool_use_id", "tool_call_id"):
        if isinstance(payload.get(key), str) and payload[key]:
            return payload[key]
    return None


def command_of(payload):
    tool_input = payload.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("command", "cmd"):
            if isinstance(tool_input.get(key), str):
                return tool_input[key]
    return ""


def wakes(command):
    """True when every simple command is fh (with at least one fh sleep or fh wait) or an output filter, with no loop:
    a tell or mention ends the sleep, so the call ends and the model reads it at once."""
    command = REDIRECT.sub(" ", " " + command.replace("\n", " ; "))   # 2>&1, > /dev/null, < file
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|<>()")
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        return False
    seen_wait, start, prev = False, True, None
    for tok in tokens:
        if tok in CONTROL:
            start = True
            continue
        if tok in ("for", "while", "until", "do", "done"):
            return False
        if start:
            if os.path.basename(tok) == "fh":
                prev = "fh"
            elif tok in FILTERS:
                prev = None
            else:
                return False
            start = False
        elif prev == "fh":
            seen_wait = seen_wait or tok in ("sleep", "wait")
            prev = None
    return seen_wait


def load(d):
    try:
        state = json.load(open(os.path.join(d, STATE)))
    except (OSError, ValueError):
        return {"calls": {}}
    return state if isinstance(state, dict) and isinstance(state.get("calls"), dict) else {"calls": {}}


def save(d, state):
    path = os.path.join(d, STATE)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def started(d, payload, now=None):
    """A PreToolUse: the call's start (a call left open by an interrupt is dropped)."""
    now = time.time() if now is None else now
    state = load(d)
    calls = {k: c for k, c in state["calls"].items() if isinstance(c, dict) and now - c.get("since", 0) <= STALE_S}
    calls[call_id(payload) or "?"] = {"since": round(now, 1), "tool": str(payload.get("tool_name") or ""),
                                      "wakes": wakes(command_of(payload))}
    state["calls"] = calls
    save(d, state)


def ended(d, payload, now=None):
    """A PostToolUse: that call's end; one without an id ends them all. Another tool's end (Claude's PreToolUse
    records Bash only) leaves the open ones."""
    now = time.time() if now is None else now
    state = load(d)
    key = call_id(payload)
    if key is None:
        state["calls"] = {}
    elif key in state["calls"]:
        del state["calls"][key]
    else:
        return
    state["ended"] = round(now, 1)
    save(d, state)


def fact(name, d, now=None, what="tells"):
    """One line when `name`'s model has been inside a tool call LONG_S or longer, else None."""
    now = time.time() if now is None else now
    open_calls = [c for c in load(d)["calls"].values() if isinstance(c, dict) and not c.get("wakes")
                  and isinstance(c.get("since"), (int, float)) and now - c["since"] >= LONG_S]
    if not open_calls:
        return None
    since = min(c["since"] for c in open_calls)
    count = "one tool call" if len(open_calls) == 1 else f"{len(open_calls)} tool calls"
    return (f"{name}: {count} running since {time.strftime('%H:%M:%S', time.localtime(since))} "
            f"({int((now - since) // 60)} min); {what} reach it when it ends")
