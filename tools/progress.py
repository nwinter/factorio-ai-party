#!/usr/bin/env python3
"""fh progress: the run so far by shift, read from the recorded data on this Mac (viewers Alex 22:00: "let them review
the overall progress of the run"; Foobator 15:46: an objective progress measure).
  fh progress [--full] [--last N] [--format json]      (bin/fh runs this file; no game call)
  python3 tools/progress.py [--runs DIR] [--full] [--last N] [--format json]

Reads, per shift of the run (runs/RUN/resumed-from chains them, from site.json's run_start):
  scores.jsonl      through site/longrun.py, the site's own long-run reading: game time, technologies, science per
                    minute (research units a minute: the labs' use of packs in sets), packs made, plates and circuits
                    a minute, rockets, platforms, planets; loss alerts from stream-service.log (the director's cuts)
  agent-stats.json  the team's deaths and items moved by hand (summed over the agents; no agent is listed)
  efficiency.jsonl  machines, machines running, items made by machines and moved by hand (since shift13)
  tokens.json       the team's tokens and model calls (--full)
A shift's own changes run from its first score row to its last. A shift that began from an earlier save than the
shift before ended on says so (rolled_back). Facts only: numbers as recorded, no ranking of agents.
"""
import argparse
import datetime
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "site"))
import longrun  # noqa: E402  (site/longrun.py)

TREND = 3  # shifts in the trend line


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def last_jsonl(path):
    """The last parseable line of a JSONL file, or None."""
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            return json.loads(line)
        except ValueError:
            continue
    return None


def team_stats(d):
    """agent-stats.json summed over the agents: deaths, items moved by hand; the team's machines when recorded."""
    s = read_json(d / "agent-stats.json")
    if not isinstance(s, dict):
        return {}
    agents = s.get("agents")
    rows = list(agents.values()) if isinstance(agents, dict) else agents if isinstance(agents, list) else []
    rows = [r for r in rows if isinstance(r, dict)]
    out = {"deaths": sum(int(r.get("deaths") or 0) for r in rows),
           "hand_moved": sum(int(r.get("haul_items") or 0) for r in rows),
           # the game's own hauling count (shift10 on), else the journals' direct calls only
           "hand_from": "journal" if any(r.get("haul_from") == "journal" for r in rows) else "game"}
    m = s.get("machines_team")
    if isinstance(m, dict):
        out.update(machines=m.get("machines"), running=m.get("machines_working"), made_items=m.get("made_items"),
                   machine_share_pct=m.get("made_share_pct"))
    return out


def efficiency(d):
    """The last efficiency.jsonl row's team line: machines, running, items made and moved by hand this shift."""
    r = last_jsonl(d / "efficiency.jsonl")
    t = r.get("team") if isinstance(r, dict) else None
    if not isinstance(t, dict):
        return {}
    return {"machines": t.get("machines"), "running": t.get("running"), "made_items": t.get("items_shift"),
            "hand_items": t.get("hand_items_shift"), "machine_share_pct": t.get("machine_share_pct")}


def tokens(d):
    t = read_json(d / "tokens.json")
    agents = t.get("agents") if isinstance(t, dict) else None
    if not isinstance(agents, dict):
        return None
    rows = [v for v in agents.values() if isinstance(v, dict)]
    return {"total": sum(int(v.get("total") or 0) for v in rows), "output": sum(int(v.get("output") or 0) for v in rows),
            "calls": sum(int(v.get("calls") or 0) for v in rows), "final": bool(t.get("final"))}


def labs_use(a, b, mins):
    """{pack: packs the labs used a minute} between two score rows, or None."""
    used = longrun.used_between(a, b)
    if used is None or mins <= 0:
        return None
    return {k: round(v / mins, 1) for k, v in sorted(used.items()) if v > 0}


def run_start(runs_dir):
    site = read_json(ROOT / "site" / "content" / "site.json") or {}
    start = os.environ.get("POG_RUN_START") or site.get("run_start")
    return start if start and (runs_dir / start).is_dir() else None


