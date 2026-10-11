#!/usr/bin/env python3
"""Offline checks for the parts that cannot run against a real world yet (eng/bots shapes) and for the
read-only guard.  python3 tools/stream/selftest.py"""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

import harness  # noqa: E402
from director import Director  # noqa: E402
from live import LiveSource  # noqa: E402
from model import Model  # noqa: E402


# board.lua (eng/board) event shape: the item's kind/owner/requester/status after the change
BOARD_EVENTS = [
    {"seq": 1, "tick": 10, "by": "luna", "id": 1, "change": "posted", "title": "Gears", "kind": "request",
     "owner": None, "requested_by": "luna", "status": "open"},
    {"seq": 2, "tick": 11, "by": "astra", "id": 1, "change": "taken", "title": "Gears", "kind": "request",
     "owner": "astra", "requested_by": "luna", "status": "claimed"},
    {"seq": 3, "tick": 12, "by": "luna", "id": 2, "change": "posted", "title": "West wall", "kind": "claim",
     "owner": "luna", "requested_by": "luna", "status": "claimed"},
    {"seq": 4, "tick": 13, "by": "luna", "id": 1, "change": "note", "title": "Gears", "kind": "request",
     "owner": "astra", "requested_by": "luna", "status": "claimed", "text": "thanks"},
    {"seq": 5, "tick": 14, "by": "operator", "id": 4, "change": "done", "title": "Save build orders", "kind": "harness",
     "owner": "operator", "requested_by": "astra", "status": "done"},
]


class FakeHarness:
    """Answers like the eng/bots runtime described in docs/BOTS-API.md."""

    def __init__(self, board=False, reject_peek=False):
        self.calls = []
        self.tick = 600_000
        self.board = board
        self.reject_peek = reject_peek

    def probe(self):
        return {"harness": True, "camera": True, "cameras": True}

    def score(self):
        return {"tick": self.tick, "paused": False, "research_done": ["automation", "logistics"],
                "current_research": "steel-processing", "produced": {"iron-plate": 1200, "copper-plate": 400}}

    def extras(self):
        return {"progress": 0.4, "top_done": ["logistics", "automation"], "electric_machines": 40, "starved": 30}

    def flows(self, items):
        return {"iron-plate": [10] * 30}

    def dispatch(self, action, args=None, player=None, bot=None):
        assert action in harness.READ_ACTIONS
        self.calls.append((action, bot, player))
        if action == "profiles":
            return {"profiles": [
                {"kind": "bot", "name": "astra", "display_name": "Astra", "color": "#7c5cff", "glyph": "✦",
                 "position": {"x": 1, "y": 2}, "alive": True, "active": "mine", "last_said": {"text": "hi", "tick": 1}},
                {"kind": "bot", "name": "luna", "display_name": "Luna", "color": "#14141c", "glyph": "🌙",
                 "position": {"x": 20, "y": 2}, "alive": False, "active": False, "last_said": None},
                {"kind": "bot", "name": "stray", "display_name": "Stray", "color": "#ffffff", "glyph": "S",
                 "position": {"x": 300, "y": 2}, "alive": True, "active": False},
            ]}, self.tick
        if action == "status":
            if (args or {}).get("peek") and self.reject_peek:
                raise RuntimeError("status: unknown argument peek for status; valid: machines, since, threats")
            self.status_args = args
            return {"position": {"x": 1, "y": 2}, "alive": bot != "luna", "active": {"kind": "mine"} if bot == "astra" else False,
                    "last": {"kind": "craft", "outcome": "done", "tick": 1}, "combat": bot == "astra" and {"until_tick": 5},
                    "dead_until_tick": self.tick + 300 if bot == "luna" else None}, self.tick
        if action == "describe":
            return {"actions": {a: {} for a in ["status", "profiles", "chat"] + (["board", "board_events"] if self.board else [])}}, self.tick
        if action == "board_events":
            assert self.board, "board_events sent to a runtime that does not list it"
            evs = [e for e in BOARD_EVENTS if e["seq"] > args.get("since_seq", 0)]
            return {"events": evs, "cursor": evs[-1]["seq"] if evs else args.get("since_seq", 0)}, self.tick
        if action == "board":
            items = [{"id": 2, "kind": "claim", "title": "West wall", "owner": "luna", "requested_by": "luna",
                      "status": "claimed", "updated_tick": 3}] if args.get("kind") == "claim" else [
                     {"id": 1, "kind": "request", "title": "Gears", "owner": "astra", "requested_by": "luna", "status": "claimed"},
                     {"id": 3, "kind": "request", "title": "Steel", "owner": None, "requested_by": "astra", "status": "open"}]
            return {"items": items, "matched": len(items), "open_unowned": 1}, self.tick
        if action == "chat":
            assert args.get("peek") is True
            return {"messages": [{"seq": 5, "tick": 10, "from": "Astra", "text": "[color=1,0,0]Iron[/color] ok"}], "cursor": 5}, self.tick
        raise AssertionError(action)

    def camera(self, body):
        self.calls.append(("camera", body))
        return {"ok": True}


