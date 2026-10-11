#!/usr/bin/env python3
"""Run history for the analyst: past runs' score logs as benchmarks, milestones and pace comparisons.

  python3 tools/analyst/history.py runs                       # every run with a score log, length and final state
  python3 tools/analyst/history.py at 40                      # every run at game minute 40 (SPM, techs, plates)
  python3 tools/analyst/history.py milestones shake2          # game minute each technology finished in a run
  python3 tools/analyst/history.py when oil-processing        # when each run finished a technology (or not)
  python3 tools/analyst/history.py study shake2               # a study document (docs/studies/), also from other branches

Score logs are `runs/<run>/scores.jsonl` (tools/score-loop.sh: cumulative production, research and buildings about
every 2 minutes), read from this checkout and from the main checkout (~/code/player-of-games/runs), where runs that
are not committed live. A run with several worlds (turn runs a and b) counts as one series per world.
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ROOTS = [os.path.join(REPO, "runs"), os.path.expanduser("~/code/player-of-games/runs")]
PACKS = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
         "production-science-pack", "utility-science-pack", "space-science-pack"]
SKIP = ("smoke", "mock")
# Who played (docs/PLAN.md results tables: world a was GPT-6 Astra and b Fable 5.1 in the solo rounds; round three's
# Fable run ended with 12 technologies, which is turns3h/b). Each label starts with what to call the run on air: the
# code names (coop1, turns1, baseline1) mean nothing to viewers (docs/studies/shake4.md, mistake 8).
LABELS = {"2026-10-10-baseline1/a": "say: an early solo test; GPT-6 Astra alone, base game, peaceful (no biters), real time",
          "2026-10-10-baseline1/b": "say: an early solo test; Fable 5.1 alone, base game, peaceful (no biters), real time",
          "2026-10-10-turns1/a": "say: an early solo test; GPT-6 Astra alone, base game, peaceful, turn mode (game paused while it thinks)",
          "2026-10-10-turns1/b": "say: an early solo test; Fable 5.1 alone, base game, peaceful, turn mode (game paused while it thinks)",
          "2026-10-10-turns3h/a": "say: an early solo test; GPT-6 Astra alone, base game, peaceful, turn mode, 3 h",
          "2026-10-10-turns3h/b": "say: an early solo test; Fable 5.1 alone, base game, peaceful, turn mode, 3 h",
          "2026-10-10-coop1": "say: the two-agent co-op test; GPT-6 Astra and Claude Opus 5.5 together, base game, "
                              "peaceful (no biters), real time, 2 h",
          "shake1": "say: the first nine-agent team run; base game, normal enemies, real time (docs/studies/shake1.md)",
          "shake2": "say: the second nine-agent team run; base game, normal enemies, real time (docs/studies/shake2.md)",
          "shake3": "say: the third nine-agent team run; base game, normal enemies, real time",
          "sapilot": "say: the three-agent Space Age pilot; Astra, Opus and Gemini Flash, normal enemies, real time, 30 min",
          "shake4": "say: the first nine-agent Space Age team run; normal enemies, real time (docs/studies/shake4.md)"}
SPACE_AGE_RUNS = ("sapilot", "shake4")  # every other run so far was the base game


def is_team_run(name):
    """The team runs (shake*, the Space Age pilot) are the benchmarks the analyst offers; the solo and co-op tests of
    10 October were one or two agents on peaceful maps, so they are kept for questions about them only."""
    return not name.startswith("2026-10-10-")


def is_space_age(name):
    return name.split("/")[0] in SPACE_AGE_RUNS or name.startswith("sa")


SP = " "


def label(name):
    shifts = f", shifts {' + '.join(SHIFTS[name])}" if len(SHIFTS.get(name, [])) > 1 else ""
    if name in LABELS:
        return f"{name} ({LABELS[name]}{shifts})"
    return f"{name} (Space Age{shifts})" if is_space_age(name) else (f"{name} ({shifts[2:]})" if shifts else name)


def resumed_from(run):
    """The run a shift continued (runs/RUN/resumed-from, written by tools/start-team.sh with POG_RESUME), or None."""
    for root in ROOTS:
        p = os.path.join(root, run, "resumed-from")
        if os.path.exists(p):
            return open(p).read().strip() or None
    return None


def chain_root(run):
    """The first shift of the world a run belongs to (the run itself when it was not resumed)."""
    seen = {run}
    while True:
        prev = resumed_from(run)
        if not prev or prev in seen:
            return run
        seen.add(prev)
        run = prev


SHIFTS = {}  # series name -> the runs (shifts) it is made of, when more than one
SPANS = {}   # run (shift) -> (first tick, last tick) of its own score log


def load_runs(exclude=None, teams_only=False):
    """{series name: snapshots}. exclude: the run being replayed or played live (a directory or a list of them),
    which must not be its own benchmark; nor may the earlier shifts of its world. teams_only: the team runs only."""
    series = load_all()
    if teams_only:
        series = {k: v for k, v in series.items() if is_team_run(k)}
    for e in ([exclude] if isinstance(exclude, str) else exclude or []):
        if e:
            ex = chain_root(os.path.basename(e.rstrip("/")))
            series = {k: v for k, v in series.items() if k != ex and not k.startswith(ex + "/")}
    return series


def load_all():
    series = {}
    SHIFTS.clear()
    SPANS.clear()
    for root in ROOTS:
        if not os.path.isdir(root):
            continue
        for run in sorted(os.listdir(root)):
            p = os.path.join(root, run, "scores.jsonl")
            if any(s in run for s in SKIP) or not os.path.exists(p):
                continue
            rows = {}
            with open(p) as f:
                lines = f.readlines()
            for line in lines:
                try:
                    j = json.loads(line)
                except json.JSONDecodeError:
                    continue
                sc = j.get("score") or {}
                if "tick" not in sc:
                    continue
                key = run if not j.get("world") else f"{run}/{j['world']}"
                rows.setdefault(key, []).append(sc)
            for k, v in rows.items():
                worlds = {r for r in rows}
                name = run if len(worlds) == 1 else k
                if name not in series:
                    v.sort(key=lambda r: r["tick"])
                    series[name] = dedupe(v)
                    SPANS[name] = (series[name][0]["tick"], series[name][-1]["tick"])
    # Shifts of one world (a resumed run continues its save's game time) are one series under the first shift's name.
    for name in list(series):
        root = chain_root(name)
        if root != name:
            series[root] = dedupe(sorted(series.get(root, []) + series.pop(name), key=lambda r: r["tick"]))
            SHIFTS.setdefault(root, [root]).append(name)
    def hops(run):
        n = 0
        while resumed_from(run) and n < 50:
            run, n = resumed_from(run), n + 1
        return n
    for runs in SHIFTS.values():
        runs.sort(key=hops)
    return series


def dedupe(rows):
    """Drop snapshots where the clock went backwards (a restarted world) and paused repeats."""
    out = []
    for r in rows:
        if out and r["tick"] <= out[-1]["tick"]:
            continue
        out.append(r)
    return out


def row_at(rows, minute):
    before = [r for r in rows if r["tick"] / 3600 <= minute + 1e-6]
    return before[-1] if before else None


def rate(rows, minute, items, window=10):
    """Items per minute over the window ending at minute (from cumulative totals)."""
    end = row_at(rows, minute)
    start = row_at(rows, minute - window)
    if not end or not start or end is start:
        return None
    span = (end["tick"] - start["tick"]) / 3600
    if span < 2:
        return None
    tot = lambda r: sum((r.get("produced") or {}).get(i, 0) for i in items)
    return (tot(end) - tot(start)) / span


def milestones(rows):
    first = {}
    for r in rows:
        for t in r.get("research_done") or []:
            first.setdefault(t, r["tick"] / 3600)
        for p in PACKS:
            if (r.get("produced") or {}).get(p):
                first.setdefault("first " + p, r["tick"] / 3600)
    return dict(sorted(first.items(), key=lambda kv: kv[1]))


def at_text(series, minute):
    lines = [f"past runs at game minute {minute:g} (SPM = all science packs per minute over the previous 10 min):"]
    for name, rows in series.items():
        r = row_at(rows, minute)
        last = rows[-1]["tick"] / 3600
        if not r or last < minute - 3:
            lines.append(f"- {label(name)}:{SP}run ended at minute {last:.0f}")
            continue
        s = rate(rows, minute, PACKS)
        fe = rate(rows, minute, ["iron-plate"])
        done = r.get("research_done") or []
        lines.append(f"- {label(name)}:{SP}{len(done)} techs" + (f", researching {r['current_research']}" if r.get("current_research") else "")
                     + (f", SPM {s:.1f}" if s is not None else "") + (f", iron plates {fe:.0f}/min" if fe is not None else "")
                     + f", labs {(r.get('entities') or {}).get('lab', 0)}, assemblers "
                     f"{sum(v for k, v in (r.get('entities') or {}).items() if k.startswith('assembling'))}")
    return "\n".join(lines)


def runs_text(series):
    lines = []
    for name, rows in series.items():
        last = rows[-1]
        s = rate(rows, last["tick"] / 3600, PACKS)
        lines.append(f"- {label(name)}:{SP}{len(rows)} snapshots to game {last['tick'] / 3600:.0f} min; {len(last.get('research_done') or [])} techs; "
                     f"final SPM {s:.1f}" if s is not None else f"- {label(name)}:{SP}{len(rows)} snapshots to game {last['tick'] / 3600:.0f} min")
    return "\n".join(lines)


def when_text(series, tech):
    lines = [f"when past runs finished {tech}:"]
    for name, rows in series.items():
        m = milestones(rows).get(tech)
        lines.append(f"- {label(name)}:{SP}" + (f"game minute {m:.0f}" if m is not None else f"not reached (run ended at minute {rows[-1]['tick'] / 3600:.0f})"))
    return "\n".join(lines)


def resume_tick(run):
    """The tick a resumed shift started at ("resumed at tick N" in runs/RUN/start.log), or None."""
    for root in ROOTS:
        p = os.path.join(root, run, "start.log")
        if os.path.exists(p):
            with open(p, errors="replace") as f:
                m = re.search(r"resumed at tick (\d+)", f.read())
            if m:
                return int(m.group(1))
    return None


def world_text(run, series=None):
    """For a live or replayed run that continues an earlier shift's world: the game minutes each shift played, and
    the world's own milestones and science rate so far (all shifts as one series). None for a first shift."""
    run = os.path.basename((run or "").rstrip("/"))
    if not run or not resumed_from(run):
        return None
    root = chain_root(run)
    series = series if series is not None else load_all()
    rows = series.get(root) or []
    shifts = SHIFTS.get(root) or [root, run]
    starts = {s: (0 if i == 0 else resume_tick(s) or SPANS[s][0]) for i, s in enumerate(shifts) if s in SPANS}
    spans = ", ".join(f"{s} game minutes {starts[s] / 3600:.0f} to {SPANS[s][1] / 3600:.0f}" if s in SPANS else s
                      for s in shifts)
    start = resume_tick(run) or SPANS.get(run, (None,))[0]
    lines = [f"This run ({run}) is a resumed shift: the same world, base and agents as {root}, continued from its save"
             + (f" at game minute {start / 3600:.0f}" if start else "") + f". Shifts so far: {spans}. Everything before "
             "this shift is this team's own earlier play, not another team's: count pace and say times in game time (the "
             "game clock carried on), never time since this stream or shift started. The agents restarted their sessions "
             "at the shift change and re-read their notes, so a slow minute or two after the resume is the restart."]
    if rows:
        ms = milestones(rows)
        lines.append("This world's technologies by game minute (all shifts): "
                     + ", ".join(f"{t} {m:.0f}" for t, m in ms.items() if not t.startswith("first ")))
        firsts = [f"{t[6:]} minute {m:.0f}" for t, m in ms.items() if t.startswith("first ")]
        if firsts:
            lines.append("First science pack of each colour: " + ", ".join(firsts))
        pts = [f"minute {m}: {r:.1f}" for m in range(30, int(rows[-1]["tick"] / 3600) + 1, 30)
               for r in [rate(rows, m, PACKS)] if r is not None]
        if pts:
            lines.append("This world's science per minute (all packs, 10-minute window): " + ", ".join(pts))
    return "\n".join(lines)


