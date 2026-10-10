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


class FakeHarness:
    """Answers like the eng/bots runtime described in docs/BOTS-API.md."""

    def __init__(self):
        self.calls = []
        self.tick = 600_000

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
            return {"position": {"x": 1, "y": 2}, "alive": bot != "luna", "active": {"kind": "mine"} if bot == "astra" else False,
                    "last": {"kind": "craft", "outcome": "done", "tick": 1}, "combat": bot == "astra" and {"until_tick": 5},
                    "dead_until_tick": self.tick + 300 if bot == "luna" else None}, self.tick
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

    log = os.path.join(os.environ.get("TMPDIR", "/tmp"), "selftest-director.jsonl")
    d = Director([{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}], src.send_camera, log)
    cams = d.step(snap)
    assert cams["main"]["agents"][0] == "astra", cams
    sent = [c for c in fake.calls if c[0] == "camera"]
    assert sent and sent[0][1]["player"] == 3 and sent[0][1]["follow"] == "astra", sent
    print("selftest ok:", json.dumps(cams))


if __name__ == "__main__":
    main()
