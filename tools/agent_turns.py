#!/usr/bin/env python3
"""How each Claude Code and Codex agent spent its shifts, from the CLIs' own session logs (read only).

  python3 tools/agent_turns.py [--shifts 80-86] [--agents opus,sol,...] [--calls DIR]

One row per agent and shift: steps (the model's tool calls), the hours the logs span, steps an hour, hours inside tool
calls, calls of 5 minutes or more and the hours inside them, wait calls (sleep, wait, until, idle, Monitor), turns
(prompts that started one: the launch, the deadline prompt, a resume), compactions, thinking or reasoning items, text
messages, output tokens, and the median call in seconds. --calls DIR writes calls-AGENT-SHIFT.tsv there (start UTC,
seconds, the call's text).

d27 batch275 HW (viewers Aurora and Foobator; Nick: why the Claude Code agents are less self-driven than the Codex
ones): in shifts 80-86 Opus made 31-65 steps a shift and spent 3.2-3.9 h of each inside calls of 5+ min; the Codex
agents made 625-1,677 and none. Run it after the next shifts to compare.

Logs: Claude Code under CLAUDE_PROJECTS (default the claude-b route's projects folder), one folder per workspace
(-Users-owner-code-player-of-games-runs-shiftNN-AGENT); Codex rollouts under CODEX_HOMES (default ~/.codex and
~/.codex-account-b) sessions/, matched by the workspace path in their first 4 KB.
"""
import argparse, glob, json, os, re, sys
from datetime import datetime

