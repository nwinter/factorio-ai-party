#!/usr/bin/env python3
"""Quota headroom per route before a run or shift (docs/studies/shake5.md, P1 item 6: Gemini started shake5 at 72% of
its 5-hour window and ran dry 47 minutes in).

  tools/quota_check.py TEAM_FILE MINUTES [--brief FILE] [--now EPOCH] [--save FILE]

Reads `ai-usage agent --json` (read-only; falls back to its cached ~/.cache/ai-usage/agent-brief.json), maps each team
member's route to an ai-usage profile, and projects each quota window over the run with the hourly burn in
agent/quota-burn.tsv (or the file POG_QUOTA_BURN names; none: no burn rates) times the agents on that profile. Prints one line per profile and window; a line starting
"WARNING" for a window likely to run dry before the run ends. Always exits 0: the warnings are for the operator.
--save FILE keeps the brief it read (tools/start-team.sh: tools/quota_rest.py --at-limit reads it once the agents'
workspaces exist, without a second ai-usage call). at_limit() names the members whose account is at its limit now.
"""
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AI_USAGE = "/Users/owner/.local/bin/ai-usage"
CACHED = os.path.expanduser("~/.cache/ai-usage/agent-brief.json")
# Routes are ai-usage profile commands (codex-b, claude, ...); "-" means the harness's own login.
KIND_COMMAND = {"grok": "grok", "agy": "agy", "muse": "muse", "codex": "codex", "claude": "claude"}


def load_brief(path=None):
    """(brief, note): the given file, else a fresh `ai-usage agent --json`, else its cached copy."""
    if path:
        return json.load(open(path)), f"from {path}"
    try:
        out = subprocess.run([AI_USAGE, "agent", "--json"], capture_output=True, text=True, timeout=120)
        if out.returncode == 0:
            return json.loads(out.stdout), "live"
        err = (out.stderr.strip().splitlines() or ["no output"])[-1][:120]
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        err = str(e)[:120]
    try:
        brief = json.load(open(CACHED))
        age = int(time.time() - brief.get("generated_at", 0)) // 60
        return brief, f"cached {age} min ago (ai-usage failed: {err})"
    except (OSError, ValueError):
        return None, f"no quota data (ai-usage failed: {err})"


def burn_rates():
    rates = {}
    path = os.environ.get("POG_QUOTA_BURN") or os.path.join(ROOT, "agent", "quota-burn.tsv")
    if not os.path.isfile(path):
        return rates   # the public export has no measured rates: only a full window warns
    for line in open(path):
        if line.strip() and not line.startswith("#"):
            profile, window, rate = line.rstrip("\n").split("\t")
            rates[(profile, window)] = float(rate)
    return rates


def relevant(label, model):
    """Scoped windows count only for their models: agy's Gemini vs Claude/GPT, Claude's Fable."""
    gemini = "gemini" in model
    if label.startswith("Gemini") and not gemini:
        return False
    if label.startswith("Claude/GPT") and gemini:
        return False
    if "Fable" in label and "fable" not in model:
        return False
    return True


