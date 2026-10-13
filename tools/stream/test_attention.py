#!/usr/bin/env python3
"""Where an agent is paying attention (attention.py; Nick 2026-10-13 12:00: "It would be interesting to follow its
attention"): python3 tools/stream/test_attention.py

1. Recorded journal requests (shifts 05-06) -> attention points: kind, verb, what, centre and extent from a position,
   an area, a list of positions, entities, builds or tiles, the platform; no point without a place.
2. The journal feed (work.py) hands every such request to live.py (take_attention); its work items are as before.
3. The model: each agent's latest point with its age, the distance from its character, far or not, and a label text
   ("taking steel plate 40 m east", "at <landmark>", "on Sunward"); gone after ATTENTION_TTL.
4. The director (onecam.py): the agent on air works far from its character -> that spot in the inset, labelled
   "Sol taking steel plate 40 m east", no cut; held while it keeps at it (up to attn_max), moved to a new spot no more
   than every attn_move, ended when the story on air changes; nothing inside the on-air frame, in the first attn_min,
   within attn_gap of the last, in a fight, or for an agent off air. The hosts read onair.attention.
5. push_live: the site's map gets the point (kind, text, position, far, age), trimmed.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "site"))
import attention  # noqa: E402
from model import Model  # noqa: E402
from onecam import onair_info  # noqa: E402
from test_onecam import agent, world  # noqa: E402

# journal lines as recorded (runs/shift05-06/*/journal.jsonl; ids shortened)
RECORDED = [
    '{"at":"2026-10-13T18:04:09.206Z","event":"request","request":{"id":"3cbf","action":"inspect","bot":"luna","args":{"position":{"x":26.5,"y":-24.5}}}}',
    '{"at":"2026-10-13T18:07:41.131Z","event":"request","request":{"id":"e87a","action":"transfer","bot":"astra","args":{"position":{"x":46.5,"y":-5.5},"item":"steel-plate","count":24,"direction":"to_player"}}}',
    '{"at":"2026-10-13T18:04:56.525Z","event":"request","request":{"id":"365a","action":"transfer","bot":"luna","args":{"position":{"x":26.5,"y":-24.5},"item":"stone-wall","count":2,"direction":"assembling_machine_input"}}}',
    '{"at":"2026-10-13T18:44:24.512Z","event":"request","request":{"id":"6588","action":"place_ghosts","bot":"luna","args":{"name":"roboport","position":{"x":45,"y":52}}}}',
    '{"at":"2026-10-13T18:05:21.143Z","event":"request","request":{"id":"f4f8","action":"place_ghosts","bot":"astra","args":{"platform":"Sunward","entities":[{"name":"space-platform-foundation","position":{"x":5.5,"y":-6.5}},{"name":"space-platform-foundation","position":{"x":8.5,"y":6.5}}]}}}',
    '{"at":"2026-10-13T18:05:55.295Z","event":"request","request":{"id":"352f","action":"place_ghosts","bot":"astra","args":{"platform":"Sunward","tiles":{"name":"space-platform-foundation","area":{"left_top":{"x":-9,"y":3},"right_bottom":{"x":-4,"y":8}}}}}}',
    '{"at":"2026-10-13T18:04:06.881Z","event":"request","request":{"id":"ef82","action":"observe","bot":"astra","args":{"platform":"Sunward","area":{"left_top":{"x":-10,"y":-13},"right_bottom":{"x":11,"y":16}},"scope":"grid"}}}',
    '{"at":"2026-10-13T18:05:31.211Z","event":"request","request":{"id":"d202","action":"observe","bot":"astra","args":{"platform":"Sunward","positions":[{"x":5.5,"y":-7.5},{"x":8.5,"y":5.5},{"x":-8.5,"y":3.5}],"fields":["fluids"],"scope":"scan"}}}',
    '{"at":"2026-10-13T18:07:34.475Z","event":"request","request":{"id":"a71a","action":"build","bot":"astra","args":{"builds":[{"item":"fast-inserter","position":{"x":26.5,"y":-42.5},"direction":"west"},{"item":"fast-inserter","position":{"x":39.5,"y":-42.5},"direction":"west"},{"item":"small-electric-pole","position":{"x":25.5,"y":-40.5}},{"item":"small-electric-pole","position":{"x":39.5,"y":-40.5}}]}}}',
    '{"at":"2026-10-13T19:01:56.614Z","event":"request","request":{"id":"6200","action":"collect","bot":"gemini","args":{"positions":[{"x":-1.5,"y":59.5},{"x":-9.5,"y":59.5}],"item":"advanced-circuit"}}}',
    '{"at":"2026-10-13T18:15:52.363Z","event":"request","request":{"id":"c225","action":"configure","bot":"astra","args":{"platform":"Sunward","position":{"x":-2.5,"y":-4.5},"filters":["iron-plate"]}}}',
    '{"at":"2026-10-13T18:18:36.940Z","event":"request","request":{"id":"bc8d","action":"drop","bot":"astra","args":{"platform":"Sunward","items":[{"item":"iron-ore","count":600}]}}}',
    '{"at":"2026-10-13T18:31:04.313Z","event":"request","request":{"id":"c084","action":"launch","bot":"sol","args":{"position":{"x":14.5,"y":140.5},"platform":"Sunward"}}}',
    # no place: a scan around the character, hub requests on the character, a walk, a status read
    '{"at":"2026-10-13T18:04:08.568Z","event":"request","request":{"id":"6344","action":"observe","bot":"luna","args":{"radius":18,"group":false}}}',
    '{"at":"2026-10-13T18:06:29.670Z","event":"request","request":{"id":"da2f","action":"requests","bot":"astra","args":{"set":[{"item":"advanced-circuit","min":20,"max":20}]}}}',
    '{"at":"2026-10-13T18:05:33.278Z","event":"request","request":{"id":"916a","action":"move_to","bot":"luna","args":{"position":{"x":69,"y":-60},"combat":true}}}',
    '{"at":"2026-10-13T18:03:52.954Z","event":"request","request":{"id":"4435","action":"status","bot":"luna","args":{}}}',
]


def parse(line):
    q = json.loads(line)["request"]
    return attention.point(q["action"], q["args"])


def points():
    got = [parse(l) for l in RECORDED]
    want = [  # kind, verb, what, position, extent, platform
        ("looking", "inspecting", "", {"x": 26.5, "y": -24.5}, 0, None),
        ("moving items", "taking", "steel plate", {"x": 46.5, "y": -5.5}, 0, None),
        ("moving items", "loading", "stone wall", {"x": 26.5, "y": -24.5}, 0, None),
        ("building", "placing ghosts", "roboport", {"x": 45, "y": 52}, 0, None),
        ("building", "placing ghosts", "space platform foundation", {"x": 7.0, "y": 0.0}, 13.0, "Sunward"),
        ("building", "placing ghosts", "", {"x": -6.5, "y": 5.5}, 5.0, "Sunward"),
        ("looking", "scanning", "", {"x": 0.5, "y": 1.5}, 29.0, "Sunward"),
        ("looking", "scanning", "", {"x": 0.0, "y": -1.0}, 17.0, "Sunward"),
        ("building", "building", "", {"x": 32.5, "y": -41.5}, 14.0, None),
        ("moving items", "collecting", "advanced circuit", {"x": -5.5, "y": 59.5}, 8.0, None),
        ("configuring", "configuring", "", {"x": -2.5, "y": -4.5}, 0, "Sunward"),
        ("moving items", "dropping cargo", "", None, 0, "Sunward"),
        ("moving items", "launching a rocket", "", {"x": 14.5, "y": 140.5}, 0, "Sunward"),
        None, None, None, None,
    ]
    for g, w, line in zip(got, want, RECORDED):
        if w is None:
            assert g is None, (g, line)
            continue
        assert (g["kind"], g["verb"], g["what"], g["position"], g["extent"], g["platform"]) == w, (g, line)
        assert g["kind"] in attention.KINDS
    texts = [attention.text(g, {"x": 6.5, "y": -5.5}) if g else None for g in got]
    assert texts[1] == "taking steel plate 40 m east", texts
    assert texts[3] == "placing roboport ghosts 70 m southeast", texts
    assert texts[0] == "inspecting 30 m northeast" and texts[2] == "loading stone wall 30 m northeast", texts
    assert texts[8] == "building 45 m northeast" and texts[9] == "collecting advanced circuit 65 m south", texts
    assert texts[4] == "placing space platform foundation ghosts on Sunward", texts
    assert texts[11] == "dropping cargo from Sunward" and texts[12] == "launching a rocket to Sunward", texts
    assert attention.text(got[1], {"x": 40, "y": -5}) == "taking steel plate nearby"
    assert attention.text(got[1], {"x": 0, "y": 0}, [{"name": "the smelter row", "x": 50, "y": 0, "r": 20}]) == \
        "taking steel plate at the smelter row"
    assert attention.text(got[1]) == "taking steel plate at (46, -6)"  # (no character position)
    print("points: ok")


def feed():
    from work import WorkFeed
    root = tempfile.mkdtemp()
    for n in ("astra", "luna"):
        os.makedirs(os.path.join(root, n))
        open(os.path.join(root, n, "journal.jsonl"), "w").close()
    f = WorkFeed(root, ["astra", "luna"])
    assert f.poll() == [] and f.take_attention() == []
    with open(os.path.join(root, "luna", "journal.jsonl"), "a") as fh:
        fh.write("\n".join(RECORDED[:4] + RECORDED[13:]) + "\n")
        fh.write('{"at":"x","event":"response","response":{"id":"3cbf","ok":true,"result":{"position":{"x":1,"y":2}}}}\n')
    out = f.poll()
    assert [w["action"] for w in out] == ["place_ghosts"], out  # the work items: as before
    att = f.take_attention()
    assert [(a["agent"], a["action"]) for a in att] == [("luna", "inspect"), ("luna", "transfer"), ("luna", "transfer"),
                                                        ("luna", "place_ghosts")], att
    assert att[0]["at"] == "2026-10-13T18:04:09.206Z" and f.take_attention() == []
    print("feed: ok")


def model():
    run = {"agents": {"sol": {}, "astra": {}}, "landmarks": [{"name": "the oil field", "x": 200, "y": 0, "r": 25}]}
    m = Model(run)
    sol = {"name": "sol", "position": {"x": 6.5, "y": -5.5}, "alive": True}
    astra = {"name": "astra", "position": {"x": 0, "y": 0}, "alive": True}
    plat = {"name": "Sunward", "view": {"surface": "platform-3", "hub": {"x": 0, "y": 0}}}
    m.ingest({"agents": [sol, astra], "space": {"platforms": [plat]},
              "attention": [dict(parse(RECORDED[0]), agent="sol"), dict(parse(RECORDED[1]), agent="sol"),
                            dict(parse(RECORDED[10]), agent="astra"), dict(parse(RECORDED[2]), agent="nobody")]}, now=100)
    rows = {a["name"]: a for a in m.snapshot(110)["agents"]}
    s = rows["sol"]["attention"]
    assert s["kind"] == "moving items" and s["text"] == "taking steel plate 40 m east" and s["far"] is True, s
    assert s["dist"] == 40.0 and s["age_s"] == 10.0 and s["surface"] == "nauvis" and s["position"] == {"x": 46.5, "y": -5.5}
    a = rows["astra"]["attention"]
    assert a["platform"] == "Sunward" and a["surface"] == "platform-3" and a["far"] is True and a["dist"] is None, a
    assert a["text"] == "configuring on Sunward"
    # near the character: not far; a landmark names the spot
    m.ingest({"agents": [sol], "attention": [dict(attention.point("inspect", {"position": {"x": 10, "y": -5}}), agent="sol")]},
             now=200)
    s = next(r for r in m.snapshot(201)["agents"] if r["name"] == "sol")["attention"]
    assert s["far"] is False and s["text"] == "inspecting nearby", s
    m.ingest({"agents": [sol], "attention": [dict(attention.point("inspect", {"position": {"x": 210, "y": 5}}), agent="sol")]},
             now=300)
    s = next(r for r in m.snapshot(301)["agents"] if r["name"] == "sol")["attention"]
    assert s["far"] is True and s["text"] == "inspecting at the oil field", s
    assert next(r for r in m.snapshot(300 + 121)["agents"] if r["name"] == "sol")["attention"] is None  # old news
    print("model: ok")


def att(x, y, text="taking steel plate", age=1.0, kind="moving items", far=True, platform=None):
    return {"kind": kind, "text": text, "position": {"x": x, "y": y}, "surface": "nauvis", "extent": 0, "age_s": age,
            "far": far, "platform": platform}


def on_air(d, team, t):
    """Steps until sol (the strongest) is on air; -> the time."""
    for k in range(10):
        d.step({"agents": team, "alerts": []}, t + k)
        if (d.public(t + k).get("main") or {}).get("agents") == ["sol"]:
            return t + k
    raise AssertionError(d.public())


def director():
    d, sent = world(map_every=0, platform_every=0)
    team = [agent("sol", 0, 0, 6), agent("luna", 300, 0, 1), agent("astra", -300, 0, 1)]
    t = on_air(d, team, 1000)
    cuts = len(d.cuts)
    team[0]["attention"] = att(60, 0)
    for k in range(1, 15):  # the first attn_min of the story: nothing yet
        d.step({"agents": team, "alerts": []}, t + k)
        assert not d.inset, (k, d.inset)
    for k in range(15, 25):
        d.step({"agents": team, "alerts": []}, t + k)
        if d.inset:
            break
    t1 = t + k
    assert d.inset and d.inset["why"] == "attention" and len(d.cuts) == cuts, (d.inset, d.cuts)
    body = [b for b in sent if b.get("position") == {"x": 60, "y": 0}]
    assert body and body[-1]["smooth"] is False and body[-1]["zoom"] == 1.2, body
    d.step({"agents": team, "alerts": []}, t1 + 2)
    pub = d.public(t1 + 2)
    assert pub["main"]["agents"] == ["sol"] and pub["inset"]["agents"] == ["sol"], pub
    assert pub["inset"]["work"] == "Sol taking steel plate" and pub["inset"]["attention"]["kind"] == "moving items", pub
    info = onair_info({"agents": team}, pub)
    assert info["agent"] == "sol" and info["attention"]["text"] == "taking steel plate", info
    # keeps at that spot: held past attn_hold, up to attn_max
    for k in range(3, 60):
        team[0]["attention"] = att(62, 1, "inspecting", age=1.0, kind="looking")
        d.step({"agents": team, "alerts": []}, t1 + k)
        if not d.inset:
            break
    assert 44 <= k <= 47, k  # attn_max 45 s
    assert d.state["cam3"]["work"] == "Sol inspecting"
    assert len(d.cuts) == cuts  # never a cut
    # within attn_gap: no new inset, even for a new spot
    team[0]["attention"] = att(-60, 0)
    for k in range(k + 1, k + 40):
        d.step({"agents": team, "alerts": []}, t1 + k)
        assert not d.inset, k
    print("director: ok (inset after attn_min, held to attn_max, no cuts, attn_gap)")


def director_rules():
    # inside the on-air frame: nothing (sol at 0,0; a spot 10 tiles east shows on air already)
    d, _ = world(map_every=0, platform_every=0)
    team = [agent("sol", 0, 0, 6), agent("luna", 300, 0, 1), agent("astra", -300, 0, 1)]
    t = on_air(d, team, 1000)
    team[0]["attention"] = att(10, 0)
    for k in range(1, 60):
        d.step({"agents": team, "alerts": []}, t + k)
        assert not d.inset
    # stale (age > attn_fresh) or not far: nothing
    team[0]["attention"] = att(80, 0, age=30)
    d.step({"agents": team, "alerts": []}, t + 60)
    assert not d.inset
    # in a fight: nothing
    team[0]["attention"] = att(80, 0)
    team[0]["combat"] = True
    d.step({"agents": team, "alerts": []}, t + 61)
    assert not d.inset
    team[0]["combat"] = False
    # an agent off air: nothing
    team[0]["attention"] = None
    team[1]["attention"] = att(380, 0)
    d.step({"agents": team, "alerts": []}, t + 62)
    assert not d.inset
    # a new spot: the inset moves along, not more often than attn_move
    team[1]["attention"] = None
    team[0]["attention"] = att(80, 0)
    d.step({"agents": team, "alerts": []}, t + 63)
    assert d.inset and d.inset["position"] == {"x": 80, "y": 0}, d.inset
    team[0]["attention"] = att(0, 80, "placing ghosts", kind="building")
    d.step({"agents": team, "alerts": []}, t + 65)
    assert d.inset["position"] == {"x": 80, "y": 0}
    d.step({"agents": team, "alerts": []}, t + 72)
    assert d.inset["position"] == {"x": 0, "y": 80} and d.state[d.inset["slot"]]["work"] == "Sol placing ghosts", d.inset
    assert [a[2] for a in d.attns] == ["taking steel plate", "placing ghosts"]
    # the story on air changes: the inset ends with it
    d.cut(d.next_slot()["slot"], "test", t + 73)
    d.step({"agents": team, "alerts": []}, t + 73.5)
    assert not d.inset and d.last_attn == t + 73.5, d.inset
    # a platform: the platform's view in the inset
    d2, sent2 = world(map_every=0, platform_every=0)
    t = on_air(d2, team, 5000)
    team[0]["attention"] = dict(att(-2.5, -4.5, "configuring on Sunward", kind="configuring"), platform="Sunward",
                                surface="platform-3")
    view = {"surface": "platform-3", "hub": {"x": 0, "y": 0}, "bounds": {"left": -14, "top": -10, "right": 14, "bottom": 12}}
    for k in range(1, 30):
        d2.step({"agents": team, "alerts": [], "space": {"platforms": [{"name": "Sunward", "view": view}]}}, t + k)
        if d2.inset:
            break
    assert d2.inset and sent2[-1]["surface"] == "platform-3", sent2[-1]
    print("director rules: ok (in frame, stale, fight, off air, moves along, ends with the story, platform)")


def site():
    from push_live import public_state
    a = {"name": "sol", "attention": dict(att(46.53, -5.5), dist=40.0, extent=0, verb="taking", action="transfer")}
    out = public_state({"agents": [a]})
    assert out["agents"][0]["attention"] == {"kind": "moving items", "text": "taking steel plate", "surface": "nauvis",
                                             "age_s": 1.0, "dist": 40.0, "far": True,
                                             "position": {"x": 46.5, "y": -5.5}}, out
    print("site: ok")


if __name__ == "__main__":
    points()
    feed()
    model()
    director()
    director_rules()
    site()