LUA_GLOBALS = {"game", "rcon", "helpers", "defines", "prototypes", "remote", "pairs", "ipairs", "next", "type",
               "tostring", "tonumber", "math", "string", "table", "pcall"}


def lua_globals_check():
    """With a local luac: the overlay's Lua compiles once joined to one line and reads no stray globals (a loop
    variable used after its loop reads as a nil global and fails the whole read on the server)."""
    import re, shutil, subprocess
    if not shutil.which("luac"):
        return
    for name in ("FLOW_LUA", "STREAM_LUA", "PROBE_LUA", "CAMERA_LUA", "SPACE_LUA"):
        lua = getattr(harness, name, None)
        if lua is None:
            continue
        lua = harness.one_line(lua).replace("ITEMS", "{}").replace("BODY", "'{}'")
        out = subprocess.run(["luac", "-p", "-l", "-l", "-"], input=lua, capture_output=True, text=True)
        assert out.returncode == 0, f"{name}: {out.stderr.strip()}"
        names = set(re.findall(r'[GS]ETTABUP.*_ENV "([A-Za-z_]\w*)"', out.stdout))
        assert names <= LUA_GLOBALS, f"{name} uses globals {sorted(names - LUA_GLOBALS)}"


def space_checks():
    """Space Age: platform rows, moments fire once (seeded on start), agents off Nauvis, space segments."""
    from model import platform_where
    from segments import Segments
    w = platform_where({"name": "P", "at": "nauvis->vulcanus 42%", "speed": 1.2})
    assert w["route"] == {"from": "Nauvis", "to": "Vulcanus", "pct": 42} and w["where"] == "Nauvis → Vulcanus" and w["speed_kms"] == 72, w
    assert platform_where({"name": "P", "at": "in transit"})["where"] == "in transit"

    run = {"agents": {"astra": {}, "opus": {}}, "space_age": True}
    m = Model(run)
    t = time.time()
    base = [{"name": "astra", "surface": "nauvis", "position": {"x": 0, "y": 0}},
            {"name": "opus", "surface": "nauvis", "position": {"x": 5, "y": 0}}]
    m.ingest({"agents": base, "space": {"rockets": 1, "planets": ["nauvis"], "platforms": []}}, t)
    assert not m.moments, "what is true at start is seeded, not announced"
    snap = m.snapshot(t)
    assert snap["space"]["active"] and snap["space"]["rockets"] == 1 and snap["space"]["summary"] == "1 rocket", snap["space"]
    plat = {"name": "Orbital One", "at": "nauvis"}
    m.ingest({"agents": base, "space": {"rockets": 2, "planets": ["nauvis"], "platforms": [plat]}}, t + 1)
    assert [x["kind"] for x in m.moments] == ["first_platform"], list(m.moments)
    away = [base[0], dict(base[1], surface="vulcanus")]
    m.ingest({"agents": away, "space": {"rockets": 2, "planets": ["nauvis", "vulcanus"],
                                        "platforms": [dict(plat, at="vulcanus")]}}, t + 2)
    kinds = [x["kind"] for x in m.moments]
    assert kinds == ["first_platform", "orbit", "landing"], kinds
    landing = m.moments[-1]
    assert landing["agent"] == "opus" and landing["facts"]["planet"] == "Vulcanus" and landing["facts"]["planets_reached"] == 2
    m.ingest({"agents": away, "space": {"rockets": 3, "planets": ["nauvis", "vulcanus"], "platforms": [dict(plat, at="vulcanus")]}}, t + 3)
    assert len(m.moments) == 3, "each moment fires once"
    snap = m.snapshot(t + 3)
    op = next(a for a in snap["agents"] if a["name"] == "opus")
    assert op["where"] == "Vulcanus" and op["location"] == "Vulcanus", op
    assert any(a["kind"] == "space" for a in snap["alerts"])

    seg = Segments(lull_after=1e9)
    seg.step(snap, t + 3)  # a fresh moment starts by itself (newest first: the landing, following the agent)
    assert seg.queue and seg.queue["type"] == "space_moment" and seg.queue["camera"] == {"follow": "opus", "zoom": seg.spotlight_zoom}, seg.queue
    assert seg.queue["facts"]["moment"] == "landing"
    seg.step(snap, t + 4)
    assert seg.cur["type"] == "space_moment"
    seg.cur["ends"] = t + 5
    seg.step(snap, t + 6)  # ended -> the next fresh moment (spacing waived)
    seg.step(snap, t + 12)
    assert seg.cur and seg.cur["facts"]["moment"] == "orbit", seg.cur
    code, reply = seg.request({"type": "space"}, t + 500, ignore_spacing=True)
    assert code == 409 and reply["error"] == "busy"
    seg.cur = None
    code, reply = seg.request({"type": "space"}, t + 500)
    assert code == 200 and reply["facts"]["planets"] == ["Nauvis", "Vulcanus"] and reply["facts"]["rockets"] == 3, reply
    assert Segments().why_unavailable("space", {"space": {"active": False}}) == "no Space Age progress yet"

    # live: the `platforms` read goes out with peek, per platform, and merges into the score's rows
    class PlatHarness(FakeHarness):
        def dispatch(self, action, args=None, player=None, bot=None):
            if action == "platforms":
                assert args.get("peek") is True and args["platform"] == "Orbital One"
                self.calls.append(("platforms", args))
                return {"platforms": [{"name": "Orbital One", "state": "on_the_path", "at": "nauvis->vulcanus 10%", "speed": 1.5}]}, 1
            return super().dispatch(action, args, player, bot)
    ph = PlatHarness()
    ls = LiveSource("test", {"agents": {"astra": {}}}, harness=ph)
    sp = {"platforms": [{"name": "Orbital One", "at": "in transit"}]}
    errs = {}
    ls.observe_platforms(sp, errs)
    assert not errs and sp["platforms"][0]["speed"] == 1.5 and sp["platforms"][0]["at"].startswith("nauvis->"), (errs, sp)
    sp2 = {"platforms": [{"name": "Orbital One", "at": "in transit"}]}
    ls.observe_platforms(sp2, errs)  # within platform_every: no new read, last detail reused
    assert len([c for c in ph.calls if c[0] == "platforms"]) == 1 and sp2["platforms"][0]["speed"] == 1.5
    assert "platforms" in harness.READ_ACTIONS


