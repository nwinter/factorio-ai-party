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
        {"chunk_centre": {"x": 16, "y": 16}, "hits": 9, "last_tick": 4000, "entities": "gun-turret x2, stone-wall x5"},
        {"chunk_centre": {"x": 500, "y": 16}, "hits": 1, "last_tick": 10}]}, 5000)
    assert len(ev) == 1 and ev[0]["text"] == "Base under attack near (16, 16): gun-turret x2", ev
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
    assert len(losses) == 1 and losses[0]["text"] == "7 lost near (12, -40): 4 stone wall, 3 gun turret (by 5 small biter)", losses

    # an attack cuts the main camera straight away, even inside its dwell
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

    log = os.path.join(os.environ.get("TMPDIR", "/tmp"), "selftest-director.jsonl")
    d = Director([{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}], src.send_camera, log)
    cams = d.step(snap)
    assert cams["main"]["agents"][0] == "astra", cams
    sent = [c for c in fake.calls if c[0] == "camera"]
    assert sent and sent[0][1]["player"] == 3 and sent[0][1]["follow"] == "astra", sent
    print("selftest ok:", json.dumps(cams))


if __name__ == "__main__":
    main()
