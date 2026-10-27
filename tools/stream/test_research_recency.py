#!/usr/bin/env python3
"""Old research is not new (d27 batch258 RR): python3 tools/stream/test_research_recency.py

Viewer Foobator, d27 04:18: "agents think 'legendary' was just unlocked, which is not true. ... might need something
like how long ago it was actually unlocked". The hosts said "Legendary quality is their newest research" (shift85
04:06:31) at game 327h; it finished at 150h54m (shift40's chronicle). model.py seeded research["recent"] with the
extras read's top_done at each start, and the hosts (latest_research), the overlay and the site called them latest.

- chronicle_log.research_finished: each technology's newest research row along the run chain;
- model.py: recent holds only technologies finished while the service runs (with t, tick, game_time, ago); top_done
  the most advanced done before it, with the chronicle's finish where known; unused_unlocks say how long ago;
- caster.py: latest_research only from recent, with how long ago; most_advanced_research_done with the game time it
  finished and how long ago, marked not new; check_line refuses a line calling one of those new; an agent's last line
  from before a restart keeps its time;
- segments.py research card, static/overlay.js and site/static/live.js: "Latest" only for this stream's.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import caster  # noqa: E402
import chronicle_log  # noqa: E402
import segments  # noqa: E402
from model import Model  # noqa: E402

SITE = os.path.join(os.path.dirname(os.path.dirname(HERE)), "site")
H = 3600 * 60  # game ticks an hour
LEGENDARY = 32597669  # shift40's chronicle: research finished: legendary-quality, 150h54m
NOW_TICK = 327 * H + 48 * 3600  # 327h48m


def write_chain(d):
    """runs/shift40 (legendary-quality, mech-armor) <- runs/shift85 (resumed from it; a research row of its own)."""
    rows = {"shift40": [{"type": "event", "id": 1, "kind": "research", "name": "legendary-quality", "tick": LEGENDARY,
                         "game_time": "150h54m", "t": 1792425576.1},
                        {"type": "event", "id": 2, "kind": "research", "name": "mech-armor", "tick": 37432467,
                         "game_time": "173h17m", "t": 1792514613.8},
                        {"type": "event", "id": 3, "kind": "rocket", "tick": 37432500}],
            "shift85": [{"type": "event", "id": 9, "kind": "research", "name": "mining-productivity-3",
                         "tick": 70798245, "game_time": "327h46m", "level": 3}]}
    for run, evs in rows.items():
        os.makedirs(os.path.join(d, run))
        with open(os.path.join(d, run, "chronicle.jsonl"), "w") as f:
            f.write("not json\n" + "".join(json.dumps(e) + "\n" for e in evs))
    open(os.path.join(d, "shift85", "resumed-from"), "w").write("shift40\n")
    return os.path.join(d, "shift85", "chronicle.jsonl")


def model_tests(path):
    got = chronicle_log.research_finished(path)
    assert set(got) == {"legendary-quality", "mech-armor", "mining-productivity-3"}, got
    assert got["legendary-quality"] == {"tick": LEGENDARY, "game_time": "150h54m", "t": 1792425576.1}

    m = Model({"agents": {"astra": {}}})
    m.set_research_history(path)
    t = 1000.0
    top = ["legendary-quality", "mech-armor", "epic-quality"]  # epic: before the chronicle (not in these files)
    m.ingest({"tick": NOW_TICK, "research": {"current": "mining-productivity-3", "done": top + ["logistics"],
                                              "top_done": top}}, t)
    r = m.snapshot(t)["research"]
    # on main: recent was the seeded top_done with t None, and every surface called them the latest
    assert r["recent"] == [], r["recent"]
    leg, mech, epic = r["top_done"]
    assert leg["name"] == "legendary-quality" and leg["game_time"] == "150h54m" and leg["ago"] == "177 h" and \
        leg["ago_s"] == round((NOW_TICK - LEGENDARY) / 60) and "t" not in leg, leg
    assert mech["ago"] == "155 h" and epic == {"name": "epic-quality", "label": "Epic quality"}, (mech, epic)

    # a technology finishing while the service runs: latest, with how long ago, and gone from top_done
    m.ingest({"tick": NOW_TICK + 600, "research": {"current": None, "done": top + ["logistics", "quantum-processor"],
                                                    "top_done": ["quantum-processor"] + top}}, t + 10)
    m.ingest({"tick": NOW_TICK + 4200}, t + 70)
    r = m.snapshot(t + 70)["research"]
    assert [(x["name"], x["t"], x["tick"], x["ago"]) for x in r["recent"]] == [
        ("quantum-processor", t + 10, NOW_TICK + 600, "1 min")], r["recent"]
    assert [x["name"] for x in r["top_done"]] == top, r["top_done"]
    # the chronicle's row, a poll later, gives the game's own finish tick
    m.ingest({"tick": NOW_TICK + 4800, "chronicle": {"events": [
        {"id": 50, "kind": "research", "name": "quantum-processor", "tick": NOW_TICK + 300, "game_time": "327h53m"}]}},
        t + 80)
    x = m.snapshot(t + 80)["research"]["recent"][0]
    assert x["tick"] == NOW_TICK + 300 and x["ago_s"] == 75, x

    # unused_unlocks: one done before this stream says how long ago where the chronicle knows
    m.done_at.clear()
    m.research["done"] = {"logistic-robotics"}
    m.entities_counted = {"roboport"}
    m.note_research_tick("logistic-robotics", {"tick": NOW_TICK + 4800 - 3 * H})
    assert m.unused_unlocks(t + 80)[0]["researched"] == "3 h of game time ago, before this stream", m.unused_unlocks(t + 80)
    return m


def caster_tests(m):
    t = 1000.0
    s = m.snapshot(t + 80)
    f = caster.research_facts(s["research"])
    assert f["latest_research"] == [{"tech": "Quantum processor", "finished": "1 minute of game time ago"}], f
    assert f["most_advanced_research_done"] == [
        {"tech": "Legendary quality", "finished_at_game_time": "150 hours 54 minutes",
         "finished": "about 177 hours of game time ago"},
        {"tech": "Mech armor", "finished_at_game_time": "173 hours 17 minutes",
         "finished": "about 155 hours of game time ago"}], f
    assert "not new" in f["most_advanced_research_note"]
    # a fresh start: nothing latest, the seeded ones with their finish
    m2 = Model({"agents": {}})
    m2.ingest({"tick": NOW_TICK, "research": {"current": "x", "done": ["legendary-quality"], "top_done": ["legendary-quality"]}}, t)
    facts = caster.facts_for({"kind": "lull", "prio": 1}, m2.snapshot(t))
    flat = json.dumps(facts)
    assert "latest_research" not in flat and "Legendary quality" in flat and "before the run's records" in flat, facts
    assert facts["most_advanced_research_done"][0]["tech"] == "Legendary quality", facts  # a lull: research is the story
    facts = caster.facts_for({"kind": "attack", "text": "Base under attack", "prio": 9}, m2.snapshot(t))
    assert "most_advanced_research_done" in facts["background"], facts  # elsewhere a standing number
    # the lines shift85 aired are refused against these facts; a true one about the same technology is not
    for line in ("Big ask. Legendary quality is their newest research.",
                 "Sol's already sketching an all-legendary ship. Legendary quality only just came out of the labs."):
        assert caster.check_line(line, facts, [], []) == "calls old research new: legendary quality", line
    assert caster.check_line("Legendary quality has been done for ages; the modules are the bottleneck.", facts, [], []) is None
    on_card = {"on_screen_now": {"done_before_this_stream": ["Mech armor (155 h ago)"]}}
    assert caster.check_line("Mech armor, freshly researched.", on_card, [], []) == "calls old research new: mech armor"
    # the research card's facts (on air and in the hosts' on_screen_now)
    _, card, _ = build_research(s, t)
    assert card["recent"] == ["Quantum processor (1 min ago)"], card
    assert card["done_before_this_stream"] == ["Legendary quality (177 h ago)", "Mech armor (155 h ago)",
                                               "Epic quality"], card
    _, card2, _ = build_research(m2.snapshot(t), t)
    assert card2["recent"] == [] and card2["done_before_this_stream"] == ["Legendary quality"], card2


def build_research(snap, now):
    for v in vars(segments).values():
        if isinstance(v, type) and hasattr(v, "build_research"):
            return v.build_research(None, {}, snap, now)
    raise AssertionError("no build_research")


def said_tests():
    """(item 3) an agent's last line read at the first poll after a start keeps its own time by game tick."""
    m = Model({"agents": {"sol": {}}})
    now = time.time()
    m.ingest({"tick": NOW_TICK, "agents": [{"name": "sol", "last_said": {"text": "Loom is held", "tick": NOW_TICK - 2 * H}}]}, now)
    a = next(a for a in m.snapshot(now)["agents"] if a["name"] == "sol")
    assert abs(a["last_said"]["t"] - (now - 7200)) < 1, a["last_said"]
    assert caster.agent_intent({"chat": []}, a) is None  # on main: t = the read's time, so "fresh" for 10 minutes
    assert caster.agent_facts({"agents": [a]}, "sol", said=True)["last_said_when"] == "about 2 hours ago"
    # a line said while the service runs: the read's time
    m.ingest({"tick": NOW_TICK + 180, "agents": [{"name": "sol", "last_said": {"text": "Loom is free", "tick": NOW_TICK + 170}}]}, now + 3)
    a = next(a for a in m.snapshot(now + 3)["agents"] if a["name"] == "sol")
    assert a["last_said"]["t"] == now + 3 and caster.agent_intent({"chat": []}, a) == "Loom is free", a


