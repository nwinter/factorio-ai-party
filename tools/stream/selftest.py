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

    def __init__(self, board=False, reject_peek=False, reject_brief=False):
        self.calls = []
        self.tick = 600_000
        self.board = board
        self.reject_peek = reject_peek
        # a runtime older than peek is older than brief too
        self.reject_brief = reject_brief or reject_peek

    def probe(self):
        return {"harness": True, "camera": True, "cameras": True}

    def score(self):
        return {"tick": self.tick, "paused": False, "research_done": ["automation", "logistics"],
                "current_research": "steel-processing", "produced": {"iron-plate": 1200, "copper-plate": 400}}

    def extras(self):
        return {"progress": 0.4, "top_done": ["logistics", "automation"], "electric_machines": 40, "starved": 30}

    def flows(self, items):
        return {"iron-plate": [10] * 30}

    def basemap(self, ore=False):
        m = {"tick": self.tick, "cell": 4, "x0": -8, "y0": -4, "w": 3, "h": 2, "rows": ["SBA", ".D"], "nests": [],
             "buildings": 5}
        if ore:
            m["ore"] = {"cell": 4, "x0": -72, "y0": -68, "w": 35, "rows": ["", "..ii"]}
        return m

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
                # shake8: a human player, disconnected, with no profile set
                {"kind": "player", "name": "NickWinter", "position": {"x": 5, "y": 5}, "alive": False, "active": False},
            ]}, self.tick
        if action == "status":
            if (args or {}).get("peek") and self.reject_peek:
                raise RuntimeError("status: unknown argument peek for status; valid: machines, since, threats")
            if (args or {}).get("brief") and self.reject_brief:
                raise RuntimeError("status: unknown argument brief for status; valid: machines, since, threats")
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
    for name in ("FLOW_LUA", "STREAM_LUA", "PROBE_LUA", "CAMERA_LUA", "SPACE_LUA", "PLATFORM_LUA"):
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
    # the New platform button: a record waiting for its starter pack, no hub yet -> not a platform (shake7, Solstice)
    m.ingest({"agents": base, "space": {"rockets": 1, "planets": ["nauvis"], "platforms": [
        {"name": "Solstice", "at": "nauvis", "hub": False}, {"name": "Dawn", "at": "nauvis", "state": "waiting_for_starter_pack"}]}}, t + 0.5)
    assert not m.moments and not m.snapshot(t + 0.5)["space"]["platforms"], list(m.moments)
    m.ingest({"agents": base, "space": {"rockets": 2, "planets": ["nauvis"], "platforms": [plat]}}, t + 1)
    # rockets 1 -> 2: the first rocket since the service started (this shift) is a moment too (eng/hostguide)
    assert [x["kind"] for x in m.moments] == ["shift_rocket", "first_platform"], list(m.moments)
    away = [base[0], dict(base[1], surface="vulcanus")]
    m.ingest({"agents": away, "space": {"rockets": 2, "planets": ["nauvis", "vulcanus"],
                                        "platforms": [dict(plat, at="vulcanus")]}}, t + 2)
    kinds = [x["kind"] for x in m.moments]
    assert kinds == ["shift_rocket", "first_platform", "orbit", "landing"], kinds
    landing = m.moments[-1]
    assert landing["agent"] == "opus" and landing["facts"]["planet"] == "Vulcanus" and landing["facts"]["planets_reached"] == 2
    m.ingest({"agents": away, "space": {"rockets": 3, "planets": ["nauvis", "vulcanus"], "platforms": [dict(plat, at="vulcanus")]}}, t + 3)
    assert len(m.moments) == 4, "each moment fires once"
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
    for name in ("FLOW_LUA", "STREAM_LUA", "PROBE_LUA", "CAMERA_LUA", "PLATFORM_LUA"):
        assert "--" not in harness.one_line(getattr(harness, name)), f"{name} has a Lua comment"
    assert "--" not in harness.one_line(harness.basemap_lua(ore=True)), "BASEMAP_LUA has a Lua comment"
    lua_globals_check()

    run = {"agents": {"astra": {"model": "GPT-6 Astra", "harness": "Codex"}, "luna": {"model": "GPT-6 Luna"}}}
    fake = FakeHarness()
    src = LiveSource("test", run, harness=fake)
    assert src.use_profiles, "profiles should switch on when the camera function exists"
    obs = src.observe()
    assert not obs["errors"], obs["errors"]
    names = [a["name"] for a in obs["agents"]]
    assert names == ["astra", "luna"], names  # the run's team only: no stray bot, no human player (shake8: Nick)
    astra = obs["agents"][0]
    assert astra["active"] == "mine" and astra["combat"] is True and astra["display_name"] == "Astra"
    assert ("status", "astra", None) in fake.calls and ("profiles", "astra", None) in fake.calls

    m = Model(run)
    m.ingest(obs, time.time())
    snap = m.snapshot(time.time())
    assert snap["basemap"]["rows"] == ["SBA", ".D"], "the base map reaches the snapshot"
    assert snap["basemap"]["ore"]["rows"][1] == "..ii", "the first base read takes the ore too"
    m.ingest({"basemap": fake.basemap()}, time.time())
    assert m.snapshot(time.time())["basemap"]["ore"], "a base read without ore keeps the last ore"
    by = {a["name"]: a for a in snap["agents"]}
    assert by["astra"]["activity"] == "acting" and by["astra"]["action"] == "mining"
    assert by["luna"]["activity"] == "dead" and "respawning" in by["luna"]["action"], by["luna"]
    assert set(by) == {"astra", "luna"}, set(by)  # ten cards in shake8; the team is two here
    # a standing order running for an agent (orders.lua, status `order`): the card says "auto: <order>"
    auto = {"name": "restock-ammo", "reason": "3 turrets below 20", "step": 2, "steps": 5}
    m.ingest({"agents": [{"name": "astra", "alive": True, "active": "walk", "auto": auto}]}, time.time())
    a2 = {a["name"]: a for a in m.snapshot(time.time())["agents"]}["astra"]
    assert a2["action"] == "auto: restock ammo" and a2["auto"]["reason"] == "3 turrets below 20", a2
    m.ingest({"agents": [{"name": "astra", "alive": True, "active": "mine", "auto": None}]}, time.time())
    assert {a["name"]: a for a in m.snapshot(time.time())["agents"]}["astra"]["action"] == "mining"
    # the model keeps out names outside the team even if a source reports them
    m.ingest({"agents": [{"name": "NickWinter", "kind": "player", "alive": False, "position": {"x": 0, "y": 0}}]}, time.time())
    assert "NickWinter" not in {a["name"] for a in m.snapshot(time.time())["agents"]}
    # a run without a team list still shows every profile
    loose = LiveSource("test", {}, harness=FakeHarness()).observe()
    assert {a["name"] for a in loose["agents"]} >= {"astra", "luna", "stray"}, [a["name"] for a in loose["agents"]]
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
    # status reads are brief with alerts (none of the factory and threat scans); older runtimes get the full status
    assert fake.status_args == {"brief": True, "alerts": True, "peek": True} and src.peek_ok is True and src.brief_ok is True
    old = FakeHarness(reject_peek=True)
    osrc = LiveSource("test", run, harness=old)
    oobs = osrc.observe()
    assert not oobs["errors"] and osrc.peek_ok is False and osrc.brief_ok is False and old.status_args == {}, oobs["errors"]
    nobrief = FakeHarness(reject_brief=True)
    nsrc = LiveSource("test", run, harness=nobrief)
    nobs = nsrc.observe()
    assert not nobs["errors"] and nsrc.peek_ok is True and nsrc.brief_ok is False and nobrief.status_args == {"peek": True}, nobs["errors"]
    assert any(a["name"] == "astra" and a.get("plan", {}).get("kind") == "mine" for a in nobs["agents"]), nobs["agents"]

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
    assert losses[0]["position"] == {"x": 16.0, "y": -35.5, "extent": 16.0, "surface": "nauvis"}, losses  # the rectangle
    # our own entities among the causes (describe_incident's "friendly fire: ..."): named as such, after any enemy
    losses = LiveSource.loss_events({"latest": [
        "in (5000,5000)-(5002,5001) 3 destroyed: 1 gun-turret, 1 pipe, 1 radar by friendly fire: 2 flamethrower-turret, 1 unknown source, 1s ago",
        "in (6000,6000) 3 destroyed: 2 transport-belt, 1 stone-wall by 2 medium-biter, friendly fire: 1 flamethrower-turret, 1s ago",
        "in (7000,7000) 1 destroyed: 1 pipe by friendly fire: 1 unknown source, 1s ago"]})
    assert [l["text"] for l in losses] == ["3 lost near (5000, 5000): 1 gun turret, 1 pipe (by friendly fire from flamethrower turrets)",
                                           "3 lost near (6000, 6000): 2 transport belt, 1 stone wall (by medium biters)",
                                           "1 lost near (7000, 7000): 1 pipe (by friendly fire)"], losses
    # eng/defensetools' numbered lines (text, from a runtime without alerts.incidents): the surface they name, a running
    # total, the flamer's position left out of the label
    losses = LiveSource.loss_events({"latest": [
        "#7 on vulcanus in (-223,74)-(-214,79) 59 destroyed: 59 gun-turret by 59 small-demolisher, 3s ago",
        "losses #8 in (12,-40) continue: 9 destroyed (+2 since you were told): 9 pipe by friendly fire: 9 flamethrower-turret at (80,90) (84,90), 1m10s-0s ago",
        "#9 on platform Starling in (3,-4) 1 destroyed: 1 gun-turret by 1 medium-metallic-asteroid, 2s ago"]})
    assert [l["text"] for l in losses] == [
        "59 lost on Vulcanus near (-223, 74): 59 gun turret (by small demolishers)",
        "9 lost near (12, -40): 9 pipe (by friendly fire from flamethrower turrets)",
        "1 lost near (3, -4): 1 gun turret (by medium metallic asteroids)"], losses
    assert losses[0]["position"] == {"x": -218.5, "y": 76.5, "extent": 16.0, "surface": "vulcanus"}, losses
    assert losses[0]["key"] == "loss:vulcanus:#7" and losses[2]["platform"] == "Starling", losses
    # status.alerts.incidents rows win over the text: 12:58 on 2026-10-13, Sol's 59 turrets on Vulcanus were cut to
    # (-223,74) on Nauvis, an empty field
    rows = {"latest": ["#7 in (-223,74) 59 destroyed: 59 gun-turret, 3s ago"], "incidents": [
        {"id": 7, "surface": "vulcanus", "box": {"x0": -223, "y0": 74, "x1": -214, "y1": 79}, "total": 59,
         "names": "59 gun-turret", "by": "59 small-demolisher", "first_tick": 9000, "last_tick": 9900},
        {"id": 8, "surface": "nauvis", "box": {"x0": 12, "y0": -40, "x1": 20, "y1": -31}, "total": 7,
         "names": "4 stone-wall, 3 gun-turret", "by": "5 small-biter", "first_tick": 9500, "last_tick": 9990},
        {"id": 9, "surface": "platform-3", "platform": "Starling", "box": {"x0": 3, "y0": -4, "x1": 3, "y1": -4}, "total": 1,
         "names": "1 gun-turret", "by": "1 medium-metallic-asteroid", "first_tick": 9990, "last_tick": 9990},
        {"id": 3, "surface": "nauvis", "box": {"x0": 0, "y0": 0, "x1": 0, "y1": 0}, "total": 2, "names": "2 pipe",
         "last_tick": 10000 - 2 * 3600}]}
    losses = LiveSource.loss_events(rows, 10000)
    assert [l["text"] for l in losses] == ["59 lost on Vulcanus near (-223, 74): 59 gun turret (by small demolishers)",
                                           "7 lost near (12, -40): 4 stone wall, 3 gun turret (by small biters)",
                                           "1 lost near (3, -4): 1 gun turret (by medium metallic asteroids)"], losses
    assert losses[0]["position"]["surface"] == "vulcanus" and losses[1]["position"] == {"x": 16.0, "y": -35.5, "extent": 16.0, "surface": "nauvis"}
    assert losses[2]["position"]["surface"] == "platform-3" and losses[2]["platform"] == "Starling", losses
    # the director frames it there: a cut to Vulcanus, not to Nauvis
    from segments import LOSS_RE as SEG_LOSS
    from onecam import minor_loss
    assert SEG_LOSS.match(losses[0]["text"]).group(1) == "59" and not minor_loss(losses[0]["text"])
    assert minor_loss("2 lost on Vulcanus near (1, 2): 2 transport belt (by small biters)")

    # hit counts ("x3") and kill counts never reach the banner or the replay title (shake3: read on air as enemies)
    hits = LiveSource.attack_events({"attacked": [
        {"chunk_centre": {"x": -48, "y": 16}, "damage": 40, "last_tick": 100, "entities": "character x3"},
        {"chunk_centre": {"x": 64, "y": 0}, "damage": 9, "last_tick": 100, "entities": "gun-turret x12, stone-wall x2"}]}, 100)
    assert [h["text"] for h in hits] == ["Engineer under attack near (-48, 16)", "Base under attack near (64, 0): gun turret"], hits
    assert hits[1]["position"] == {"x": 64, "y": 0, "extent": 32.0, "surface": "nauvis"}, hits  # the attacked chunk

    # an attack cuts the main camera straight away, even inside its dwell
    sent_s = []
    ds = Director([{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}], lambda body: sent_s.append(body) or {"ok": True}, None)
    ds.apply(ds.slots[0], {"agents": ["a"], "follow": "a", "zoom": 1.0}, "test", {}, 0.0, quiet=True)
    ds.apply(ds.slots[1], {"agents": ["b"], "follow": "b", "zoom": 1.0}, "test", {}, 0.0, quiet=True)
    assert sent_s[0]["zoom"] == round(ds.cfg["main_scale"], 2) and sent_s[1]["zoom"] == round(min(ds.cfg["max_zoom"], ds.cfg["side_scale"]), 2), sent_s
    sent2 = []
    d2 = Director([{"slot": "main", "player": 3}], lambda body: sent2.append(body) or {"ok": True}, None)
    m2 = Model({"agents": {"astra": {}, "luna": {}}})
    m2.ingest({"agents": [{"name": "astra", "position": {"x": 0, "y": 0}, "active": "build"},
                          {"name": "luna", "position": {"x": 300, "y": 0}}]})
    m2.agents["astra"].interest = 20
    now = time.time()
    assert d2.step(m2.snapshot(now), now)["main"]["agents"] == ["astra"]
    m2.ingest({"events": [{"kind": "attack", "text": "Base under attack near (500, 0)", "key": "a1",
                           "position": {"x": 500, "y": 0, "extent": 32.0, "surface": "nauvis"}}]})
    cams2 = d2.step(m2.snapshot(now + 2), now + 2)
    assert cams2["main"]["agents"] == [] and "attack" in cams2["main"], cams2  # the place of the fight
    assert (d2.state["main"]["position"]["x"], d2.state["main"]["position"]["y"]) == (500, 0)
    # the chunk in frame (32 tiles + 24 margin, ~60 across at zoom 1), sent as is, jumping there (no easing)
    assert sent2[-1]["zoom"] == round(60 / 56, 2) and sent2[-1]["smooth"] is False and sent2[-1]["surface"] == "nauvis", sent2[-1]
    assert d2.last_attack_framed == {"t": now + 2, "how": "position"}
    # shake10: a turret fight 10 tiles from an agent is still shown where it is, not by following the agent
    m2.ingest({"events": [{"kind": "attack", "text": "Base under attack near (290, 0)", "key": "a2",
                           "position": {"x": 290, "y": 0, "extent": 32.0, "surface": "nauvis"}}]})
    d2.last_attack_cut -= 60  # past attack_spacing
    cams3 = d2.step(m2.snapshot(now + 3), now + 3)
    assert cams3["main"]["agents"] == [] and d2.state["main"]["position"]["x"] == 290, cams3
    assert d2.state["main"]["until"] == now + 3 + d2.cfg["attack_hold"]  # held ~20 s
    assert d2.step(m2.snapshot(now + 15), now + 15)["main"]["agents"] == [], "still on the fight"

    # Space Age: agents pair only on the same surface; a pair's fixed view names that surface; a card says where
    sent_sa = []
    dsa = Director([{"slot": "main", "player": 3}], lambda body: sent_sa.append(body) or {"ok": True}, None)
    msa = Model({"agents": {"astra": {}, "luna": {}}})
    msa.ingest({"agents": [{"name": "astra", "position": {"x": 0, "y": 0}, "surface": "vulcanus", "where": "vulcanus", "active": "build"},
                           {"name": "luna", "position": {"x": 6, "y": 0}, "surface": "nauvis", "where": "nauvis"}]})
    msa.agents["astra"].interest = 20
    t_sa = time.time()
    assert dsa.step(msa.snapshot(t_sa), t_sa)["main"]["agents"] == ["astra"]  # 6 tiles apart, different planets
    assert sent_sa[-1]["follow"] == "astra"
    msa.ingest({"agents": [{"name": "luna", "position": {"x": 6, "y": 0}, "surface": "vulcanus", "where": "vulcanus"}]})
    assert dsa.step(msa.snapshot(t_sa + 1), t_sa + 1)["main"]["agents"] == ["astra", "luna"]
    assert sent_sa[-1]["surface"] == "vulcanus" and sent_sa[-1]["position"] == {"x": 3.0, "y": 0.0}, sent_sa[-1]
    by_sa = {a["name"]: a for a in msa.snapshot(t_sa + 1)["agents"]}
    assert by_sa["astra"]["location"] == "Vulcanus", by_sa["astra"]
    msa.ingest({"agents": [{"name": "luna", "position": {"x": 0, "y": -3}, "surface": "platform-1", "platform": "alpha",
                            "where": "platform alpha", "travel": "aboard"}]})
    luna = {a["name"]: a for a in msa.snapshot(t_sa + 2)["agents"]}["luna"]
    assert luna["location"] == "alpha" and luna["on_platform"], luna
    msa.ingest({"agents": [{"name": "luna", "position": {"x": 0, "y": -3}, "surface": "platform-1", "platform": "alpha",
                            "where": "cargo pod to vulcanus", "travel": "descending", "alive": False}]})
    luna = {a["name"]: a for a in msa.snapshot(t_sa + 3)["agents"]}["luna"]
    assert luna["location"] == "cargo pod to vulcanus" and luna["alive"], luna  # bodiless in a pod, not dead
    assert not [al for al in msa.snapshot(t_sa + 3).get("alerts") or [] if al["kind"] == "death"], "boarding is no death"
    msa.ingest({"agents": [{"name": "luna", "position": {"x": 2, "y": 2}, "surface": "vulcanus", "where": "vulcanus", "travel": None,
                            "alive": True}]})
    assert {a["name"]: a for a in msa.snapshot(t_sa + 4)["agents"]}["luna"]["travel"] is None  # landed: the ride ends

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
    rep = seg.request({"type": "production"}, t5)[1]
    assert rep.get("why") == "no item's rate moved by 25% in 10 minutes", rep  # no history: nothing worth a card
    # iron plates tripled over 10 minutes (2-minute buckets), gears steady: the card shows the mover only
    s5["production"] = [{"item": "iron-plate", "rate": 300.0, "series": [100.0] * 6 + [300.0]},
                        {"item": "iron-gear-wheel", "rate": 50.0, "series": [48.0] * 6 + [50.0]}]
    seg.snap = s5
    code, rep = seg.request({"type": "production", "seconds": 999, "by": "caster", "reason": "lull"}, t5)
    assert code == 200 and rep["seconds"] == 20 and rep["facts"]["science_per_min"] == 30.0, rep
    assert [i["item"] for i in rep["facts"]["items"]] == ["iron plate"] and rep["facts"]["items"][0]["change_pct"] == 200
    assert rep["title"] == "Production: iron plate +200% in 10 min", rep["title"]
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
    # a recap with nothing in its window is skipped and its clock restarts (it never blocks the queue)
    re0 = Segments(lull_after=1e9)
    t9 = re0.last_recap
    re0.step(s5, t9 + 1201)
    assert re0.queue is None and re0.last_recap == t9 + 1201, (re0.queue, re0.last_recap - t9)
    assert re0.request({"type": "recap"}, t9 + 1300)[1].get("why") == "nothing happened in the window"
    rc = Segments(lull_after=1e9, spacing=180)
    t9 = rc.last_recap
    rc.history.append((t9 + 1000, "death", "Astra died"))
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
    # overdue (10 minutes late, shake4's replays kept the slot): next after the running segment, others refused
    ro = Segments(lull_after=1e9, spacing=180)
    t9 = ro.last_recap
    ro.history.append((t9 + 1500, "attack", "Base under attack"))
    ro.step(s5, t9 + 1)
    rep = ro.request({"type": "overview"}, t9 + 1790, ignore_spacing=True)  # a replay-like request
    assert rep[0] == 200, rep
    ro.step(s5, t9 + 1791)
    ro.cur["ends"] = t9 + 1820
    for k in range(1792, 1830):
        ro.step(s5, t9 + k)
    assert ro.cur["type"] == "recap" and ro.cur["reason"] == "recap overdue" and ro.cur["started"] == t9 + 1821, ro.cur
    assert ro.cur["facts"]["minutes"] == 30
    ro2 = Segments(lull_after=1e9)
    ro2.step(s5, ro2.last_recap + 1)
    rep =ro2.request({"type": "overview"}, ro2.last_recap + 1810, ignore_spacing=True)[1]
    assert rep.get("why") == "an overdue recap goes next", rep

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

    # the main camera's cut to a fight makes no replay of it: viewers watched it live (test_fight_replays.py: the rest)
    rf = rp.Replays(Segments(), obs=FakeOBS(), log=lambda *a: None, start=False)
    tf = time.time()
    fight = {"kind": "attack", "agent": None, "text": "Base under attack near (290, 0): gun turret"}
    rf.on_attack_cut(fight, s7, tf, framed={"t": tf, "how": "position"})
    assert rf.pending is None, rf.pending

    # two deaths 43 s apart (shake4: Haiku, then Opus): the second cut drops the queued replay, both clips still air
    t9 = t7 + 300
    for k in range(10):
        rpl.tick(s7, {"main": {"agents": ["luna", "astra"]}}, t9 + k)
    rpl.on_attack_cut({"kind": "death", "agent": "luna", "text": "Luna died"}, s7, t9 + 10)
    rpl.work(t9 + 15)
    seg7.last_attack_cut = t9 - 100
    rpl.offer(t9 + 16)
    assert seg7.queue and seg7.queue["clip"] == rpl.clip["id"]
    for k in range(40, 53):
        rpl.tick(s7, {"main": {"agents": ["astra"]}}, t9 + k)
    seg7.attack_cut(t9 + 53)  # Astra dies: main cuts to it, the queue empties
    rpl.on_attack_cut({"kind": "death", "agent": "astra", "text": "Astra died"}, s7, t9 + 53)
    assert seg7.queue is None and rpl.clip["label"] == "Luna died" and rpl.pending["label"] == "Astra died"
    rpl.work(t9 + 58)
    assert rpl.clip["label"] == "Luna died" and [c["label"] for c in rpl.more_clips] == ["Astra died"]
    aired, when = [], []
    for k in range(58, 260):  # one tick a second: segments, then the replay worker
        seg7.step(s7, t9 + k)
        rpl.offer(t9 + k)
        rpl.follow_segment(t9 + k)
        if rpl.playing and rpl.status["last"]["label"] not in aired:
            aired.append(rpl.status["last"]["label"])
            when.append(k)
    assert aired == ["Luna died", "Astra died"] and not rpl.clip and fobs.program == "stream", aired
    assert when[1] - when[0] >= 90, when  # at least 90 s between replays (shake12: three in 41 s)

    # chat lanes: conversation and confessionals talk, coordination goes to the ticker, relayed viewer lines skip both
    m9 = Model({"agents": {"astra": {}, "luna": {}}})
    m9.ingest({"chat": [
        {"seq": 1, "tick": 1, "from": "astra", "text": "Placed 4 inserters at (12,-3), moving to iron"},
        {"seq": 2, "tick": 2, "from": "luna", "text": "Wall held. Barely. Somebody send ammo!"},
        {"seq": 3, "tick": 3, "from": "astra", "text": "on it", "aloud": True},
        {"seq": 4, "tick": 4, "from": "viewer cy", "text": "you are doing great", "viewer": True},
        {"seq": 5, "tick": 5, "from": "server", "text": "server: harness v5: board"},
        {"seq": 6, "tick": 5, "from": "vote", "text": "viewer Troll42 is muted for the rest of the run (2 of 3 active "
         "agents: astra, sol)", "notice": True}],
        "confessions": [{"seq": 1, "tick": 6, "from": "luna", "text": "I don't trust that wall."}]})
    lanes = [(c["seq"], c["lane"]) for c in m9.snapshot(time.time())["chat"]]
    assert lanes == [(1, "log"), (2, "talk"), (3, "talk"), (4, "viewer"), (5, "log"), (6, "notice"), ("c1", "talk")], lanes
    m9.ingest({"confessions": [{"seq": 1, "tick": 6, "from": "luna", "text": "I don't trust that wall."}]})
    assert sum(1 for c in m9.chat if c.get("confess")) == 1  # confessions dedup by their own seq
    # tells (agent -> teammates outside the chat): their own lane, shown in the chat feed as direct lines, once each
    tells = [{"seq": 1, "tick": 7, "from": "astra", "to": ["luna"], "text": "29 plates in the chest (3,4)"},
             {"seq": 2, "tick": 8, "from": "luna", "to": "team", "text": "north belt is down"}]
    m9.ingest({"tells": tells})
    m9.ingest({"tells": tells})
    told = [c for c in m9.chat if c.get("tell")]
    assert [(c["seq"], c["lane"], c["agent"], c["text"]) for c in told] == [
        ("t1", "tell", "astra", "→ Luna: 29 plates in the chest (3,4)"), ("t2", "tell", "luna", "→ team: north belt is down")], told
    assert [(c["to_shown"], c["body"]) for c in told] == [("Luna", "29 plates in the chest (3,4)"), ("team", "north belt is down")]
    # a burst of tells does not push the conversation out of the window, nor the conversation the tells
    m9.ingest({"tells": [{"seq": 10 + k, "tick": 9 + k, "from": "astra", "to": ["luna"], "text": f"item {k}"} for k in range(40)]})
    win = m9.chat_window()
    assert sum(1 for c in win if c["lane"] == "tell") == 24 and sum(1 for c in win if c["lane"] == "talk") >= 3, \
        [(c["seq"], c["lane"]) for c in win]

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