def load(runs_dir):
    runs_dir = Path(runs_dir)
    start = run_start(runs_dir)
    long_ = longrun.load(runs_dir, start=start)
    if not long_:
        return None
    shifts, prev_end = [], None
    for s in long_["shifts"]:
        d = runs_dir / s["id"]
        if s.get("empty"):
            shifts.append({"shift": s["id"], "played": False, "note": s.get("note")})
            continue
        sc = longrun.scores(d / "scores.jsonl")
        a, b = sc[0], sc[-1]
        mins = (b["tick"] - a["tick"]) / 3600
        row = {"shift": s["id"], "played": True, "started": s["started"], "ended": s["ended"], "running": bool(s.get("running")),
               "game_start": longrun.game_time(a["tick"]), "game_end": longrun.game_time(b["tick"]),
               "game_minutes": round(mins, 1),
               "research": b["research"], "research_new": len(b["done"] - a["done"]),
               "researched": sorted(b["done"] - a["done"]), "researching": s.get("researching"),
               "spm": s.get("spm"), "labs_use_per_min": labs_use(a, b, mins),
               "packs_made_per_min": s.get("made_per_min"), "packs_made": {k: v for k, v in sorted(s.get("made", {}).items()) if v},
               "output_per_min": s.get("output_per_min"),
               "rockets": b["rockets"], "rockets_new": max(0, b["rockets"] - a["rockets"]),
               "platforms": [{"name": p, "at": b["at"].get(p)} for p in b["platforms"]],
               "platforms_built": s.get("platforms_built") or [], "platforms_lost": s.get("platforms_lost") or [],
               "planets": b["planets"], "loss_alerts": s.get("losses")}
        if prev_end is not None and a["raw"] < prev_end["raw"]:
            row["rolled_back"] = {"game_start": longrun.game_time(a["raw"]), "previous_end": longrun.game_time(prev_end["raw"]),
                                  "game_minutes": round((prev_end["raw"] - a["raw"]) / 3600, 1)}
        prev_end = b
        st = team_stats(d)
        row["deaths"] = st.get("deaths") if st else s.get("deaths")
        row["deaths_from"] = "journals" if st else "director"
        row["hand_moved"] = st.get("hand_moved")
        eff = efficiency(d)
        mach = {k: v for k, v in (eff or st).items() if k in ("machines", "running", "made_items", "hand_items", "machine_share_pct")}
        row["machines"] = mach.get("machines")
        row["machines_running"] = mach.get("running")
        row["made_by_machines"] = mach.get("made_items")
        row["moved_by_hand"] = mach.get("hand_items") if mach.get("hand_items") is not None else row["hand_moved"]
        row["moved_by_hand_from"] = "game" if mach.get("hand_items") is not None else st.get("hand_from")
        del row["hand_moved"]
        row["machine_share_pct"] = mach.get("machine_share_pct")
        row["tokens"] = tokens(d)
        shifts.append(row)
    played = [r for r in shifts if r.get("played")]
    last = played[-1] if played else None
    plats = long_.get("platforms") or []
    totals = {"shifts": len(played), "first": played[0]["shift"] if played else None, "last": last["shift"] if last else None,
              "game_time": last["game_end"] if last else None, "research": last["research"] if last else 0,
              "rockets": last["rockets"] if last else 0, "packs_made": dict(sorted(long_["made"].items())),
              "packs_made_total": sum(long_["made"].values()),
              "platforms": [p["name"] for p in plats if not p.get("lost")],
              "platforms_lost": [p["name"] for p in plats if p.get("lost")],
              "planets": last["planets"] if last else [],
              "deaths": sum(r.get("deaths") or 0 for r in played), "loss_alerts": sum(r.get("loss_alerts") or 0 for r in played),
              "tokens": sum((r.get("tokens") or {}).get("total", 0) for r in played) or None,
              "rollbacks": [r["shift"] for r in played if r.get("rolled_back")]}
    recent = played[-TREND:]
    trend = {"shifts": [r["shift"] for r in recent], "spm": [r["spm"] for r in recent],
             "research_new": [r["research_new"] for r in recent], "rockets_new": [r["rockets_new"] for r in recent],
             "packs_made_per_min": [r["packs_made_per_min"] for r in recent],
             "plates_per_min": [(r.get("output_per_min") or {}).get("plates") for r in recent],
             "circuits_per_min": [(r.get("output_per_min") or {}).get("circuits") for r in recent],
             "deaths": [r.get("deaths") for r in recent]}
    return {"shifts": shifts, "totals": totals, "trend": trend,
            "measures": {"spm": "research units a minute: the labs' use of packs in sets (the most-used pack that does not spoil); "
                                "- where the shift's score log has no lab counts",
                         "packs_made_per_min": "science packs made a minute, all colours",
                         "output_per_min": "plates (iron, copper, steel) and circuits (green, red, blue) made a minute",
                         "own changes": "research_new, rockets_new: from the shift's first score row to its last",
                         "deaths": "the agents' deaths in their journals (summed)",
                         "moved_by_hand": "items the agents moved by hand (transfers, queue and order steps; the game's count; "
                                          "marked journals: counted from direct calls in the journals)",
                         "made_by_machines": "items made this shift by the machines the agents built (since shift13)",
                         "loss_alerts": "loss alerts the stream's director cut to"}}


