#!/usr/bin/env python3
"""Per-harness context compaction for agent workspaces (see docs/CONTEXT-NOTES.md).

  tools/context.py setup KIND MODEL DIR    write the workspace's compaction settings and hooks; prints launch env
                                           (KEY=VALUE words, may be empty) for harnesses configured by env
  tools/context.py limit KIND MODEL        print compact_at from agent/context.tsv
  tools/context.py agy-tokens DIR          context size of DIR's latest Antigravity conversation (0 if unknown)
  tools/context.py hook EVENT [--at N] [--mark]   hook handler; reads the hook payload on stdin

Hook events: pre-compact and post-compact log to DIR/context.log (post-compact also saves the summary to
DIR/compactions.md; --mark leaves a marker so the next post-tool hook re-injects notes.md, for harnesses without
a SessionStart "compact" hook). session-compact prints notes.md for a SessionStart(compact) hook. post-tool
re-injects notes.md after a marked compaction and, with --at N (Claude), warns once per context window when the
transcript is within reach of the compaction point so the agent updates notes.md first.
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTES_CAP = 9000          # characters of notes.md injected after a compaction (hook outputs are capped by harnesses)
STATE = ".context-state.json"


def limits(kind, model):
    rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(ROOT, "agent", "context.tsv"))
            if l.strip() and not l.startswith("#")]
    for want in (model, "*"):
        for m, k, window, at in rows:
            if k == kind and m == want:
                return int(window), int(at)
    return 0, 0


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def hook_cmd(event, *extra):
    return {"type": "command", "command": " ".join(["python3", os.path.join(ROOT, "tools", "context.py"), "hook",
                                                    event, *extra]), "timeout": 20}


def claude_window(at):
    """autoCompactWindow and CLAUDE_AUTOCOMPACT_PCT_OVERRIDE that make Claude Code compact at `at` tokens.

    Claude Code 2.1.296 fires at min(floor(W * pct / 100), W - 13000) for window W (W >= 100000)."""
    if at + 13000 >= 100000:
        return at + 13000, None
    return 100000, str(at * 100 // 100000)


def setup(kind, model, d):
    window, at = limits(kind, model)
    env = []
    if kind == "claude":
        path = os.path.join(d, ".claude", "settings.json")
        cfg = json.load(open(path)) if os.path.exists(path) else {}
        if at:
            w, pct = claude_window(at)
            cfg["autoCompactWindow"] = min(w, window)
            if pct:
                cfg.setdefault("env", {})["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] = pct
        cfg["hooks"] = {
            "PreCompact": [{"hooks": [hook_cmd("pre-compact")]}],
            "PostCompact": [{"hooks": [hook_cmd("post-compact")]}],
            "SessionStart": [{"matcher": "compact", "hooks": [hook_cmd("session-compact")]}],
            "PostToolUse": [{"hooks": [hook_cmd("post-tool", "--at", str(at))]}],
        }
        write_json(path, cfg)
    elif kind == "codex":
        # Project config layer: loaded because run dirs sit inside the trusted player-of-games repo. Codex compacts
        # on OpenAI's servers, which ignore the prompt file; it applies only if Codex falls back to local compaction.
        os.makedirs(os.path.join(d, ".codex"), exist_ok=True)
        with open(os.path.join(d, ".codex", "config.toml"), "w") as f:
            f.write("# Written by tools/context.py from agent/context.tsv\n")
            f.write(f"model_context_window = {window}\n")
            if at:
                f.write(f"model_auto_compact_token_limit = {at}\n")
            f.write(f'experimental_compact_prompt_file = "{os.path.join(ROOT, "agent", "compact.md")}"\n')
    elif kind == "grok":
        if at:
            env.append(f"GROK_AUTO_COMPACT_THRESHOLD_PERCENT={at * 100 // window}")
        write_json(os.path.join(d, ".grok", "hooks", "context.json"), {"hooks": {
            "PreCompact": [{"hooks": [hook_cmd("pre-compact")]}],
            "PostCompact": [{"hooks": [hook_cmd("post-compact", "--mark")]}],
            "PostToolUse": [{"hooks": [hook_cmd("post-tool")]}],
        }})
    elif kind == "muse":
        write_json(os.path.join(d, ".muse", "hooks.json"), {"hooks": {
            "PreCompact": [{"hooks": [hook_cmd("pre-compact")]}],
            "PostCompact": [{"hooks": [hook_cmd("post-compact")]}],
            "SessionStart": [{"matcher": "compact", "hooks": [hook_cmd("session-compact")]}],
        }})
    # agy: no threshold or compaction hooks; .agy-loop.sh starts a fresh conversation past compact_at (agy-tokens).
    print(" ".join(env))


def agy_tokens(d):
    base = os.path.expanduser("~/.gemini/antigravity-cli")
    try:
        conv = json.load(open(os.path.join(base, "cache", "last_conversations.json")))[os.path.realpath(d)]
        path = os.path.join(base, "brain", conv, ".system_generated", "logs", "transcript.jsonl")
        for line in reversed(tail_lines(path)):
            row = json.loads(line)
            if row.get("type") == "PLANNER_RESPONSE" and "input_tokens" in row:
                return int(row["input_tokens"]) + int(row.get("cache_read_tokens") or 0)
    except (OSError, KeyError, ValueError):
        pass
    return 0


def tail_lines(path, size=400_000, since=0):
    """Complete lines in the last `size` bytes of a file, starting no earlier than byte offset `since`."""
    with open(path, "rb") as f:
        f.seek(0, 2)
        end = f.tell()
        since = since if since <= end else 0   # a different (new) file
        start = max(since, end - size)
        f.seek(start)
        data = f.read().decode("utf-8", "replace")
    lines = data.splitlines()
    return [l for l in (lines if start == since else lines[1:]) if l.strip()]


def claude_tokens(transcript, since=0):
    """Context size at the latest assistant message of a Claude Code transcript, written after byte `since`."""
    try:
        for line in reversed(tail_lines(transcript, since=since)):
            if '"usage"' not in line:
                continue
            row = json.loads(line)
            u = (row.get("message") or {}).get("usage")
            if row.get("type") == "assistant" and u:
                return sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens",
                                                       "cache_read_input_tokens", "output_tokens"))
    except (OSError, ValueError):
        pass
    return 0


def notes_block(d, why):
    try:
        notes = open(os.path.join(d, "notes.md")).read()
    except OSError:
        notes = "(notes.md is missing)"
    if len(notes) > NOTES_CAP:
        notes = notes[:NOTES_CAP] + "\n[... truncated: read notes.md for the rest]"
    return (f"{why} Below is your notes.md, your durable memory. Before acting: read deadline.txt, add anything from "
            "the summary that notes.md is missing, then check ./fh call status and ./fh call chat.\n\n" + notes)


def hook(event, args):
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except ValueError:
        payload = {}
    d = payload.get("cwd") or os.getcwd()
    state_path = os.path.join(d, STATE)
    try:
        state = json.load(open(state_path))
    except (OSError, ValueError):
        state = {}

    def log(**fields):
        with open(os.path.join(d, "context.log"), "a") as f:
            f.write(json.dumps({"time": time.strftime("%Y-%m-%d %H:%M:%S"), "event": event, **fields}) + "\n")

    def save():
        with open(state_path, "w") as f:
            json.dump(state, f)

    transcript = payload.get("transcript_path")
    if event == "pre-compact":
        tokens = claude_tokens(transcript) if transcript else payload.get("context_tokens")
        log(trigger=payload.get("trigger"), tokens=tokens, window=payload.get("context_window_size"))
    elif event == "post-compact":
        summary = payload.get("compact_summary") or ""
        state["compactions"] = state.get("compactions", 0) + 1
        state["nudged"] = False
        if transcript and os.path.exists(transcript):
            state["since"] = os.path.getsize(transcript)   # usage before this point is the old context's
        if "--mark" in args:
            state["reinject"] = True
        save()
        log(trigger=payload.get("trigger"), summary_chars=len(summary), n=state["compactions"])
        if summary:
            with open(os.path.join(d, "compactions.md"), "a") as f:
                f.write(f"\n## Compaction {state['compactions']} ({time.strftime('%H:%M:%S')})\n\n{summary}\n")
    elif event == "session-compact":
        state["nudged"] = False
        state.pop("reinject", None)
        save()
        log(source=payload.get("source"))
        print(notes_block(d, "Your context was just compacted."))
    elif event == "post-tool":
        context = None
        if state.get("reinject"):
            state.pop("reinject")
            save()
            log(action="reinject")
            context = notes_block(d, "Your context was just compacted.")
        elif "--at" in args and transcript and not state.get("nudged"):
            at = int(args[args.index("--at") + 1])
            tokens = claude_tokens(transcript, state.get("since", 0))
            if at and tokens >= at - max(12000, at // 10):
                state["nudged"] = True
                save()
                log(action="nudge", tokens=tokens, at=at)
                context = (f"Context is at {tokens} tokens; automatic compaction happens at about {at}, and the "
                           "summary keeps only your last few actions. Update notes.md now (Now, claims and "
                           "coordinates, agreements, open board items, lessons), then continue.")
        if context:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": context}}))


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "setup":
        setup(*args[:3])
    elif cmd == "limit":
        print(limits(args[0], args[1])[1])
    elif cmd == "agy-tokens":
        print(agy_tokens(args[0]))
    elif cmd == "hook":
        hook(args[0], args[1:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
