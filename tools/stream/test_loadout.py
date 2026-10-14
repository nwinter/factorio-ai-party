#!/usr/bin/env python3
"""What agents carry, wear and build, on stream and on the site (operator 08:55, from Nick):
python3 tools/stream/test_loadout.py

1. loadout.py picks one mode per agent: combat (shooting, health falling, in a vehicle, a fight near it, the stream's
   combat flag) with the gun in hand first and its ammo; building (a build action, or the craft queue busy) with the
   queue and build x of y; carrying for 12 s every 3 min (offset per agent) with the largest stacks; else nothing.
2. model.py ingests live.py's rows (the team only), puts the mode on each agent row and the full rows under loadouts.
3. live.py reads `loadout` as the operator every 4 s once describe lists it; a failed read waits 30 s.
4. overlay.js has the strips (main and inset), drawn from the agent rows; node --check passes; css has them.
5. push_live.py publishes each agent's loadout; the agents page has a "Now" block per card and site.js fills it.
"""
import os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "site"))
import live  # noqa: E402
import loadout as L  # noqa: E402
import model  # noqa: E402


def row(name="astra", **kw):
    r = {"name": name, "alive": True, "surface": "nauvis", "health": {"now": 250, "max": 350}, "selected_gun": 2,
         "guns": [{"name": "pistol", "count": 1}, {"name": "submachine-gun", "count": 1}, False],
         "ammo": [False, {"name": "piercing-rounds-magazine", "count": 187}, False],
         "armor": {"name": "power-armor-mk2", "equipment": [{"name": "energy-shield-equipment", "count": 2},
                   {"name": "personal-laser-defense-equipment", "count": 1}], "shield": {"now": 37, "max": 150}},
         "items": [{"name": "copper-cable", "count": 1200}, {"name": "iron-plate", "count": 400}] + [
             {"name": f"item-{i}", "count": 10 - i} for i in range(8)],
         "slots": {"free": 12, "total": 90}}
    r.update(kw)
    return r


def at_carry(name, now):
    """A time when name's carrying card is up (and one when it is not)."""
    base = now - (now + L._offset(name)) % L.CARRY_EVERY
    return base + 1, base + L.CARRY_S + 5


def modes():
    lo = L.Loadouts()
    now = 10_000.0
    on, off = at_carry("astra", now)
    lo.ingest([row()], off)
    assert lo.mode("astra", off) == (None, None)
    m, p = lo.mode("astra", on)
    assert m == "carrying" and len(p["items"]) == L.ITEMS and p["items"][0]["name"] == "copper-cable" and p["slots"]["free"] == 12
    # combat: shooting; the gun in hand first with its ammo
    lo.ingest([row(shooting=True)], off)
    m, p = lo.mode("astra", off)
    assert m == "combat" and p["why"] == "shooting", p
    assert p["guns"][0] == {"name": "submachine-gun", "ammo": "piercing-rounds-magazine", "count": 187, "selected": True}, p["guns"]
    assert p["guns"][1]["name"] == "pistol" and p["guns"][1]["ammo"] is None and p["armor"]["shield"]["now"] == 37
    # health falling in the last 10 s: under fire; steady again later: not
    lo2 = L.Loadouts()
    lo2.ingest([row(health={"now": 300, "max": 350})], off - 4)
    lo2.ingest([row(health={"now": 210, "max": 350})], off)
    assert lo2.mode("astra", off)[0] == "combat" and lo2.mode("astra", off)[1]["why"] == "under fire"
    lo2.ingest([row(health={"now": 210, "max": 350})], off + 15)
    assert lo2.mode("astra", off + 15)[0] is None
    # in a vehicle
    lo.ingest([row(vehicle="tank")], off)
    assert lo.mode("astra", off)[1]["why"] == "in tank"
    # building: a build action or the craft queue
    lo.ingest([row(building={"kind": "construct", "done": 7, "total": 20})], off)
    m, p = lo.mode("astra", off)
    assert m == "building" and p["building"]["done"] == 7
    lo.ingest([row(crafting={"queue": [{"recipe": "inserter", "count": 5}], "items": 5, "progress": 0.5})], off)
    assert lo.mode("astra", off)[0] == "building"
    # dead or unknown: nothing
    lo.ingest([row(alive=False)], off)
    assert lo.mode("astra", off) == (None, None) and lo.mode("nobody", off) == (None, None)
    # snapshot: a fight within 48 tiles in the last 30 s, on the same surface; the combat flag
    lo.ingest([row(), row("sol")], off)
    agents = [{"name": "astra", "position": {"x": 0, "y": 0}, "surface": "nauvis"},
              {"name": "sol", "position": {"x": 500, "y": 0}, "surface": "nauvis", "combat": True}]
    fights = [{"position": {"x": 30, "y": 20}, "last": off - 5}, {"position": {"x": 500, "y": 0, "surface": "gleba"}, "last": off}]
    shown = lo.snapshot(agents, fights, off)
    assert shown["astra"]["mode"] == "combat" and shown["astra"]["why"] == "fight near" and shown["sol"]["mode"] == "combat"
    fights[0]["last"] = off - 60
    assert "astra" not in lo.snapshot(agents[:1], fights, off)
    fights[0]["last"] = off
    fights[0]["position"] = {"x": 100, "y": 0}
    assert "astra" not in lo.snapshot(agents[:1], fights, off)