def check(brief, team_file, minutes, now=None):
    now = now or time.time()
    end = now + minutes * 60
    by_command = {p.get("command"): p for p in brief.get("profiles", [])}
    users = {}   # profile id -> [(name, model)]
    lines = []
    for line in open(team_file):
        if not line.strip() or line.startswith("#"):
            continue
        name, kind, route, model = line.rstrip("\n").split("\t")[:4]
        command = route if route != "-" else KIND_COMMAND.get(kind, kind)
        p = by_command.get(command)
        if p is None:
            lines.append(f"WARNING quota: {name} (route {command}): no ai-usage profile for it, headroom unknown")
            continue
        users.setdefault(p["id"], []).append((name, model))
    rates = burn_rates()
    hhmm = lambda t: time.strftime("%H:%M", time.localtime(t))
    for pid, members in users.items():
        p = next(q for q in brief["profiles"] if q["id"] == pid)
        names = ",".join(n for n, _ in members)
        if p.get("stale") or not p.get("available", True):
            lines.append(f"WARNING quota {pid} ({names}): ai-usage data is stale or unavailable")
        for w in p.get("windows", []):
            label = w["label"]
            ms = [m for _, m in members if relevant(label, m)]
            if not ms:
                continue
            rate = rates.get((pid, label), 0.0) * len(ms)
            pct, reset = float(w.get("percent") or 0), float(w.get("resets_at") or 0)
            # Burn until the window resets (or the run ends), then from 0 after a reset inside the run.
            dry = None
            first = min(end, reset) if reset > now else end
            if pct >= 100:
                dry = now
            elif rate and pct + rate * (first - now) / 3600 >= 100:
                dry = now + (100 - pct) / rate * 3600
            elif rate and reset > now and end > reset and rate * (end - reset) / 3600 >= 100:
                dry = reset + 100 / rate * 3600
            what = (f"{pid} ({names}) {label}: {pct:.0f}% used, about {rate:.1f}%/h for {len(ms)} agent"
                    f"{'s' if len(ms) > 1 else ''}, resets {hhmm(reset) if reset else '?'}")
            if dry is not None and dry < end:
                when = "now" if dry <= now else f"at about {hhmm(dry)}"
                after = f"; it resets at {hhmm(reset)}" if now < reset < end else ""
                lines.append(f"WARNING quota {what}: likely to run dry {when}, before the run ends at {hhmm(end)}{after}")
            else:
                at_end = pct + rate * (first - now) / 3600 if not (now < reset < end) else rate * (end - reset) / 3600
                lines.append(f"quota {what}: ok (about {min(at_end, 100):.0f}% at {hhmm(end)})")
    return lines


# At its limit: a window at LIMIT_PCT or more. The windows read in whole percent, and at 20:09 on 2026-10-22 ai-usage
# read Grok's weekly window at 99% five minutes after the grok CLI stopped on its weekly limit (d22 batch108 BR1). A
# member marked resting who can play after all ends the rest with its first request (rests.lua, pacing.py).
LIMIT_PCT = float(os.environ.get("POG_QUOTA_LIMIT_PCT", 99))


def members(team_file):
    """[(name, kind, route command, model)] of a team file."""
    out = []
    for line in open(team_file):
        if not line.strip() or line.startswith("#"):
            continue
        name, kind, route, model = line.rstrip("\n").split("\t")[:4]
        out.append((name, kind, route if route != "-" else KIND_COMMAND.get(kind, kind), model))
    return out


def at_limit(brief, team_file, now=None):
    """{name: {"reset": epoch, "window": label, "percent": p, "profile": id}} for each team member whose account is at
    its limit now: a window that counts for its model at LIMIT_PCT or more, with its reset ahead (the latest such reset
    when several are). A profile ai-usage marks stale or unavailable is left out: its numbers are not now's."""
    now = now or time.time()
    by_command = {p.get("command"): p for p in brief.get("profiles", [])}
    out = {}
    for name, _, command, model in members(team_file):
        p = by_command.get(command)
        if p is None or p.get("stale") or not p.get("available", True):
            continue
        for w in p.get("windows", []):
            pct, reset = float(w.get("percent") or 0), float(w.get("resets_at") or 0)
            if relevant(w["label"], model) and pct >= LIMIT_PCT and reset > now:
                if name not in out or reset > out[name]["reset"]:
                    out[name] = {"reset": reset, "window": w["label"], "percent": pct, "profile": p.get("id")}
    return out


def main():
    args = sys.argv[1:]
    brief_path = now = None
    if "--brief" in args:
        i = args.index("--brief"); brief_path = args[i + 1]; del args[i:i + 2]
    if "--now" in args:
        i = args.index("--now"); now = float(args[i + 1]); del args[i:i + 2]
    save = None
    if "--save" in args:
        i = args.index("--save"); save = args[i + 1]; del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    brief, note = load_brief(brief_path)
    print(f"quota data: {note}")
    if save and brief is not None:
        try:
            with open(save, "w") as f:
                json.dump(brief, f)
        except OSError as e:
            print(f"quota data: not saved to {save} ({e})")
    if brief is None:
        print("WARNING quota: no ai-usage data; check each route's headroom by hand")
        return
    for line in check(brief, args[0], int(args[1]), now):
        print(line)


if __name__ == "__main__":
    main()
