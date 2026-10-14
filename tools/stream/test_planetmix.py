#!/usr/bin/env python3
"""Host lines that mix planets (viewer Joonazan, 13:38 on 2026-10-14: "There are no biters on Gleba. There are also other
announcements that sound like they are mixing planets."; operator 14:08): python3 tools/stream/test_planetmix.py

1. Battle facts say their planet: live.py writes "Base under attack on Gleba near (x, y)" off Nauvis; model.py's alerts
   carry their surface (an agent's attack, fight and death: the agent's; an area or a loss: the event's); caster.py's
   events keep it and facts_for gives `planet` and `enemies_there` (none while Nauvis is the only planet in play).
2. No joining across planets: the battle tally is kept per surface (12:57: Nauvis's four gun turrets in "Sol is under
   attack on Gleba"); a beat folds only urgent events of its own surface (11:15: Nauvis's laser turret in Sol's).
3. The line check: an enemy named where it does not live ("Biters have found Sol on Gleba"), or a planet a battle fact
   does not give, is refused; saying an enemy is absent passes; Nauvis's biters and spitters pass.
4. The analyst: its status says which planet it covers, can be read as an agent elsewhere, and the agents' list says
   where each one is (13:11: "The team is on Nauvis, where there are no stomper nests" with Sol and Luna on Gleba).
"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "analyst"))
import caster  # noqa: E402
from live import LiveSource  # noqa: E402
from model import Model  # noqa: E402

SPACE = {"space": {"space_age": True, "planets": ["Nauvis", "Vulcanus", "Fulgora", "Gleba"], "active": True}}


def facts_have_planets():
    rows = LiveSource.attack_events({"attacked": [
        {"chunk_centre": {"x": 176, "y": 48}, "surface": "gleba", "damage": 30, "last_tick": 100, "entities": "gun-turret x3"},
        {"chunk_centre": {"x": 16, "y": 16}, "surface": "nauvis", "damage": 30, "last_tick": 100, "entities": "laser-turret x1"}]}, 100)
    assert [r["text"] for r in rows] == ["Base under attack on Gleba near (176, 48): gun turret",
                                         "Base under attack near (16, 16): laser turret"], rows
    assert caster.spoken(rows[0]["text"]) == "Base under attack on Gleba: gun turret"
    m = Model({"agents": {"sol": {}, "astra": {}}})
    m.ingest({"tick": 1000, "events": rows, "agents": [
        {"name": "sol", "alive": True, "surface": "gleba", "position": {"x": 46, "y": 51}, "active": "shoot",
         "combat": {"auto": True, "kills_10s": 0, "target": {"name": "small-wriggler-pentapod"}, "fired_tick": 990}},
        {"name": "astra", "alive": True, "position": {"x": 0, "y": 0},
         "hurt": {"tick": 990, "by": "small-biter"}}]}, now=time.time())
    al = {a["text"]: a for a in m.alerts}  # (the snapshot shows the last three)
    assert al["Base under attack on Gleba near (176, 48): gun turret"]["surface"] == "gleba"
    assert al["Base under attack near (16, 16): laser turret"]["surface"] == "nauvis"
    assert al["Sol is fighting a small wriggler pentapod"]["surface"] == "gleba"
    assert al["Astra is under attack by a small biter"]["surface"] == "nauvis", al
    # the hosts' events keep it; facts_for names the planet and who attacks there
    d = caster.Differ()
    d.diff({"agents": []})
    ev = {e["text"]: e for e in d.diff({"agents": [], "alerts": list(al.values())})}
    e = ev["Base under attack on Gleba near (176, 48): gun turret"]
    assert e["surface"] == "gleba", e
    f = caster.facts_for(e, dict(SPACE, agents=[]))
    assert f["planet"] == "Gleba" and "no biters" in f["enemies_there"], f
    assert caster.facts_for(ev["Astra is under attack by a small biter"], dict(SPACE, agents=[]))["enemies_there"] == \
        "biters, spitters and worms"
    # while Nauvis is the only planet in play, no planet (Nick 12:35, item 4)
    assert "planet" not in caster.facts_for(e, {"space": {"space_age": True, "planets": ["Nauvis"], "active": False}})
    print("facts have planets: ok")


def no_joins():
    class _A:
        stale, seed = 45, 1
    now = time.time()
    cs = caster.Caster.__new__(caster.Caster)
    cs.a, cs.events = _A(), caster.deque(maxlen=60)
    # a Nauvis raid's unspoken beats, then Sol's attack on Gleba: the tally stays Nauvis's
    cs.tally_battle({"kind": "loss", "text": "4 lost: 4 gun turret", "surface": "nauvis"})
    cs.tally_battle({"kind": "attack", "text": "Base under attack: gun turret"})  # (no surface: Nauvis)
    g = cs.take_tally({"kind": "attack", "text": "Sol is under attack", "surface": "gleba"})
    assert "since_last_report" not in g, g
    n = cs.take_tally({"kind": "loss", "text": "3 lost: 3 transport belt", "surface": "nauvis"})
    assert n["since_last_report"] == {"reports": 2, "attacks": 1, "lost": {"gun turret": 4}}, n
    assert "since_last_report" not in cs.take_tally({"kind": "attack", "text": "x", "surface": "nauvis"})  # said once
    # a beat folds urgent events of its own surface only; another planet's wait for their own beat
    for i, (k, s) in enumerate([("attack", "gleba"), ("attack", "nauvis"), ("loss", "nauvis"), ("loss", "gleba")]):
        cs.events.append({"kind": k, "text": f"{k} on {s} {i}", "surface": s, "t": now + i, "prio": caster.PRIORITY[k]})
    first = cs.pick_event(now + 5)
    assert first["text"] == "attack on nauvis 1" and first.get("also") == ["loss on nauvis 2"], first  # (the newest)
    second = cs.pick_event(now + 5)
    assert second["text"] == "attack on gleba 0" and second.get("also") == ["loss on gleba 3"], second
    assert not cs.events
    print("no joins across planets: ok")


# The before list (11:10-14:10): lines with the facts they had, plus `planet` as the facts give it now.
BAD = [("Biters have found Sol on Gleba, and they're busy stabilizing those two remote foodbanks.", "Gleba"),
       ("Biters are hitting Sol again on Gleba, right as the robot port goes in.", "Gleba"),
       ("One biter hit on Sol's base. Nothing lost. The second science build carries on.", "Gleba"),
       ("Biters are on Sol over on Gleba, right in the middle of installing that robot port.", "Gleba"),
       ("Sol's gun turret and laser turret both went down to spitters, and Sol keeps gathering anyway.", "Gleba"),
       ("Sol is under attack on Gleba. The team just lost four gun turrets and three belts.", "Nauvis"),
       ("Spitters hit the turrets on Gleba again.", "Nauvis")]
GOOD = [("Big spitters just picked off another turret, and the line out there needs a refill.", "Nauvis", {}),
        ("Big biters just took out a gun turret. Two minutes left, then shift 12 inherits that wall.", "Nauvis", {}),
        ("Sunward is leaving Nauvis for Gleba now. Back at base, one laser turret just went down.", "Nauvis",
         {"on_screen_platform": {"shown_as": "Sunward · leaving Nauvis for Gleba"}}),
        ("A wriggler pentapod just bit Sol by the egg breeders.", "Gleba", {}),
        ("Muse Spark just died on Nauvis. They'd been on row upkeep.", "Nauvis", {}),
        ("Foobator tells Grok that Fulgora has no biters.", None, {}),
        ("No stompers here on Nauvis, that's Gleba.", None, {}),
        ("Demolishers again on Vulcanus. Sonnet's turrets hold.", "Vulcanus", {})]


def line_check():
    for text, planet in BAD:
        f = {"planet": planet, "event": "attack"}
        why = caster.wrong_enemy(text.lower(), f)
        assert why, text
    for text, planet, extra in GOOD:
        f = dict({"planet": planet, "event": "attack"} if planet else {}, **extra)
        assert caster.wrong_enemy(text.lower(), f) is None, (text, caster.wrong_enemy(text.lower(), f))
    # through check_line too (the writers' gate)
    names = ["Sol", "Astra"]
    facts = {"event": "attack", "text": "Sol is under attack", "planet": "Gleba", "agent": {"name": "Sol", "where": "Gleba"},
             "planets_reached": ["Nauvis", "Gleba"]}
    assert caster.check_line("Biters are on Sol over on Gleba.", facts, names, []) == "biters do not live on Gleba"
    assert caster.check_line("Something is hitting Sol on Gleba.", facts, names, []) is None
    assert caster.check_line("Sol is under attack on Nauvis.", facts, names, []).startswith("planet not in this event's facts")
    assert "Enemies by planet" in caster.SHOW_SPACE and "numbers_mean" not in caster.SHOW_SPACE
    print("line check: ok")


def analyst():
    import mcp_server
    st = mcp_server.trim_status({"surface": "nauvis", "enemies": {"bases": 3}, "brief": False, "inv": "x"})
    assert st["covers"].startswith("Nauvis only") and st["surface"] == "nauvis" and "inv" not in st, st
    schema = mcp_server.TOOLS["game_status"][0]["schema"]
    assert "agent" in schema["properties"] and "agent" not in schema["required"], schema
    assert "game_agents" in mcp_server.TOOLS
    import game as G

    class FakeRc:
        def __init__(self):
            self.sent = []

        def command(self, cmd):
            import json
            self.sent.append(cmd)
            body = cmd[cmd.index('{"id"'):cmd.rindex("}") + 1]  # the request JSON inside the Lua string
            req = json.loads(body.replace('\\"', '"'))
            if req["action"] == "profiles":
                return json.dumps({"ok": True, "result": {"profiles": [
                    {"name": "sol", "display_name": "Sol", "surface": "gleba", "where": "Gleba", "position": {"x": 1, "y": 2}},
                    {"name": "astra", "display_name": "Astra", "surface": "nauvis"}]}})
            return json.dumps({"ok": True, "result": {"surface": "gleba" if req.get("bot") == "sol" else "nauvis", "bot": req.get("bot")}})
    g = G.LiveGame.__new__(G.LiveGame)
    g.bot, g.player, g.rc = "astra", None, FakeRc()
    assert g.status()["bot"] == "astra" and g.status("sol") == {"surface": "gleba", "bot": "sol"}
    assert g.agents() == [{"name": "sol", "display_name": "Sol", "surface": "gleba", "where": "Gleba"},
                          {"name": "astra", "display_name": "Astra", "surface": "nauvis"}], g.agents()
    src = open(os.path.join(HERE, "analyst.py")).read()
    assert "Harness status on {where} only" in src and "on {x.get('where')" in src
    print("analyst: ok")


if __name__ == "__main__":
    facts_have_planets()
    no_joins()
    line_check()
    analyst()
    print("test_planetmix: ok")
