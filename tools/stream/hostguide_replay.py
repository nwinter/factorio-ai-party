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
import argparse, ast, json, os, re, sys, time

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


RUN07 = os.path.expanduser("~/code/player-of-games/runs/shift07")
STORY_LOGS = ["caster-20261013-110316.jsonl", "caster-20261013-151243.jsonl"]  # shift06 (headlines) and shift07
DIRECTOR = re.compile(r"^\[director\] (\d\d:\d\d:\d\d) (?:threat battle (\S+?)@(\d+): (take|skip) \((.*); (\{.*\})\)"
                      r"|BATTLE \(|battle over after (\d+) s)")


def at(day, hms):
    return time.mktime(time.strptime(f"{day} {hms}", "%Y-%m-%d %H:%M:%S"))


def director_fights(path, day="2026-10-13"):
    """The director's battle candidates (key, first, parts, logged at) and key-battle windows, from its log."""
    cands, battles, start = [], [], None
    for line in open(path, errors="replace"):
        m = DIRECTOR.match(line)
        if not m:
            continue
        t = at(day, m.group(1))
        if m.group(2):
            parts = ast.literal_eval(m.group(6))
            cands.append({"t": t, "key": m.group(2), "first": float(m.group(3)), "parts": parts})
        elif m.group(7):
            battles.append((t - int(m.group(7)), t))
        else:
            start = t
    return cands, battles


def snapshot_at(t, cands, battles):
    """The fights and battle a host beat at t saw, as far as the director log tells (no positions: a loss counts as
    near, a battle on air as this fight's)."""
    fights = {}
    for c in cands:
        if t - 120 <= c["t"] <= t:
            f = fights.setdefault(c["key"], {"key": c["key"], "first": c["first"], "last": c["t"], "losses": [],
                                             "agent": c["key"].split(":", 1)[1] if c["key"].startswith("attack:") else None,
                                             "position": {"x": 0, "y": 0}})
            f["last"] = c["t"]
            if c["key"].startswith("loss:") and c["parts"].get("pieces"):
                f["losses"] = [c["t"]]
    on = next((b for b in battles if b[0] <= t <= b[1]), None)
    return {"fights": list(fights.values()), "onair": {"battle": "held" if on else None},
            "held": on}


def story_replay(a, w):
    """shift07 16:20-16:38 (viewer Joonazan 16:38: "why is Rook always out of the loop?"): each host beat as aired,
    whether an attack is still a beat (hoststory.AttackGate on the director's own threat scores), and the facts
    with and without the story memo (hoststory.StoryMemo, rebuilt from the caster logs as of that beat)."""
    import hoststory
    recs = []
    for log in STORY_LOGS:
        recs += [json.loads(l) for l in open(os.path.join(LOGS, log))]
    recs.sort(key=lambda r: r.get("t") or 0)
    cands, battles = director_fights(os.path.join(RUN07, "stream-service.log"))
    gate = hoststory.AttackGate(os.path.join(RUN07, "threat-history.json"))
    story = hoststory.StoryMemo(None)
    plan, said, research = {}, {}, None
    lo, hi = at("2026-10-13", "16:20:00"), at("2026-10-13", "16:38:59")
    kept = dropped = 0
    for r in recs:
        t, f = r.get("t") or 0, r.get("facts") or {}
        if r.get("type") == "agent":
            said[r["agent"]] = {"text": r.get("line"), "t": t}
            continue
        if r.get("type") != "caster":
            continue
        if f.get("team_plan"):
            plan = f["team_plan"]
        if (f.get("background") or {}).get("researching"):
            research = f["background"]["researching"]
        text = f.get("what_happened") or f.get("text")
        if r.get("event") in ("space", "headline", "death", "loss") and text:
            story.note({"kind": r["event"], "text": text}, t)
        if not (lo <= t <= hi) or r.get("who") != "pbp" and r.get("exchange") and any(
                x.get("exchange") == r.get("exchange") and x.get("who") == "pbp" for x in recs if x.get("type") == "caster"):
            continue
        doing = [{"name": d.split(":", 1)[0], "text": d.split(":", 1)[1].strip()} for d in plan.get("who_does_what") or []]
        snap = {"board": {"plan": {"goals": plan.get("goals"), "doing": doing}},
                "agents": [{"name": n, "display_name": n.title(), "last_said": said.get(n), "seen": True}
                           for n in sorted({d["name"] for d in doing} | set(said))],
                "research": {"label": (research or {}).get("tech"), "progress": (research or {}).get("percent")}}
        memo = story.update(snap, t, force=True)
        print(f"== {time.strftime('%H:%M:%S', time.localtime(t))} {r['event']}: {text or ''}")
        print(f"   aired  {caster.CASTERS[r['who']]['name']}: {r['line']}")
        e = {"kind": r["event"], "text": f.get("text"), "agent": (f.get("agent") or {}).get("name") if isinstance(
            f.get("agent"), dict) else None, "prio": caster.PRIORITY.get(r["event"], 2), "t": t}
        if r["event"] == "attack":
            m = re.match(r"(\w+) is under attack", f.get("text") or "")
            if m:
                e["agent"], e["alert_key"] = m.group(1).lower(), f"attack:{m.group(1).lower()}"
            else:  # the area fight the director logged last before the beat
                area = [c for c in cands if c["key"].startswith("area:") and t - 120 <= c["t"] <= t]
                e["alert_key"] = area[-1]["key"] if area else None
            s = snapshot_at(t, cands, battles)
            if s["held"]:
                s["onair"]["battle"] = e.get("alert_key") or "incoming"
            why = gate.why(e, s, t)
            if not why:
                dropped += 1
                f_ = next((x for x in s["fights"] if x["key"] == e.get("alert_key")), None)
                score = gate.scorer(t).score_fight(0, f.get("text"), bool((f_ or {}).get("agent")),
                                                   t - (f_ or {}).get("first", t))[0] if f_ else None
                print(f"   now    no beat: nothing lost near it, no key battle, threat score {score} < {gate.floor}"
                      f" (a quiet hit: a word in another line at most)")
                gate.quiet.append((t, f.get("text")))
                continue
            kept += 1
            e["why_it_matters"] = why
            print(f"   now    a beat: {why}")
        without = {k: v for k, v in f.items()}
        with_ = caster.story_facts(dict(f), e, story, gate, t)
        added = {k: with_[k] for k in with_ if k not in without}
        print("   memo   " + json.dumps(added.get("story"), ensure_ascii=False)[:900])
        for k in ("why_it_matters", "quiet_hits"):
            if k in added:
                print(f"   {k}: {added[k]}")
        if a.writer != "template":
            for label, facts in (("without", without), ("with", with_)):
                for who, line in w.exchange(e, facts, without.get("earlier_on_air") or [], first="pbp", n=2):
                    print(f"   {label:7} {caster.CASTERS[who]['name']}: {line}")
    print(f"attack beats 16:20-16:38: {kept} kept, {dropped} no longer beats")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--writer", default="template", help="template (offline) or or:MODEL / cf:MODEL / claude:MODEL")
    ap.add_argument("--story", action="store_true", help="shift07 16:20-16:38: attack beats and the story memo")
    a = ap.parse_args()
    if a.story:
        w = None
        if a.writer != "template":
            kind, _, model = a.writer.partition(":")
            w = caster.LLMWriter(kind, model or None, timeout=30)
        return story_replay(a, w)
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
