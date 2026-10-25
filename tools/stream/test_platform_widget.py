#!/usr/bin/env python3
"""The Space widget's platform cards (model.platform_card, overlay.js renderSpace): python3 tools/stream/test_platform_widget.py

Nick, 12:58: "Our on-stream space platform widget is kinda basic." Per platform: name, where or its route (bar, %),
speed or paused/drifting back, who is aboard or working on it from the ground; hub health bar, guns armed of all,
rounds in the turrets and ammo in the hub, repair packs, asteroid hits a minute, cargo highlights; a lost platform
for two minutes with its cause; under fire first; the widget holds its rotation turn while a platform is hot.
1. platform_card parses the harness's text fields (space.lua platforms, platalerts.lua defense).
2. The model: hits from status alerts' platform_hits, aboard and remote workers, ordering, lost, hot.
3. The mock arc (serve.py --mock with a Space Age run) walks through all of it.
4. The page: static checks of overlay.js, overlay.css and portrait.css, and node --check.
"""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import model  # noqa: E402
from model import Model, platform_card  # noqa: E402

KESTREL = {"name": "Kestrel", "at": "nauvis->vulcanus 48%", "state": "on_the_path", "speed": 1.0, "paused": True,
           "defense": {"hub_health": "620/1000", "turrets": "5 gun-turrets: 4 empty, 1 low (under 10 magazines: 6 (55 rounds))",
                       "ammo": "turrets hold 6 magazines (55 rounds), the hub firearm-magazine 920, piercing-rounds-magazine 40"},
           "repair_packs": "repair-pack*12 repair-pack@uncommon*3", "damaged_count": 7,
           "hub_items": "space-science-pack*340 firearm-magazine*920 iron-plate*48 repair-pack*12 copper-cable*30 +4 more"}