def overlay_tests():
    """static/overlay.js: the card's line and the facts panel list only rows with a t, with how long ago."""
    js = open(os.path.join(HERE, "static", "overlay.js")).read()
    rec = re.search(r"const rec = (.*);\n", js).group(1)
    fact = re.search(r"const recent = (\(r\.recent.*);\n", js).group(1)
    r = {"recent": [{"label": "Quantum processor", "t": 5, "ago": "4 min"}],
         "top_done": [{"label": "Legendary quality", "ago": "177 h"}]}
    seeded = {"recent": [{"label": "Legendary quality", "t": None}]}  # a state from a service before this change
    code = (f"const out = []; for (const r of {json.dumps([r, seeded])}) {{ out.push([{rec}, {fact}]); }}"
            "console.log(JSON.stringify(out));")
    p = subprocess.run(["node", "-e", code], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout) == [[["Quantum processor (4 min ago)"], "Quantum processor (4 min ago)"], [[], ""]], p.stdout
    assert 'factRow("Done earlier", f.done_before_this_stream' in js and 'factRow("Latest", (f.recent' not in js


def site_tests():
    sys.path.insert(0, SITE)
    import test_research_levels
    html = test_research_levels.render({"current": "x", "label": "X", "progress": 0.5, "done_count": 246,
                                        "recent": [{"name": "quantum-processor", "label": "Quantum processor", "t": 5,
                                                    "game_time": "327h53m", "ago": "4 min"},
                                                   {"name": "old-seed", "label": "Old seed", "t": None}],
                                        "top_done": [{"name": "legendary-quality", "label": "Legendary quality",
                                                      "game_time": "150h54m", "ago": "177 h"},
                                                     {"name": "epic-quality", "label": "Epic quality"}]})
    text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html))
    latest = re.search(r'research-recent">(.*?)</ol>', html).group(1)
    assert "Quantum processor" in latest and "4 min ago, at 327h53m" in latest and "Old seed" not in html, html
    earlier = re.search(r'research-earlier">(.*?)</ul>', html).group(1)
    assert "<h4>Most advanced done</h4>" in html and "Legendary quality" in earlier and "177 h ago, at 150h54m" in earlier
    assert "Epic quality" in earlier and "Legendary quality" not in latest, text
    html = test_research_levels.render({"current": "x", "label": "X", "progress": 0.5, "done_count": 2, "recent": [],
                                        "top_done": [{"name": "legendary-quality", "label": "Legendary quality"}]})
    assert "<h4>Latest</h4>" not in html and "Legendary quality" in html


def main():
    with tempfile.TemporaryDirectory() as d:
        m = model_tests(write_chain(d))
    caster_tests(m)
    said_tests()
    if shutil.which("node"):
        overlay_tests()
        site_tests()
        js = "overlay and site"
    else:
        js = "overlay and site skipped (no node)"
    print(f"research recency: ok (only this stream's research is latest; the seeded ones by game time ago; {js})")


if __name__ == "__main__":
    main()