CLAUDE_PROJECTS = os.environ.get("CLAUDE_PROJECTS", os.path.expanduser("~/.profiles/claude/account-b/projects"))
CODEX_HOMES = os.environ.get("CODEX_HOMES", os.path.expanduser("~/.codex") + ":" + os.path.expanduser("~/.codex-account-b"))
REPO = "-Users-owner-code-player-of-games"
WAIT = re.compile(r"\b(sleep|wait|idle\.py|idle|until|Monitor)\b")
CLAUDE = ("opus", "sonnet", "haiku")
CODEX = ("astra", "sol", "luna")
HEAD = ("agent", "shift", "steps", "hours", "steps_h", "in_calls_h", "calls_5min", "h_in_5min", "waits", "turns",
        "compacts", "thinking", "texts", "out_tok", "median_s")


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def claude_log(path):
    """-> (calls [(start, seconds, text)], info) from one Claude Code transcript."""
    calls, start = [], {}
    info = dict(texts=0, turns=0, compacts=0, thinking=0, out_tok=0, first=None, last=None)
    for line in open(path, errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        t = ts(d.get("timestamp"))
        if t:
            info["first"] = info["first"] or t
            info["last"] = t
        if d.get("isCompactSummary"):
            info["compacts"] += 1
        m = d.get("message") or {}
        content = m.get("content") if isinstance(m.get("content"), list) else []
        if d.get("type") == "assistant":
            info["out_tok"] += (m.get("usage") or {}).get("output_tokens", 0) or 0
            for it in content:
                kind = it.get("type")
                if kind == "tool_use":
                    inp = it.get("input") or {}
                    start[it.get("id")] = (t, f"{it.get('name')} {inp.get('command') or inp.get('description') or json.dumps(inp)}")
                elif kind == "text":
                    info["texts"] += 1
                elif kind == "thinking":
                    info["thinking"] += 1
        elif d.get("type") == "user":
            if isinstance(m.get("content"), str) and not d.get("isCompactSummary") and not d.get("isMeta"):
                info["turns"] += 1
            for it in content:
                if isinstance(it, dict) and it.get("type") == "tool_result" and it.get("tool_use_id") in start and t:
                    t0, text = start.pop(it["tool_use_id"])
                    if t0:
                        calls.append((t0, (t - t0).total_seconds(), text))
    return calls, info


def codex_log(path):
    """-> (calls, info) from one Codex rollout."""
    calls, start = [], {}
    info = dict(texts=0, turns=0, compacts=0, thinking=0, out_tok=0, first=None, last=None)
    for line in open(path, errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        t = ts(d.get("timestamp"))
        if t:
            info["first"] = info["first"] or t
            info["last"] = t
        kind, p = d.get("type"), d.get("payload") or {}
        pt = p.get("type")
        if kind == "compacted":
            info["compacts"] += 1
        elif kind == "response_item" and pt in ("custom_tool_call", "function_call"):
            start[p.get("call_id")] = (t, f"{p.get('name')} {p.get('input') or p.get('arguments') or ''}")
        elif kind == "response_item" and pt in ("custom_tool_call_output", "function_call_output"):
            if p.get("call_id") in start and t:
                t0, text = start.pop(p["call_id"])
                if t0:
                    calls.append((t0, (t - t0).total_seconds(), text))
        elif kind == "response_item" and pt == "reasoning":
            info["thinking"] += 1
        elif kind == "response_item" and pt == "message" and p.get("role") == "assistant":
            info["texts"] += 1
        elif kind == "event_msg" and pt == "task_started":
            info["turns"] += 1
        elif kind == "event_msg" and pt == "token_count":
            info["out_tok"] = ((p.get("info") or {}).get("total_token_usage") or {}).get("output_tokens", info["out_tok"])
    return calls, info


def codex_files(shifts):
    """{(shift, agent): [rollout paths]} for the workspaces runs/shiftNN/AGENT."""
    want = {f"shift{s}" for s in shifts}
    found = {}
    for home in CODEX_HOMES.split(":"):
        for f in glob.glob(os.path.join(home, "sessions", "*", "*", "*", "*.jsonl")):
            try:
                with open(f, errors="replace") as h:
                    head = h.read(4000)
            except OSError:
                continue
            m = re.search(r"runs/(shift\d+)/([a-z]+)", head)
            if m and m.group(1) in want:
                found.setdefault((m.group(1), m.group(2)), []).append(f)
    return found


def row(agent, shift, calls, info):
    hours = (info["last"] - info["first"]).total_seconds() / 3600 if info["first"] and info["last"] else 0
    durs = sorted(d for _, d, _ in calls)
    long = [d for d in durs if d >= 300]
    return (agent, shift, len(calls), round(hours, 2), round(len(calls) / hours) if hours else 0, round(sum(durs) / 3600, 2),
            len(long), round(sum(long) / 3600, 2), sum(1 for _, _, c in calls if WAIT.search(c)), info["turns"],
            info["compacts"], info["thinking"], info["texts"], info["out_tok"], round(durs[len(durs) // 2]) if durs else 0)


def merge(parts):
    calls, info = [], dict(texts=0, turns=0, compacts=0, thinking=0, out_tok=0, first=None, last=None)
    for c, i in parts:
        calls += c
        for k in ("texts", "turns", "compacts", "thinking", "out_tok"):
            info[k] += i[k]
        info["first"] = min(x for x in (info["first"], i["first"]) if x) if (info["first"] or i["first"]) else None
        info["last"] = max(x for x in (info["last"], i["last"]) if x) if (info["last"] or i["last"]) else None
    return calls, info


def shifts_arg(text):
    a, _, b = text.partition("-")
    return list(range(int(a), int(b or a) + 1))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--shifts", default="80-86")
    ap.add_argument("--agents", default=",".join(CODEX + CLAUDE))
    ap.add_argument("--calls")
    a = ap.parse_args(argv)
    shifts, agents = shifts_arg(a.shifts), a.agents.split(",")
    cx = codex_files(shifts) if any(x in CODEX for x in agents) else {}
    print("\t".join(HEAD))
    for s in shifts:
        for agent in agents:
            if agent in CLAUDE:
                files = sorted(glob.glob(os.path.join(CLAUDE_PROJECTS, f"{REPO}-runs-shift{s}-{agent}", "*.jsonl")))
                parse = claude_log
            else:
                files, parse = sorted(cx.get((f"shift{s}", agent), [])), codex_log
            if not files:
                continue
            calls, info = merge([parse(f) for f in files])
            print("\t".join(str(x) for x in row(agent, s, calls, info)))
            if a.calls:
                os.makedirs(a.calls, exist_ok=True)
                with open(os.path.join(a.calls, f"calls-{agent}-{s}.tsv"), "w") as h:
                    for t0, d, c in sorted(calls):
                        h.write(f"{t0.strftime('%H:%M:%S')}\t{d:.0f}\t{c[:300].replace(chr(10), ' ').replace(chr(9), ' ')}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