# -------------------------------------------------------------------- text

def num(v):
    """1.5, 42.9, 1485, 149k, 1.20M, 11.09B: one decimal under 100, whole numbers to 9999, then k, M and B; - not
    recorded."""
    if v is None:
        return "-"
    if isinstance(v, float) and abs(v) < 100:
        return f"{round(v, 1):g}"
    v = int(round(v))
    if abs(v) >= 1_000_000_000:
        return f"{v / 1_000_000_000:.2f}B"
    if abs(v) >= 1_000_000:
        return f"{v / 1_000_000:.2f}M"
    if abs(v) >= 10_000:
        return f"{v / 1000:.0f}k"
    return str(v)


def hm(t):
    try:
        return datetime.datetime.fromisoformat(t).strftime("%H:%M")
    except (TypeError, ValueError):
        return "?"


def shift_line(r):
    if not r.get("played"):
        return f"{r['shift']}: {r.get('note') or 'no score log'}"
    out = r.get("output_per_min") or {}
    parts = [f"{r['shift']} {hm(r['started'])}-{hm(r['ended'])}{' (on)' if r['running'] else ''} game {r['game_start']}-{r['game_end']}",
             f"techs +{r['research_new']} ({r['research']})", f"SPM {num(r['spm'])}", f"packs {num(r['packs_made_per_min'])}/min",
             f"plates {num(out.get('plates'))}/min circuits {num(out.get('circuits'))}/min",
             f"rockets +{r['rockets_new']} ({r['rockets']})", f"deaths {num(r.get('deaths'))}", f"loss alerts {num(r.get('loss_alerts'))}"]
    if r.get("machines") is not None:
        parts.append(f"machines {num(r.get('machines_running'))}/{num(r['machines'])} running")
    if r.get("made_by_machines") is not None:
        parts.append(f"made {num(r['made_by_machines'])}, by hand {num(r.get('moved_by_hand'))} ({num(r.get('machine_share_pct'))}% machines)")
    elif r.get("moved_by_hand") is not None:
        parts.append(f"by hand {num(r['moved_by_hand'])}{' (journals)' if r.get('moved_by_hand_from') == 'journal' else ''}")
    if r.get("rolled_back"):
        rb = r["rolled_back"]
        parts.append(f"began from an earlier save ({rb['game_start']}; the shift before ended at {rb['previous_end']})")
    return " | ".join(parts)


def totals_line(t):
    parts = [f"run {t['first']}-{t['last']} ({t['shifts']} shifts), game {t['game_time']}", f"techs {t['research']}",
             f"rockets {t['rockets']}", f"packs made {num(t['packs_made_total'])}",
             f"platforms {', '.join(t['platforms']) or 'none'}" + (f" (lost {len(t['platforms_lost'])})" if t['platforms_lost'] else ""),
             f"planets {', '.join(t['planets']) or 'nauvis'}", f"deaths {t['deaths']}", f"loss alerts {t['loss_alerts']}"]
    if t.get("rollbacks"):
        parts.append(f"earlier save at {', '.join(t['rollbacks'])}")
    return " | ".join(parts)