def study_text(name):
    for d in (os.path.join(REPO, "docs", "studies"), os.path.expanduser("~/code/player-of-games/docs/studies")):
        p = os.path.join(d, name if name.endswith(".md") else name + ".md")
        if os.path.exists(p):
            return open(p).read()
    for branch in ("research/shake2", "main", "research/transcripts"):
        r = subprocess.run(["git", "-C", REPO, "show", f"{branch}:docs/studies/{name if name.endswith('.md') else name + '.md'}"],
                           capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout
    return f"no study named {name}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["runs", "at", "milestones", "when", "study"])
    ap.add_argument("arg", nargs="?")
    a = ap.parse_args()
    if a.cmd == "study":
        print(study_text(a.arg or "shake1"))
        return
    series = load_runs()
    if a.cmd == "runs":
        print(runs_text(series))
    elif a.cmd == "at":
        print(at_text(series, float(a.arg)))
    elif a.cmd == "when":
        print(when_text(series, a.arg))
    elif a.cmd == "milestones":
        rows = series.get(a.arg)
        if not rows:
            print(f"no run {a.arg}; runs: {', '.join(series)}")
            return
        print("\n".join(f"{m:5.1f} min  {t}" for t, m in milestones(rows).items()))


if __name__ == "__main__":
    main()