def main():
    # 1. parsing
    c = platform_card(KESTREL, {"hits": 31, "by": "medium-metallic-asteroid 18, small-metallic-asteroid 13"},
                      ["Astra"], ["Sol"])
    assert c["drifting"] and c["route"]["pct"] == 48 and c["where"] == "Nauvis → Vulcanus", c
    assert c["hub"] == {"hp": 620, "max": 1000, "pct": 62}, c["hub"]
    assert c["guns"] == {"total": 5, "armed": 1, "empty": 4, "low": 1}, c["guns"]
    assert c["ammo"] == {"turrets": 6, "hub": 960}, c["ammo"]
    assert c["repair"] == 15 and c["damaged"] == 7
    assert [x["item"] for x in c["cargo"]] == ["space-science-pack", "iron-plate", "copper-cable"], c["cargo"]
    assert c["hits_per_min"] == 6.2 and c["hit_by"] == "medium-metallic-asteroid 18"
    assert c["aboard"] == ["Astra"] and c["working"] == ["Sol"]
    bare = platform_card({"name": "Wren", "at": "vulcanus", "view": {"hub_health": 100}})
    assert bare["hub"] == {"pct": 100} and "guns" not in bare and "ammo" not in bare and "repair" not in bare \
        and not bare["drifting"], bare  # between platform reads: name, where, the view's hub health
    none = platform_card({"name": "Bare", "at": "nauvis", "defense": {"turrets": "none",
                                                                     "ammo": "turrets hold 0 rounds, the hub no ammo"},
                          "repair_packs": "none"})
    assert none["guns"]["total"] == 0 and none["ammo"] == {"turrets": 0, "hub": 0} and none["repair"] == 0, none
    # (d25 batch207 QT2) the unit named: magazines, rockets, ammo items; the old "rounds" text still reads
    for text, n in (("turrets hold 16 rockets, the hub rocket 40", 16), ("turrets hold 9 ammo items, the hub no ammo", 9),
                    ("turrets hold 0 magazines, the hub no ammo", 0)):
        assert platform_card({"name": "U", "at": "nauvis", "defense": {"ammo": text}})["ammo"]["turrets"] == n, text

    # 2. the model
    t = time.time()
    m = Model({"agents": {"astra": {}, "sol": {}, "luna": {}}, "space_age": True})
    calm = dict(KESTREL, name="Starling", at="vulcanus", paused=None, state="waiting_at_station")
    m.ingest({"agents": [{"name": "astra", "surface": "platform-1", "platform": "Kestrel", "position": {"x": 0, "y": 0}},
                         {"name": "sol", "surface": "nauvis", "position": {"x": 0, "y": 0}},
                         {"name": "luna", "surface": "nauvis", "position": {"x": 0, "y": 0}}],
              "space": {"rockets": 3, "planets": ["nauvis", "vulcanus"],
                        "platforms": [dict(calm, view={"surface": "platform-2"}), dict(KESTREL, view={"surface": "platform-1"})]},
              "platform_hits": [{"platform": "Kestrel", "hits": 31, "by": "medium-metallic-asteroid 31"}],
              "work": [{"agent": "sol", "platform": "Kestrel", "verb": "building", "action": "place_ghosts", "at": t}]}, t)
    sp = m.snapshot(t)["space"]
    assert [p["name"] for p in sp["platforms"]] == ["Kestrel", "Starling"], "under fire first"
    k = sp["platforms"][0]
    assert k["aboard"] == ["astra"] or k["aboard"] == ["Astra"], k.get("aboard")
    assert k["working"] in (["sol"], ["Sol"]) and k["hits_per_min"] == 6.2 and sp["hot"]
    m.ingest({"agents": [], "platform_hits": []}, t + 1)  # a status round without rows: no hits now
    sp = m.snapshot(t + 1)["space"]
    assert not any(p.get("hits_per_min") for p in sp["platforms"]) and not sp["hot"]
    # Kestrel's hub lost, then gone from two space reads: a lost row with its cause for two minutes, hot
    m.ingest({"agents": [], "events": [{"kind": "loss", "key": "loss:0,0", "ttl": 90,
                                        "text": "1 lost near (0, 0): space platform hub (by medium metallic asteroids)",
                                        "position": {"x": 0, "y": 0, "surface": "platform-1"}}]}, t + 2)
    for dt in (3, 4):
        m.ingest({"agents": [], "space": {"rockets": 3, "planets": ["nauvis"], "platforms": [calm]}}, t + dt)
    sp = m.snapshot(t + 5)["space"]
    assert [x["name"] for x in sp["lost"]] == ["Kestrel"] and sp["lost"][0]["cause"] == "medium metallic asteroids" \
        and sp["lost"][0]["where"] == "travelling from Nauvis to Vulcanus" and sp["hot"], sp["lost"]
    assert [p["name"] for p in sp["platforms"]] == ["Starling"]
    sp = m.snapshot(t + 4 + model.Model.LOST_SHOW_S + 1)["space"]
    assert not sp["lost"] and not sp["hot"], "the lost row goes after two minutes"

    # 3. the mock arc
    from mock import MockSource
    run = json.load(open(os.path.join(HERE, "runs", "mock9.json")))
    run["space_age"] = True
    src = MockSource(run)
    mm = Model(run)
    seen = {}
    for sec in range(0, 260, 2):
        src.t0 = time.time() - sec / src.sa_speed
        now = time.time()
        mm.ingest(src.observe(), now)
        s = mm.snapshot(now)["space"]
        for p in s["platforms"]:
            if p["name"] == "Shuttle" and p.get("drifting") and p.get("hits_per_min"):
                seen["drift_hits"] = p
            if p["name"] == "Orbital One" and p.get("aboard"):
                seen["aboard"] = p
        if s.get("lost"):
            seen["lost"] = s["lost"][0]
    assert seen.get("drift_hits") and seen["drift_hits"]["guns"]["armed"] == 0 and seen["drift_hits"]["repair"] == 0, seen
    assert seen.get("aboard") and seen["aboard"]["ammo"] == {"turrets": 46, "hub": 920} and \
        [c["item"] for c in seen["aboard"]["cargo"]] == ["space-science-pack", "metallic-asteroid-chunk", "iron-plate"]
    assert seen.get("lost") and seen["lost"]["name"] == "Shuttle" and seen["lost"]["cause"] == "medium metallic asteroids"

    # 4. the page
    js = open(os.path.join(STATIC, "overlay.js")).read()
    for needle in ("function platCard(p)", "function platLine2(p)", '"drifting back"', '"guns " + g.armed + "/" + g.total',
                   '"ammo " + fmtRate(p.ammo.turrets) + " · hub "', '"repair "', '"hits " + p.hits_per_min + "/min"',
                   'el("span", "plost", "LOST")', 'box.dataset.hot = sp.hot', 'dataset.hot === "1"',
                   'classList.contains("portrait") ? 3 : 2'):
        assert needle in js, needle
    css = open(os.path.join(STATIC, "overlay.css")).read()
    for needle in (".plat .pl1", ".plat .pl2", ".pchip", ".pchip .hpbar", ".plat.lost", ".plat.hit", ".pchip.bad"):
        assert needle in css, needle
    assert "grid-template-columns: 150px 1fr 90px 74px" not in css  # the old one-line row is gone
    pcss = open(os.path.join(STATIC, "portrait.css")).read()
    assert "body.portrait .plat .pl1" in pcss and "body.portrait .plat .pl2" in pcss
    for page in ("index.html", "portrait.html"):
        assert 'id="space-plats"' in open(os.path.join(STATIC, page)).read(), page
    r = subprocess.run(["node", "--check", os.path.join(STATIC, "overlay.js")], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    print("platform widget: ok (parsing, hits, aboard/remote, order, lost with cause, hot, mock arc, page)")


if __name__ == "__main__":
    main()
