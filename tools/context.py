#!/usr/bin/env python3
"""Per-harness context compaction for agent workspaces (see docs/CONTEXT-NOTES.md).

  tools/context.py setup KIND MODEL DIR    write the workspace's compaction settings and hooks; prints extra launch
                                           words (may be empty): KEY=VALUE env words for grok, -c options for muse.
                                           POG_CTX_AT=N overrides compact_at (tools/context-probe.sh).
  tools/context.py limit KIND MODEL        print compact_at from agent/context.tsv
  tools/context.py agy-tokens DIR          context size of DIR's latest Antigravity conversation (0 if unknown)
  tools/context.py grok-tokens DIR         context size of DIR's latest Grok Build session (0 if unknown)
  tools/context.py report RUN_DIR          per-workspace compaction counts from each context.log
  tools/context.py hook EVENT [--at N] [--mark] [--skip-late S]   hook handler; reads the hook payload on stdin

Hook events: pre-compact and post-compact log to DIR/context.log (post-compact also saves the summary to
DIR/compactions.md; --mark leaves a marker so the next post-tool hook re-injects notes.md, for harnesses without
a SessionStart "compact" hook). session-compact prints notes.md for a SessionStart(compact) hook. post-tool
re-injects notes.md after a marked compaction and, with --at N (Claude), warns once per context window when the
transcript is within reach of the compaction point so the agent updates notes.md first. pre-compact with
--skip-late S --at N (Claude) blocks an automatic compaction in the last S seconds before DIR/deadline.txt.
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTES_CAP = 7000          # characters of notes.md injected after a compaction (the playbook asks for under 6 KB)
# Log lines injected after a compaction (the playbook keeps ~10). Haiku's Log reached 39 lines in shake4 and Claude Code
# also re-attaches notes.md as a recently read file, so each compaction carried the whole Log twice and the floor
# rose from 24.5K to 31.1K (docs/LAUNCH2-NOTES.md, round 5).
LOG_KEEP = 10
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
LATE_SECONDS = 120        # no compaction in an agent's last 2 minutes where a hook or our loop can stop it


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
            # Exit 2 from a PreCompact hook blocks the compaction and Claude Code continues uncompacted.
            "PreCompact": [{"hooks": [hook_cmd("pre-compact", "--skip-late", str(LATE_SECONDS), "--at", str(at))]}],
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


# Blocking stops once the context passes compact_at + LATE_ROOM. The transcript lags Claude Code's own count by the
# pending tool result (probe: hook 48.4K, compaction at 59.7K with 8K files), and the hard limit sits a little past
# compact_at + 13000 (claude_window), so the room stays small.
LATE_ROOM = 5000


def seconds_left(d):
    """Seconds to the deadline in DIR/deadline.txt ("2026-10-11 04:15 PDT", local time), None if unreadable."""
    try:
        text = open(os.path.join(d, "deadline.txt")).read().strip()
        return int(time.mktime(time.strptime(text[:16], "%Y-%m-%d %H:%M")) - time.time())
    except (OSError, ValueError):
        return None


def trim_log(notes, keep=LOG_KEEP):
    """notes.md with only the last `keep` lines of its ## Log section, and a line saying how many were left out."""
    lines = notes.split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if l.strip().lower() == "## log") + 1
    except StopIteration:
        return notes
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("## ")), len(lines))
    entries = [i for i in range(start, end) if lines[i].strip()]
    if len(entries) <= keep:
        return notes
    cut = entries[-keep]
    omitted = len(entries) - keep
    return "\n".join(lines[:start] + [f"[{omitted} older Log lines left out: fold them into the sections above, then "
                                      "delete them from notes.md]"] + lines[cut:])


BRIEF_MAX = 3000   # characters (docs/studies/2026-10-13-agent-minds.md fix 8: re-reads of 25-260 KB after a compaction)
# Harnesses that keep AGENTS.md through a compaction: Claude Code loads CLAUDE.md (a link to it) as memory, Codex loads
# AGENTS.md as its instructions. Grok and Muse read it as a file, so they are not told to skip it.
KEEPS_AGENTS_MD = ("claude", "codex")


def section(notes, *names, cap=900):
    """The body of the first `## NAME` section of notes.md matching any of `names` (case-insensitive), cut to cap."""
    lines = notes.split("\n")
    for i, l in enumerate(lines):
        if l.startswith("## ") and any(n in l[3:].strip().lower() for n in names):
            end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("## ")), len(lines))
            body = "\n".join(lines[i + 1:end]).strip()
            return body if len(body) <= cap else body[:cap].rstrip() + " [...]"
    return ""


def journal_tail(d, n_lines=4000):
    path = os.path.join(d, "journal.jsonl")
    try:
        return tail_lines(path, size=3_000_000)[-n_lines:]
    except OSError:
        return []