def model_rows():
    m = model.Model({"agents": {"astra": {}, "sol": {}}})
    now = time.time()
    m.ingest({"agents": [{"name": "astra", "alive": True, "position": {"x": 0, "y": 0}, "surface": "nauvis"}],
              "loadout": [row(shooting=True), row("nick")]}, now)
    s = m.snapshot(now)
    a = next(x for x in s["agents"] if x["name"] == "astra")
    assert a["loadout"]["mode"] == "combat" and a["loadout"]["guns"][0]["count"] == 187
    assert set(s["loadouts"]) == {"astra"} and s["loadouts"]["astra"]["items"][0]["name"] == "copper-cable"  # team only


class FakeH:
    def __init__(self, fail=False):
        self.reads, self.fail = [], fail

    def operator_read(self, action, args):
        self.reads.append((action, args))
        if self.fail:
            raise RuntimeError("rcon closed")
        return {"agents": [row()], "tick": 5}, None


def live_reads():
    src = live.LiveSource.__new__(live.LiveSource)
    src.h, src.has_loadout, src.next_loadout, src.loadout_every = FakeH(), True, 0, 4.0
    obs, err = {}, {}
    src.observe_loadout(obs, err)
    assert src.h.reads == [("loadout", {"top": 8})] and obs["loadout"][0]["name"] == "astra" and not err
    obs = {}
    src.observe_loadout(obs, err)
    assert "loadout" not in obs and len(src.h.reads) == 1  # within 4 s
    src.has_loadout = False
    src.next_loadout = 0
    src.observe_loadout(obs, err)
    assert len(src.h.reads) == 1  # a runtime without it: nothing asked
    bad = live.LiveSource.__new__(live.LiveSource)
    bad.h, bad.has_loadout, bad.next_loadout, bad.loadout_every = FakeH(fail=True), True, 0, 4.0
    bad.observe_loadout({}, err)
    assert err["loadout"] == "rcon closed" and bad.next_loadout > time.time() + 25


def overlay():
    js = open(os.path.join(HERE, "static", "overlay.js")).read()
    for needle in ("function renderLoadouts(s)", "renderLoadouts(s);", 'for (const slot of ["main", "inset"])',
                   '"loadout panel lo-"', "lo-count", 'loBar("shield"', "lo-craft", "lo-items", "seg && !seg.hidden"):
        assert needle in js, needle
    css = open(os.path.join(HERE, "static", "overlay.css")).read()
    assert ".loadout.lo-main" in css and ".loadout.lo-inset" in css
    subprocess.run(["node", "--check", os.path.join(HERE, "static", "overlay.js")], check=True)


def site():
    import push_live
    st = {"now": 1, "agents": [{"name": "astra", "display_name": "Astra"}, {"name": "sol"}],
          "loadouts": {"astra": dict(row(), age_s=3.2, error=None), "sol": {"name": "sol", "alive": False}}}
    out = push_live.public_state(st)
    a, s = out["agents"]
    assert a["loadout"]["guns"][1]["name"] == "submachine-gun" and a["loadout"]["age_s"] == 3.2 and "loadout" not in s
    assert "name" not in a["loadout"] and "surface" not in a["loadout"]
    import agents as pages
    html = pages.card("astra", {f: 0 for f, _, _ in pages.CARD} | {"active": None, "fail_rate": None}, {"survival": {}, "per_shift": {},
                      "voice": {}}, lambda k: {"name": "Astra", "color": "#fff"}, lambda k, s: "", lambda x: x)
    assert '<section class="agent-now" data-agent="astra" hidden>' in html
    js = open(os.path.join(ROOT, "site", "static", "site.js")).read()
    assert ".agent-grid[data-api]" in js and "a.loadout" in js
    subprocess.run(["node", "--check", os.path.join(ROOT, "site", "static", "site.js")], check=True)


def main():
    modes()
    model_rows()
    live_reads()
    overlay()
    site()
    print("loadout: ok (combat, building and carrying modes; model rows; live reads every 4 s; overlay strips; site Now)")


if __name__ == "__main__":
    main()
