#!/usr/bin/env python3
"""Repeating research levels (d20 batch57 S4, viewer Foobator, shift48 operator inbox 18:25: "does the site have a way to
easily see the current level of ever increasing recurring research?"): python3 tools/stream/test_repeating.py

- harness.STREAM_LUA (the extras read the stream makes every 3 s) lists each infinite technology (max_level 2^32-1)
  researched at least once, or being researched: {name, level (the last level done: LuaTechnology.level - 1), next
  (LuaTechnology.level, the level the tech tree shows), researching}; one line, no comments;
- live.py passes it on as research.repeating ({} from Lua when empty becomes []);
- model.repeating_levels: label without the prototype's starting number, the highest level first, the running one
  with research progress; the snapshot's research carries it; push_live keeps it (research is published whole);
- the overlay's research card shows the first four as "Levels: Mining productivity 14 · ..." on its line under the bar;
- (d23 batch119 CB1, viewer Aurora site:4386: "The research header says Mining productivity 3, but the detailed panel
  says level 16 reached and researching 17") the snapshot's research label names an infinite technology by the level
  under way ("Mining productivity 15"), and research.lua's board event for a finished level by the level done (the read
  after the event: its level; an event newer than the read: one more; a restart's replay: no number).
World n, d20 18:50 (saved first): this read took 1.79 ms and listed 18 (mining-productivity-3 at level 14,
rocket-fuel-productivity 10 with 11 being researched); on the private copy the read took 1.8-2.6 ms against 1.3-2.0 ms
before.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "site"))
sys.path.insert(0, os.path.dirname(HERE))
import harness, model  # noqa: E402

# world n's read, d20 18:50 (a part)
ROWS = [{"name": "artillery-shell-damage-1", "level": 1, "next": 2},
        {"name": "mining-productivity-3", "level": 14, "next": 15},
        {"name": "physical-projectile-damage-7", "level": 10, "next": 11},
        {"name": "rocket-fuel-productivity", "level": 10, "next": 11, "researching": True},
        {"name": "steel-plate-productivity", "level": 4, "next": 5}]


def lua():
    src = harness.STREAM_LUA
    assert "p.max_level >= 4294967295" in src and "repeating = rep" in src and "t.level - 1" in src
    one = " ".join(l.strip() for l in src.strip().splitlines() if l.strip())
    assert "--" not in one


def levels():
    out = model.repeating_levels(ROWS, "rocket-fuel-productivity", 0.0521501)
    assert [(r["label"], r["level"]) for r in out] == [("Mining productivity", 14), ("Physical projectile damage", 10),
                                                       ("Rocket fuel productivity", 10), ("Steel plate productivity", 4),
                                                       ("Artillery shell damage", 1)], out
    rf = out[2]
    assert rf == {"name": "rocket-fuel-productivity", "label": "Rocket fuel productivity", "level": 10, "next": 11,
                  "researching": True, "progress": 0.052}, rf
    assert "researching" not in out[0] and out[0]["next"] == 15
    assert model.repeating_levels(None) == [] and model.repeating_levels([{"name": "x"}, "junk"]) == []
    assert len(model.repeating_levels([{"name": f"t-{k}", "level": k} for k in range(40)])) == model.REPEATING_MAX


def snapshot():
    m = model.Model({"agents": {"sol": {}}})
    m.ingest({"tick": 10, "agents": [], "research": {"current": "rocket-fuel-productivity", "done": [], "progress": 0.5,
                                                      "repeating": ROWS}}, now=1000)
    r = m.snapshot(1001)["research"]
    assert r["repeating"][0]["label"] == "Mining productivity" and r["repeating"][2]["progress"] == 0.5, r
    # an extras read without it (an older stream read): kept as it was
    m.ingest({"tick": 20, "agents": [], "research": {"current": "rocket-fuel-productivity", "done": [], "progress": 0.6}}, now=1002)
    assert len(m.snapshot(1003)["research"]["repeating"]) == 5
    import push_live
    pub = push_live.public_state(dict(m.snapshot(1003)))
    assert pub["research"]["repeating"][0]["level"] == 14, pub.get("research")


def header_label():
    assert model.research_label("mining-productivity-3", model.repeating_levels(ROWS)) == "Mining productivity 15"
    assert model.research_label("rocket-fuel-productivity", model.repeating_levels(ROWS)) == "Rocket fuel productivity 11"
    assert model.research_label("plastics", model.repeating_levels(ROWS)) == "Plastics"
    # an infinite technology on its first level has no row yet: the prototype's own level is the name's number
    assert model.research_label("mining-productivity-3", []) == "Mining productivity 3"
    m = model.Model({"agents": {"sol": {}}})
    m.ingest({"tick": 100, "agents": [], "research": {"current": "mining-productivity-3", "done": [], "progress": 0.4,
                                                       "repeating": ROWS}}, now=1000)
    assert m.snapshot(1001)["research"]["label"] == "Mining productivity 15"
    # a finished level (research.lua titles the board event by the prototype name): the read at tick 100 came after
    # the event at 90 (level 14 is the one done), the event at 130 is newer than the read (15 done)
    m.ingest({"board_events": [
        {"seq": 1, "tick": 90, "by": "research", "kind": "research", "title": "mining-productivity-3", "change": "done", "status": "done"},
        {"seq": 2, "tick": 130, "by": "research", "kind": "research", "title": "mining-productivity-3", "change": "done", "status": "done"},
        {"seq": 3, "tick": 131, "by": "research", "kind": "research", "title": "steel-axe", "change": "done", "status": "done"},
        {"seq": 4, "tick": 132, "by": "research", "kind": "research", "title": "railgun-damage-1", "change": "done", "status": "done"}]},
        now=1002)
    titles = [e["title"] for e in m.snapshot(1003)["board"]["events"]]
    assert titles == ["Mining productivity 14", "Mining productivity 15", "Steel axe", "Railgun damage 1"], titles
    assert model.level_done_label({"label": "Mining productivity", "level": 14}, None, 100) is None


def live_parse():
    import live
    src = open(live.__file__).read()
    assert 'obs["research"]["repeating"] = ex["repeating"] if isinstance(ex["repeating"], list) else []' in src


def overlay():
    code = open(os.path.join(HERE, "static", "overlay.js")).read()
    # (batch115) on the card's one line under the bar, after "N done · latest ...": it pans when longer than the card
    assert 'if (levels) rb.append(' in code and '"Levels: " + reps.map((x) => x.label + " " + x.level)' in code


def main():
    lua()
    levels()
    snapshot()
    header_label()
    live_parse()
    overlay()
    print("repeating research: ok (the extras read's infinite technologies, labelled and ordered by level, on the "
          "snapshot, the site state and the overlay card; the header and finished levels by level)")


if __name__ == "__main__":
    main()