def recent_tells(lines, keep=3):
    """The last tells to this agent, from its replies' team hints ("astra, 2s ago: ...")."""
    found = []
    for line in lines:
        if '"tells"' not in line or '"team"' not in line:
            continue
        try:
            team = ((json.loads(line).get("response") or {}).get("result") or {}).get("team") or {}
        except ValueError:
            continue
        for t in team.get("tells") or []:
            if isinstance(t, str) and t not in found:
                found.append(t)
    return [t if len(t) <= 180 else t[:180] + " [...]" for t in found[-keep:]]


def my_claims(lines, me, keep=3):
    """Board items this agent owns from its own board_post/board_update replies: the latest state of each."""
    items = {}
    for line in lines:
        if '"item"' not in line or '"owner"' not in line:
            continue
        try:
            item = ((json.loads(line).get("response") or {}).get("result") or {}).get("item") or {}
        except ValueError:
            continue
        if item.get("id") is not None and item.get("owner") == me:
            items[item["id"]] = item
    open_ = [i for i in items.values() if i.get("status") not in ("done", "closed", "cancelled")]
    return [f"#{i['id']} {i.get('title', '')[:90]} ({i.get('status')})" for i in open_[-keep:]]


def brief(d, why):
    """After a compaction: at most BRIEF_MAX characters from notes.md (Now, claims, agreements), the agent's own
    claims and the last tells to it from its journal, and what its last 30 minutes measured (handover.py), instead of
    the whole notes.md; the harnesses that keep AGENTS.md are told not to re-read it."""
    try:
        kind = open(os.path.join(d, MARKER)).read().split()[0]
    except (OSError, IndexError):
        kind = ""
    try:
        notes = open(os.path.join(d, "notes.md"), errors="replace").read()
    except OSError:
        notes = ""
    me = os.path.basename(os.path.realpath(d))
    lines = journal_tail(d)
    out = [f"{why} A brief of at most 3 KB follows; notes.md has the rest (read only what this lacks)."]
    if kind in KEEPS_AGENTS_MD:
        out.append("AGENTS.md is still loaded in your context: do not re-read it.")
    now = section(notes, "now")
    out += ["", "## Now (notes.md)", now or "(notes.md has no Now section)"]
    for name in ("claim", "agreement"):
        s = section(notes, name, cap=400)
        if s:
            out += ["", f"## {name.capitalize()}s (notes.md)", s]
    claims = my_claims(lines, me)
    if claims:
        out += ["", "## Your open board items (your replies)"] + [f"- {c}" for c in claims]
    tells = recent_tells(lines)
    if tells:
        out += ["", "## Last tells to you"] + [f"- {t}" for t in tells]
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from handover import journal_stats, measured_lines
    st = journal_stats(os.path.join(d, "journal.jsonl"), since=time.time() - 1800, max_bytes=3_000_000)
    if st and st["first"]:
        out += ["", "## Your last 30 minutes, measured (your journal)"] + measured_lines(st, "last 30 minutes")[:6]
    out += ["", "Before acting: read deadline.txt, then ./fh call status and ./fh call chat."]
    text = "\n".join(out)
    return text if len(text) <= BRIEF_MAX else text[:BRIEF_MAX - 40].rstrip() + "\n[... brief cut at 3 KB]"


def notes_block(d, why):
    try:
        notes = trim_log(open(os.path.join(d, "notes.md")).read())
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
        left = seconds_left(d)
        # --skip-late S --at N (Claude): exit 2 blocks an automatic compaction in the last S seconds while the context
        # is under N + LATE_ROOM (shake3: Grok's compaction began 39 s before its deadline and ended its play).
        if "--skip-late" in args and payload.get("trigger") == "auto" and left is not None:
            late, at = int(args[args.index("--skip-late") + 1]), int(args[args.index("--at") + 1])
            if 0 < left <= late and (not tokens or tokens < at + LATE_ROOM):
                log(trigger="auto", tokens=tokens, action="skip-late", seconds_left=left)
                print(f"Skipped: the deadline is {left} s away.", file=sys.stderr)
                sys.exit(2)
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
        print(brief(d, "Your context was just compacted."))
    elif event == "post-tool":
        context = None
        if "hooks_seen" not in state:
            state["hooks_seen"] = time.strftime("%Y-%m-%d %H:%M:%S")   # shows the workspace hooks load (smoke tests)
            save()
        if state.get("reinject"):
            state.pop("reinject")
            save()
            log(action="reinject")
            context = brief(d, "Your context was just compacted.")
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
                           "coordinates, agreements, open board items, lessons) and cut its Log to the last 10 lines, "
                           "then continue.")
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