def main():
    # read-only guard
    h = harness.Harness.__new__(harness.Harness)
    for bad in ("walk", "build", "say", "camera"):
        try:
            h.dispatch(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"{bad} was not refused")
    try:
        h.dispatch("chat", {"since": 0})
    except ValueError:
        pass
    else:
        raise AssertionError("chat without peek was not refused")

    # Lua sent through one_line() must not carry `--` comments (they would swallow the rest of the joined line)
    for name in ("FLOW_LUA", "STREAM_LUA", "PROBE_LUA", "CAMERA_LUA"):
        assert "--" not in harness.one_line(getattr(harness, name)), f"{name} has a Lua comment"
    lua_globals_check()

    run = {"agents": {"astra": {"model": "GPT-6 Astra", "harness": "Codex"}, "luna": {"model": "GPT-6 Luna"}}}
    fake = FakeHarness()
    src = LiveSource("test", run, harness=fake)
    assert src.use_profiles, "profiles should switch on when the camera function exists"
    obs = src.observe()
    assert not obs["errors"], obs["errors"]
    names = [a["name"] for a in obs["agents"]]
    assert names == ["astra", "luna", "stray"], names
    astra = obs["agents"][0]
    assert astra["active"] == "mine" and astra["combat"] is True and astra["display_name"] == "Astra"
    assert ("status", "astra", None) in fake.calls and ("profiles", "astra", None) in fake.calls

    m = Model(run)
    m.ingest(obs, time.time())
    snap = m.snapshot(time.time())
    by = {a["name"]: a for a in snap["agents"]}
    assert by["astra"]["activity"] == "acting" and by["astra"]["action"] == "mining"
    assert by["luna"]["activity"] == "dead" and "respawning" in by["luna"]["action"], by["luna"]
    assert by["stray"]["model"] is None  # not in the run config: shown, but no model label invented
    assert snap["research"]["progress"] == 0.4
    assert any(a["kind"] == "power" for a in snap["alerts"]), snap["alerts"]
    assert any(a["kind"] == "attack" for a in snap["alerts"]), snap["alerts"]

    # base attacks from status.alerts become alerts and pull interest toward agents near them
    ev = LiveSource.attack_events({"attacked": [
        {"chunk_centre": {"x": 16, "y": 16}, "hits": 9, "damage": 140, "last_tick": 4000, "entities": "gun-turret x2, stone-wall x5"},
        {"chunk_centre": {"x": -16, "y": -16}, "hits": 820, "damage": 0, "last_tick": 4500, "entities": "crash-site-spaceship x820"},
        {"chunk_centre": {"x": 500, "y": 16}, "hits": 1, "damage": 5, "last_tick": 10}]}, 5000)
    assert len(ev) == 1 and ev[0]["text"] == "Base under attack near (16, 16): gun turret", ev
    before = m.agents["astra"].interest
    m.ingest({"events": ev}, time.time())
    assert m.agents["astra"].interest > before + 3, "astra is 15 tiles from the attack"

    # with profiles, per-agent status is spread over rounds
    nine = {"agents": {f"b{i}": {} for i in range(9)}}
    rr = LiveSource("test", nine, harness=FakeHarness())
    rounds = [rr.status_round(list(nine["agents"]), {}) for _ in range(3)]
    assert sorted(sum(rounds, [])) == sorted(nine["agents"]) and all(len(r) == 3 for r in rounds), rounds

    # status reads peek (no team-hint consumption); a runtime that rejects the argument gets plain reads
    assert fake.status_args == {"peek": True} and src.peek_ok is True
    old = FakeHarness(reject_peek=True)
    osrc = LiveSource("test", run, harness=old)
    oobs = osrc.observe()
    assert not oobs["errors"] and osrc.peek_ok is False and old.status_args == {}, oobs["errors"]

    # board: never polled unless `describe` lists it; then events + items reach the snapshot
    assert not src.has_board and not any(c[0].startswith("board") for c in fake.calls)
    bh = FakeHarness(board=True)
    bsrc = LiveSource("test", run, harness=bh)
    bobs = bsrc.observe()
    assert not bobs["errors"], bobs["errors"]
    assert bsrc.has_board and bsrc.board_seq == 5 and len(bobs["board_events"]) == 5
    bobs2 = bsrc.observe()
    assert bobs2["board_events"] == [] and "board" not in bobs2  # cursor advanced; items refresh every 15 s
    bm = Model(run)
    bm.ingest(bobs, time.time())
    bm.ingest({"chat": [{"seq": 9, "tick": 15, "from": "server", "text": "server: harness v4: plan_save / plan_run"}]})
    b = bm.snapshot(time.time())["board"]
    assert [(e["agent"], e["verb"]) for e in b["events"]] == [("luna", "posted"), ("astra", "taken"), ("luna", "posted"),
                                                              (None, "done")], b["events"]
    assert b["open_unowned"] == 1 and b["claims"][0]["agent"] == "luna" and b["in_progress"] == 1, b
    assert len(b["changelog"]) == 1 and b["changelog"][0]["version"] == "v4" and \
        b["changelog"][0]["request"] == "Save build orders", b["changelog"]

    # losses from status.alerts.latest (runtime describe_incident lines)
    losses = LiveSource.loss_events({"latest": [
        "in (12,-40)-(20,-31) 7 destroyed: 4 stone-wall, 3 gun-turret by 5 small-biter, 1m10s-0s ago",
        "in (300,5) 1 destroyed: 1 inserter, 4m20s ago"]})
    assert len(losses) == 1 and losses[0]["text"] == "7 lost near (12, -40): 4 stone wall, 3 gun turret (by small biters)", losses
    # hit counts ("x3") and kill counts never reach the banner or the replay title (shake3: read on air as enemies)
    hits = LiveSource.attack_events({"attacked": [
        {"chunk_centre": {"x": -48, "y": 16}, "damage": 40, "last_tick": 100, "entities": "character x3"},
        {"chunk_centre": {"x": 64, "y": 0}, "damage": 9, "last_tick": 100, "entities": "gun-turret x12, stone-wall x2"}]}, 100)
    assert [h["text"] for h in hits] == ["Engineer under attack near (-48, 16)", "Base under attack near (64, 0): gun turret"], hits

    # an attack cuts the main camera straight away, even inside its dwell
    sent_s = []
    ds = Director([{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}], lambda body: sent_s.append(body) or {"ok": True}, None)
    ds.apply(ds.slots[0], {"agents": ["a"], "follow": "a", "zoom": 1.0}, "test", {}, 0.0, quiet=True)
    ds.apply(ds.slots[1], {"agents": ["b"], "follow": "b", "zoom": 1.0}, "test", {}, 0.0, quiet=True)
    assert sent_s[0]["zoom"] == round(ds.cfg["main_scale"], 2) and sent_s[1]["zoom"] == round(min(ds.cfg["max_zoom"], ds.cfg["side_scale"]), 2), sent_s
    d2 = Director([{"slot": "main", "player": 3}], lambda body: {"ok": True}, None)
    m2 = Model({"agents": {"astra": {}, "luna": {}}})
    m2.ingest({"agents": [{"name": "astra", "position": {"x": 0, "y": 0}, "active": "build"},
                          {"name": "luna", "position": {"x": 300, "y": 0}}]})
    m2.agents["astra"].interest = 20
    now = time.time()
    assert d2.step(m2.snapshot(now), now)["main"]["agents"] == ["astra"]
    m2.ingest({"events": [{"kind": "attack", "text": "Base under attack near (500, 0)", "key": "a1", "position": {"x": 500, "y": 0}}]})
    cams2 = d2.step(m2.snapshot(now + 2), now + 2)
    assert cams2["main"]["agents"] == [] and "attack" in cams2["main"], cams2  # nobody near: show the place
    assert d2.state["main"]["position"] == {"x": 500, "y": 0}
    m2.ingest({"events": [{"kind": "attack", "text": "Base under attack near (290, 0)", "key": "a2", "position": {"x": 290, "y": 0}}]})
    d2.last_attack_cut -= 60  # past attack_spacing
    cams3 = d2.step(m2.snapshot(now + 3), now + 3)
    assert cams3["main"]["agents"] == ["luna"], cams3  # luna is 10 tiles from this one: follow luna

    # zoom follows activity once it has lasted zoom_settle; a death cuts to where the agent fell, spacing or not
    sent3 = []
    d3 = Director([{"slot": "main", "player": 3}], lambda body: sent3.append(body) or {"ok": True}, None)
    d3.cfg.update(main_scale=1.0, side_scale=1.0)  # zoom-following checks below compare the unscaled config values
    m3 = Model({"agents": {"astra": {}}})
    m3.ingest({"agents": [{"name": "astra", "position": {"x": 0, "y": 0}, "active": "build"}]})
    m3.agents["astra"].interest = 10
    t = time.time()
    assert d3.step(m3.snapshot(t), t)["main"]["zoom"] == d3.cfg["zoom_build"]
    m3.ingest({"agents": [{"name": "astra", "position": {"x": 3, "y": 0}, "active": "walk"}]})
    assert d3.step(m3.snapshot(t + 2), t + 2)["main"]["zoom"] == d3.cfg["zoom_build"]  # a short walk stays close
    assert d3.step(m3.snapshot(t + 7.1), t + 7.1)["main"]["zoom"] == d3.cfg["zoom_walk"]   # a long one goes wide
    assert len(sent3) == 2 and sent3[-1]["zoom"] == d3.cfg["zoom_walk"], sent3
    d3.last_attack_cut = t + 7  # inside attack_spacing: deaths still cut
    m3.ingest({"agents": [{"name": "astra", "position": {"x": 40, "y": 5}, "alive": False}]})
    cams4 = d3.step(m3.snapshot(t + 7.5), t + 7.5)
    assert cams4["main"]["agents"] == [] and cams4["main"]["alert"] == "death" and "died" in cams4["main"]["attack"], cams4
    assert sent3[-1]["position"] == {"x": 40, "y": 5} and sent3[-1]["zoom"] == d3.cfg["death_zoom"], sent3[-1]

    # production: science per minute headline, items ranked by the stage the factory has reached
    m4 = Model({})
    m4.ingest({"tick": 0, "game_seconds": 0, "produced": {"iron-plate": 0, "automation-science-pack": 0}})
    m4.ingest({"tick": 7200, "game_seconds": 120, "produced": {"iron-plate": 600, "copper-plate": 300, "iron-ore": 900,
               "advanced-circuit": 20, "automation-science-pack": 60, "chemical-science-pack": 30}})
    sci = m4.science(time.time())
    assert sci["spm"] == 45.0 and sci["stage"] == 3 and len(sci["packs"]) == 2, sci
    names = [r["item"] for r in m4.production(time.time())]
    assert names == ["iron-plate", "copper-plate", "advanced-circuit", "iron-ore"], names  # ore is stage 0: last

    # segments: request -> starting -> live -> ended; spacing; spotlight holds main; a fight cuts it; lulls fill
    from segments import Segments
    seg = Segments(lull_after=1e9)
    sent5 = []
    d5 = Director([{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}], lambda b: sent5.append(b) or {"ok": True}, None)
    m5 = Model({"agents": {"astra": {}, "luna": {}}})
    m5.ingest({"agents": [{"name": "astra", "position": {"x": 0, "y": 0}, "active": "build"},
                          {"name": "luna", "position": {"x": 300, "y": 40}, "active": "mine"}], "tick": 0, "game_seconds": 0,
               "produced": {"iron-plate": 0}})
    m5.ingest({"tick": 7200, "game_seconds": 120, "produced": {"iron-plate": 600, "automation-science-pack": 60}})
    m5.agents["astra"].interest = 10
    t5 = time.time()
    s5 = m5.snapshot(t5)
    s5["segment"] = seg.step(s5, t5)
    assert {r["type"]: r["available"] for r in seg.types(t5)["types"]}["attack_replay"] is False
    code, rep = seg.request({"type": "nope"}, t5)
    assert code == 400, rep
    code, rep = seg.request({"type": "production", "seconds": 999, "by": "caster", "reason": "lull"}, t5)
    assert code == 200 and rep["seconds"] == 45 and rep["facts"]["science_per_min"] == 30.0, rep
    assert seg.request({"type": "research"}, t5)[0] == 409  # busy
    assert seg.step(s5, t5 + 1)["state"] == "starting" and seg.step(s5, t5 + 4)["state"] == "live"
    assert seg.camera() is None  # production leaves the cameras alone
    assert seg.step(s5, t5 + 60)["state"] == "ended" and seg.step(s5, t5 + 66) is None
    code, rep = seg.request({"type": "spotlight", "params": {"agent": "luna"}}, t5 + 70)
    assert code == 409 and rep["error"] == "busy", rep  # 180 s spacing between starts
    seg.last_start -= 200
    code, rep = seg.request({"type": "spotlight", "params": {"agent": "luna"}}, t5 + 70)
    assert code == 200 and rep["facts"]["agent"] == "Luna", rep
    seg.step(s5, t5 + 70)
    cams5 = d5.step(s5, t5 + 70, seg.camera())
    assert cams5["main"]["agents"] == ["luna"] and cams5["main"]["segment"] == "Spotlight: Luna", cams5
    assert cams5["cam2"]["agents"] == ["astra"] and sent5[-2]["follow"] == "luna", (cams5, sent5)
    m5.ingest({"agents": [{"name": "astra", "position": {"x": 0, "y": 0}, "combat": True}]})
    s6 = m5.snapshot(time.time())  # alerts expire by wall time
    assert seg.step(s6, t5 + 75)["state"] == "live"  # an alert alone does not end a segment...
    now6 = time.time()
    d5.step(s6, now6, seg.camera())
    assert d5.last_attack_cut == now6, "the director should cut main to astra's fight"
    seg.attack_cut(now6)  # ...the director's attack cut does (serve.py's ticker calls this)
    st = seg.public()
    assert st["state"] == "ended" and st["cut"] == "attack", st
    seg.last_start = -1e9
    rep = seg.request({"type": "overview"}, now6 + 5)[1]
    assert rep.get("error") == "declined", rep  # the fight is still news
    assert seg.request({"type": "overview"}, now6 + 25)[0] == 200  # 20 s after the cut it is not
    lull = Segments(lull_after=0, spacing=0)
    lull.step(s5, time.time() + 1)
    assert lull.queue and lull.queue["by"] == "director" and lull.queue["type"] == "production", lull.queue

    # recap: due every recap_every, ahead of the lull rotation, even when requests keep the lull clock from running
    rc = Segments(lull_after=1e9, spacing=180)
    t9 = rc.last_recap
    rc.last_start = t9 + 1100  # a host request 100 s before the recap is due
    rc.step(s5, t9 + 1201)
    assert rc.queue is None, "spacing still holds"
    rc.step(s5, t9 + 1281)
    assert rc.queue and rc.queue["type"] == "recap" and rc.queue["by"] == "director" and rc.queue["facts"]["minutes"] == 21, rc.queue
    rc.step(s5, t9 + 1282)
    rc.cur["ends"] = t9 + 1290
    for k in range(1290, 1600, 10):
        rc.step(s5, t9 + k)
    assert rc.cur is None or rc.cur["type"] == "recap", "no second recap within recap_every"
    assert rc.last_recap == t9 + 1281

    # replays: a death on the main camera -> save the buffer -> attack_replay segment -> replay scene -> back to stream
    import replays as rp
    rp.time.sleep = lambda s: None  # the fake OBS answers at once

    class FakeOBS:
        def __init__(self):
            self.calls, self.program, self.saved = [], "stream", 0

        def call(self, req, data=None):
            self.calls.append((req, data))
            if req == "GetSceneList":
                return {"scenes": [{"sceneName": "stream"}]}
            if req == "GetInputList":
                return {"inputs": [{"inputName": "stream overlay"}]}
            if req == "CreateSceneItem":
                return {"sceneItemId": 7}
            if req == "GetReplayBufferStatus":
                return {"outputActive": True}
            if req == "GetStats":
                return {"cpuUsage": 5, "activeFps": 60, "renderSkippedFrames": 1, "outputSkippedFrames": 0}
            if req == "SaveReplayBuffer":
                self.saved += 1
            if req == "GetLastReplayBufferReplay":
                if not self.saved:
                    raise rp.OBSError("GetLastReplayBufferReplay: 604 no replay")
                return {"savedReplayPath": f"D:\\pog\\replays\\r{self.saved}.mkv"}
            if req == "GetMediaInputStatus":
                return {"mediaDuration": 45000, "mediaState": "OBS_MEDIA_STATE_PLAYING"}
            if req == "SetCurrentProgramScene":
                self.program = data["sceneName"]
            if req == "GetCurrentProgramScene":
                return {"currentProgramSceneName": self.program}
            return {}

    fobs = FakeOBS()
    seg7 = Segments()
    rpl = rp.Replays(seg7, obs=fobs, log=lambda *a: None, start=False)
    t7 = time.time()
    s7 = m5.snapshot(t7)
    seg7.step(s7, t7)
    rpl.work(t7)
    created = [d["sceneName"] for r, d in fobs.calls if r == "CreateScene"]
    assert created == ["replay"] and ("SetInputMute", {"inputName": "replay clip", "inputMuted": True}) in fobs.calls
    assert seg7.why_unavailable("attack_replay", s7).startswith("no fresh clip")
    for k in range(10):  # main has been on luna for 10 s
        rpl.tick(s7, {"main": {"agents": ["luna"]}}, t7 + k)
    rpl.on_attack_cut({"kind": "death", "agent": "luna", "text": "Luna died"}, s7, t7 + 10)
    assert rpl.pending and rpl.pending["kind"] == "death"
    rpl.on_attack_cut({"kind": "death", "agent": "ghost", "text": "Ghost died"}, s7, t7 + 10)  # never on main: ignored
    assert rpl.pending["label"] == "Luna died"
    rpl.work(t7 + 15)  # save_at = death + 5
    assert fobs.saved == 1 and rpl.clip and rpl.clip["path"].endswith("r1.mkv"), rpl.clip
    seg7.last_attack_cut = t7 - 100  # the death cut was long enough ago that segments are not declined
    rpl.offer(t7 + 15)
    seg7.step(s7, t7 + 15)
    assert seg7.cur["type"] == "attack_replay" and seg7.cur["state"] == "starting" and seg7.cur["facts"]["event"] == "Luna died"
    seg7.step(s7, t7 + 18)
    rpl.follow_segment(t7 + 18)
    assert fobs.program == "replay" and rpl.playing, fobs.calls[-4:]
    cursor = [d for r, d in fobs.calls if r == "SetMediaInputCursor"][-1]["mediaCursor"]
    assert 45000 - 16500 <= cursor <= 45000 - 15500, cursor  # 11 s before the death, clip saved 5 s after it
    seg7.step(s7, t7 + 40)  # past its 15 s
    rpl.follow_segment(t7 + 40)
    assert fobs.program == "stream" and not rpl.playing
    fobs.program = "replay"  # left on air by hand: the watchdog brings the stream back
    rpl.follow_segment(t7 + 50)
    assert fobs.program == "stream"

    # chat lanes: conversation and confessionals talk, coordination goes to the ticker, relayed viewer lines skip both
    m9 = Model({"agents": {"astra": {}, "luna": {}}})
    m9.ingest({"chat": [
        {"seq": 1, "tick": 1, "from": "astra", "text": "Placed 4 inserters at (12,-3), moving to iron"},
        {"seq": 2, "tick": 2, "from": "luna", "text": "Wall held. Barely. Somebody send ammo!"},
        {"seq": 3, "tick": 3, "from": "astra", "text": "on it", "aloud": True},
        {"seq": 4, "tick": 4, "from": "viewer cy", "text": "you are doing great", "viewer": True},
        {"seq": 5, "tick": 5, "from": "server", "text": "server: harness v5: board"}],
        "confessions": [{"seq": 1, "tick": 6, "from": "luna", "text": "I don't trust that wall."}]})
    lanes = [(c["seq"], c["lane"]) for c in m9.snapshot(time.time())["chat"]]
    assert lanes == [(1, "log"), (2, "talk"), (3, "talk"), (4, "viewer"), (5, "log"), ("c1", "talk")], lanes
    m9.ingest({"confessions": [{"seq": 1, "tick": 6, "from": "luna", "text": "I don't trust that wall."}]})
    assert sum(1 for c in m9.chat if c.get("confess")) == 1  # confessions dedup by their own seq

    # night lift: filter created on each capture, ramps toward the darkness, settles back by day
    import nightlift as nl

    class FilterOBS:
        def __init__(self):
            self.filters, self.settings = {"stream cam1": [], "stream cam2": [], "stream cam3": []}, {}

        def call(self, req, data=None):
            if req == "GetSourceFilterKindList":
                return {"sourceFilterKinds": ["color_filter", "color_filter_v2"]}
            if req == "GetSourceFilterList":
                if data["sourceName"] not in self.filters:
                    raise rp.OBSError("GetSourceFilterList: 600 no source")
                return {"filters": [{"filterName": f} for f in self.filters[data["sourceName"]]]}
            if req == "CreateSourceFilter":
                assert data["filterKind"] == "color_filter_v2"
                self.filters[data["sourceName"]].append(data["filterName"])
            if req == "SetSourceFilterSettings":
                self.settings[data["sourceName"]] = data["filterSettings"]
            return {}

    fo = FilterOBS()
    night = nl.NightLift(obs=fo, log=lambda *a: None, start=False)
    t8 = 1000.0
    night.t = t8
    night.set_darkness(0.0)
    night.work(t8)
    assert all(f == ["night lift"] for f in fo.filters.values()) and fo.settings["stream cam1"]["gamma"] == 0
    night.set_darkness(0.85)  # midnight
    night.work(t8 + 1)
    assert 0 < fo.settings["stream cam2"]["gamma"] < 0.1, fo.settings  # ramps, no jump
    for k in range(2, 40):
        night.work(t8 + k)
    assert fo.settings["stream cam3"] == nl.settings_for(1.0), fo.settings
    night.set_darkness(0.1)
    for k in range(40, 80):
        night.work(t8 + k)
    assert fo.settings["stream cam1"]["gamma"] == 0, fo.settings

    space_checks()

    log = os.path.join(os.environ.get("TMPDIR", "/tmp"), "selftest-director.jsonl")
    d = Director([{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}], src.send_camera, log)
    cams = d.step(snap)
    assert cams["main"]["agents"][0] == "astra", cams
    sent = [c for c in fake.calls if c[0] == "camera"]
    assert sent and sent[0][1]["player"] == 3 and sent[0][1]["follow"] == "astra", sent
    print("selftest ok:", json.dumps(cams))


if __name__ == "__main__":
    main()