def trend_line(tr):
    if not tr["shifts"]:
        return ""

    def seq(vals, sign=False):
        return ", ".join(("+" if sign and v is not None else "") + num(v) for v in vals)
    return (f"last {len(tr['shifts'])} ({tr['shifts'][0]}-{tr['shifts'][-1]}): SPM {seq(tr['spm'])} | techs {seq(tr['research_new'], True)}"
            f" | rockets {seq(tr['rockets_new'], True)} | packs/min {seq(tr['packs_made_per_min'])} | plates/min {seq(tr['plates_per_min'])}"
            f" | circuits/min {seq(tr['circuits_per_min'])} | deaths {seq(tr['deaths'])}")


def full_block(r):
    lines = [shift_line(r)]
    if not r.get("played"):
        return lines
    lines.append(f"  time {r['started']} - {r['ended']}, {num(r['game_minutes'])} game minutes")
    if r["researched"]:
        lines.append(f"  researched ({len(r['researched'])}): {', '.join(r['researched'])}")
    if r.get("researching"):
        lines.append(f"  researching at the end: {r['researching']}")
    if r.get("labs_use_per_min"):
        lines.append("  labs' use a minute: " + ", ".join(f"{k.replace('-science-pack', '')} {num(v)}" for k, v in r["labs_use_per_min"].items()))
    if r.get("packs_made"):
        lines.append("  packs made: " + ", ".join(f"{k.replace('-science-pack', '')} {num(v)}" for k, v in r["packs_made"].items()))
    plats = ", ".join(f"{p['name']} ({p['at'] or '?'})" for p in r["platforms"]) or "none"
    lines.append(f"  platforms {plats}; built {', '.join(r['platforms_built']) or 'none'}; lost {', '.join(r['platforms_lost']) or 'none'}")
    lines.append(f"  planets {', '.join(r['planets'])}")
    if r.get("tokens"):
        t = r["tokens"]
        lines.append(f"  team tokens {num(t['total'])} (output {num(t['output'])}), {num(t['calls'])} model calls{'' if t['final'] else ' so far'}")
    return lines


def text(data, full=False, last=None):
    shifts = data["shifts"][-last:] if last else data["shifts"]
    out = []
    for r in shifts:
        out.extend(full_block(r) if full else [shift_line(r)])
    out.append(totals_line(data["totals"]))
    tl = trend_line(data["trend"])
    if tl:
        out.append(tl)
    if full:
        t = data["totals"]
        out.append("packs made in the run: " + ", ".join(f"{k.replace('-science-pack', '')} {num(v)}" for k, v in t["packs_made"].items()))
        if t["platforms_lost"]:
            out.append("platforms lost: " + ", ".join(t["platforms_lost"]))
        if t.get("tokens"):
            out.append(f"team tokens in the run: {num(t['tokens'])}")
        out.append("measures: " + "; ".join(f"{k}: {v}" for k, v in data["measures"].items()))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fh progress", description="The run so far by shift, from the recorded data (no game call).")
    ap.add_argument("--full", action="store_true", help="each shift in full: technologies, labs' use and packs made, platforms, tokens")
    ap.add_argument("--last", type=int, help="only the last N shifts (totals and trend cover the run)")
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument("--runs", default=os.environ.get("POG_RUNS_DIR") or str(ROOT / "runs"), help=argparse.SUPPRESS)
    # the workspace wrapper (runs/RUN/BOT/fh) appends these to every fh command
    ap.add_argument("--bot", help=argparse.SUPPRESS)
    ap.add_argument("--journal", help=argparse.SUPPRESS)
    a, rest = ap.parse_known_args(argv)
    if rest:
        ap.error("unknown arguments: " + " ".join(rest) + " (fh progress takes --full, --last N, --format json)")
    if a.last is not None and a.last < 1:
        ap.error("--last takes 1 or more")
    data = load(a.runs)
    if data is None:
        print("no recorded shifts yet (no score log in the run's shifts)")
        return 0
    if a.format == "json":
        if a.last:
            data = dict(data, shifts=data["shifts"][-a.last:])
        print(json.dumps(data, indent=1))
    else:
        print(text(data, a.full, a.last))
    return 0


if __name__ == "__main__":
    sys.exit(main())
