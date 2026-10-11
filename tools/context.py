#!/usr/bin/env python3
"""Per-harness context compaction for agent workspaces (see docs/CONTEXT-NOTES.md).

  tools/context.py setup KIND MODEL DIR    write the workspace's compaction settings and hooks; prints extra launch
                                           words (may be empty): KEY=VALUE env words for grok, -c options for muse.
                                           POG_CTX_AT=N overrides compact_at (tools/context-probe.sh).
  tools/context.py limit KIND MODEL        print compact_at from agent/context.tsv
  tools/context.py agy-tokens DIR          context size of DIR's latest Antigravity conversation (0 if unknown)
  tools/context.py grok-tokens DIR         context size of DIR's latest Grok Build session (0 if unknown)
  tools/context.py report RUN_DIR          per-workspace compaction counts from each context.log
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
NOTES_CAP = 7000          # characters of notes.md injected after a compaction (the playbook asks for under 6 KB)
STATE = ".context-state.json"
MARKER = ".context-hooks"  # written by setup; hooks do nothing elsewhere (the repo-wide Grok hooks see every session)


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


CLAUDE_RESERVE = 20000    # Claude Code keeps this much of the window for the summary before computing the threshold


def claude_window(at):
    """autoCompactWindow and CLAUDE_AUTOCOMPACT_PCT_OVERRIDE that make Claude Code compact at `at` tokens.

    Claude Code 2.1.296 fires at min(floor(E * pct / 100), E - 13000) for E = W - 20000 and window W >= 100000
    (probe: W=100000 with pct 80 and 60 compacted at about 64K and 48K)."""
    if at + 13000 + CLAUDE_RESERVE >= 100000:
        return at + 13000 + CLAUDE_RESERVE, None
    return 100000, str(at * 100 // (100000 - CLAUDE_RESERVE))


def setup(kind, model, d):
    window, at = limits(kind, model)
    at = int(os.environ.get("POG_CTX_AT") or at)   # probes force an early compaction
    env = []
    if kind == "claude":
        path = os.path.join(d, ".claude", "settings.json")
        cfg = json.load(open(path)) if os.path.exists(path) else {}
        if at:
            w, pct = claude_window(at)
            cfg["autoCompactWindow"] = min(w, window)
            if pct:
                cfg.setdefault("env", {})["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] = pct
            elif "env" in cfg:
                cfg["env"].pop("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", None)
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
        # Grok loads project hooks only from the git root's .grok/hooks (the repo's .grok/hooks/context.json, which
        # acts in workspaces carrying MARKER), never from the run dir.
        if at:
            env.append(f"GROK_AUTO_COMPACT_THRESHOLD_PERCENT={at * 100 // window}")
    elif kind == "muse":
        # Fractions of the window: past soft Muse compacts in the background, at hard it blocks the turn to compact.
        if at:
            soft = at / window
            env += [f"-c context_compaction.soft_threshold={soft:.3f}",
                    f"-c context_compaction.hard_threshold={min(soft + 0.05, 0.95):.3f}"]
        # Muse 1.4.4 did not fire SessionStart(compact) after its own compactions (probe), so re-inject on the next
        # tool call as for Grok; SessionStart stays for a manual /compact and clears the marker if it does fire.
        write_json(os.path.join(d, ".muse", "hooks.json"), {"hooks": {
            "PreCompact": [{"hooks": [hook_cmd("pre-compact")]}],
            "PostCompact": [{"hooks": [hook_cmd("post-compact", "--mark")]}],
            "SessionStart": [{"matcher": "compact", "hooks": [hook_cmd("session-compact")]}],
            "PostToolUse": [{"hooks": [hook_cmd("post-tool")]}],
        }})
    # agy: no threshold or compaction hooks; .agy-loop.sh starts a fresh conversation past compact_at (agy-tokens).
    with open(os.path.join(d, MARKER), "w") as f:
        f.write(f"{kind} {model} {at}\n")
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


def grok_tokens(d):
    """Context size of DIR's latest Grok Build session (the last `_meta.totalTokens` in updates.jsonl), 0 if unknown."""
    import glob
    import re
    from urllib.parse import quote
    base = os.path.join(os.path.expanduser("~/.grok/sessions"), quote(os.path.realpath(d), safe=""))
    try:
        path = max(glob.glob(os.path.join(base, "*", "updates.jsonl")), key=os.path.getmtime)
        found = re.findall(r'"_meta":\{"totalTokens":(\d+)', "\n".join(tail_lines(path)))
        return int(found[-1]) if found else 0
    except (OSError, ValueError):
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
    if not os.path.exists(os.path.join(d, MARKER)):
        return
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
        state.pop("floor", None)
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
        if "hooks_seen" not in state:
            state["hooks_seen"] = time.strftime("%Y-%m-%d %H:%M:%S")   # shows the workspace hooks load (smoke tests)
            save()
        if state.get("reinject"):
            state.pop("reinject")
            save()
            log(action="reinject")
            context = notes_block(d, "Your context was just compacted.")
        elif "--at" in args and transcript and not state.get("nudged"):
            at = int(args[args.index("--at") + 1])
            tokens = claude_tokens(transcript, state.get("since", 0))
            if tokens and "floor" not in state:
                state["floor"] = tokens   # context at the first tool call of this window (after a compaction: its floor)
                save()
            # Claude Code compacts as soon as a tool result would cross the threshold; with a 12K margin the probe's
            # nudge and compaction landed in the same step, too late for the agent to update notes.md. Never warn in
            # the first half of the room above the floor: Haiku's floor (51-59K) sat above its 60K warning in shake2.
            floor = state.get("floor", 0)
            if at and tokens >= max(at - max(20000, at // 5), floor + (at - floor) // 2):
                state["nudged"] = True
                save()
                log(action="nudge", tokens=tokens, at=at)
                context = (f"Context is at {tokens} tokens; automatic compaction happens at about {at}, and the "
                           "summary keeps only your last few actions. Update notes.md now (Now, claims and "
                           "coordinates, agreements, open board items, lessons), then continue.")
        if context:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": context}}))


def report(run_dir):
    """One line per workspace: compactions, re-injects, nudges, agy fresh starts, tokens at each compaction."""
    for name in sorted(os.listdir(run_dir)):
        path = os.path.join(run_dir, name, "context.log")
        if not os.path.exists(path):
            continue
        rows = [json.loads(l) for l in open(path) if l.strip()]
        count = lambda ev, action=None: sum(r["event"] == ev and (action is None or r.get("action") == action)
                                            for r in rows)
        at = [r.get("tokens") for r in rows if r["event"] in ("pre-compact", "agy-fresh") and r.get("tokens")]
        print(f"{name:10} compactions={count('post-compact')} agy_fresh={count('agy-fresh')} "
              f"reinjects={count('session-compact') + count('post-tool', 'reinject')} "
              f"nudges={count('post-tool', 'nudge')} tokens_at_compaction={at}")


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "setup":
        setup(*args[:3])
    elif cmd == "limit":
        print(limits(args[0], args[1])[1])
    elif cmd == "agy-tokens":
        print(agy_tokens(args[0]))
    elif cmd == "grok-tokens":
        print(grok_tokens(args[0]))
    elif cmd == "report":
        report(args[0])
    elif cmd == "hook":
        hook(args[0], args[1:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
