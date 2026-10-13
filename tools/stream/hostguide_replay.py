#!/usr/bin/env python3
"""Replay logged host moments with the new headline facts and booth guide: old line as aired, new line(s).

  python3 tools/stream/hostguide_replay.py                       # the shift04/05 moments, template writer (offline)
  python3 tools/stream/hostguide_replay.py --writer or:anthropic/claude-sonnet-5.5   # the hosts' writer (network, keys)

Each moment is a caster log record (tools/stream/logs/caster-*.jsonl, main checkout) and what eng/hostguide turns it
into: a platform hub lost becomes a "platform destroyed" headline (the platform's name is not in the old logs: it is
given per moment below, from the shift05 opening "Now Skylark is lost" and the operator's notes), and a death folded
into an attack beat becomes its own death headline. The facts are the logged ones (background, shift, recent lines)
plus the headline facts model.py now produces; the prompt is the current caster.py prompt (SPOKEN + DIALOGUE).
"""
import argparse, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import caster  # noqa: E402

LOGS = os.path.expanduser("~/code/player-of-games/tools/stream/logs")
# (log, record time, the headline it becomes)
MOMENTS = [
    ("caster-20261013-024941.jsonl", 1791893756.97,
     {"kind": "headline", "text": "Skylark destroyed in orbit of Vulcanus by medium metallic asteroids",
      "facts": {"headline": "platform_destroyed", "platform": "Skylark", "where": "in orbit of Vulcanus",
                "destroyed_by": "medium metallic asteroids", "platforms_left": ["Starling"],
                "what_it_means": "its hub is gone, so the platform and everything aboard it are lost"},
      "note": "platform name assumed (Skylark or Starling, per the operator)"}),
    ("caster-20261013-065610.jsonl", 1791906274.04,
     {"kind": "headline", "text": "Starling destroyed in orbit of Vulcanus by medium metallic asteroids",
      "facts": {"headline": "platform_destroyed", "platform": "Starling", "where": "in orbit of Vulcanus",
                "destroyed_by": "medium metallic asteroids", "platforms_left": "none",
                "what_it_means": "its hub is gone, so the platform and everything aboard it are lost"},
      "note": "platform name and place assumed for the demo"}),
    ("caster-20261013-024941.jsonl", 1791894622.59,
     {"kind": "death", "text": "Haiku died", "facts": {"headline": "agent_death", "agent": "Haiku"}}),
    ("caster-20261013-024941.jsonl", 1791887060.73,
     {"kind": "death", "text": "Opus died", "facts": {"headline": "agent_death", "agent": "Opus"}}),
    ("caster-20261013-065610.jsonl", 1791902910.78,
     {"kind": "attack", "text": "Platform Starling (in orbit of Vulcanus) under attack: space platform hub",
      "note": "an attack on a platform, now named (name assumed for the demo)"}),
]


def record(log, t):
    for line in open(os.path.join(LOGS, log)):
        r = json.loads(line)
        if r.get("type") == "caster" and abs((r.get("t") or 0) - t) < 0.05:
            return r
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--writer", default="template", help="template (offline) or or:MODEL / cf:MODEL / claude:MODEL")
    a = ap.parse_args()
    if a.writer == "template":
        w = caster.TemplateWriter()
    else:
        kind, _, model = a.writer.partition(":")
        w = caster.LLMWriter(kind, model or None, timeout=30)
    for log, t, new in MOMENTS:
        r = record(log, t)
        if not r:
            print(f"{log} {t}: not found")
            continue
        old = r["facts"]
        e = dict(new, t=t, prio=caster.PRIORITY[new["kind"]])
        f = caster.facts_for(e, {"agents": [], "game_time": None})
        for k in ("game_time", "minutes_to_deadline", "shift", "planets_reached", "background", "earlier_on_air",
                  "corrections", "framings_used_lately"):
            if k in old:
                f[k] = old[k]
        print(f"== {r['event']} at {old.get('game_time')} ({log[7:22]}){'  [' + new['note'] + ']' if new.get('note') else ''}")
        print(f"   old  {caster.CASTERS[r['who']]['name']}: {r['line']}")
        if a.writer == "template":
            names = ["Skylark", "Starling", "Haiku", "Opus"]
            for who in ("pbp", "color"):
                print(f"   new  {caster.CASTERS[who]['name']}: {w.write(who, e, f, [], names)}")
        else:
            for who, line in w.exchange(e, f, old.get("earlier_on_air") or [], first="pbp", n=2):
                print(f"   new  {caster.CASTERS[who]['name']}: {line}")


if __name__ == "__main__":
    main()
