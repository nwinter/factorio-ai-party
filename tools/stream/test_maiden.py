#!/usr/bin/env python3
"""New ships' maiden flights on stream (viewer Foobator, d17 14:24: "please show new ships on their maiden flight on
stream"): python3 tools/stream/test_maiden.py

1. The history (chronicle_log.platform_history): each platform's newest creation (who built it, where) and its
   departures since, from the chronicle files along the run chain; a name used again for a new ship starts over, and a
   renamed ship (platform_renamed) keeps its history under the new name.
2. The moment (model.py): a platform's first platform_left after its creation is a maiden_flight moment and a space
   headline (platform, from, to, built by, game time); a later departure, a platform with an earlier one, a platform
   built before the chronicle, and a departure read more than 2 game minutes late are not; a ship renamed before it
   flew has its maiden flight under the new name; a ship built again under the same name has its own.
3. The camera (onecam.py): the departure is held maiden_hold, captioned "Swiftlet · maiden flight · Nauvis to Aquilo
   · built by Luna", a departure already on air included; with one camera too (POG_CAMS=1), where a plain departure is not shown; once per platform; a big
   loss and a segment come first, and it comes back after for what is left of it; it waits for host view (Nick's own
   view on air) and goes on air after it while within maiden_late.
4. The card and the hosts: segments.py's space_moment card (route, built by, the ship framed for flight), the
   overlay's rows, the hosts' headline call.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import cams  # noqa: E402
import chronicle_log  # noqa: E402
import model  # noqa: E402
from onecam import OneCam  # noqa: E402
from test_onecam import agent, world  # noqa: E402
from test_platformcam import plat, snap, team, main_row  # noqa: E402


def ev(kind, name, tick, eid, **kw):
    return dict({"type": "event", "kind": kind, "platform": name, "tick": tick, "id": eid, "t": 0}, **kw)


def write(run_dir, rows, parent=None):
    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, chronicle_log.NAME), "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in rows))
    if parent:
        with open(os.path.join(run_dir, "resumed-from"), "w") as f:
            f.write(parent)


def history():
    with tempfile.TemporaryDirectory() as d:
        write(os.path.join(d, "shift01"), [
            ev("platform_created", "Kestrel", 100, 1, by="astra", at="fulgora"),
            ev("platform_left", "Kestrel", 200, 2, at="fulgora", to="gleba"),
            ev("platform_left", "Wayfarer", 250, 3, at="nauvis", to="vulcanus"),   # built before the chronicle
            ev("platform_created", "Swiftlet", 300, 4, by="luna", at="nauvis")])
        write(os.path.join(d, "shift02"), [
            ev("platform_created", "Kestrel", 900, 9, by="sol", at="fulgora"),     # a new ship, the same name
            ev("platform_created", "Helios", 950, 10, by="sol", at="aquilo"),
            ev("platform_created", "Peregrine", 960, 11, by="sol", at="nauvis"),
            ev("platform_renamed", "Spindle", 970, 12, **{"from": "Peregrine"})], parent="shift01")
        path = os.path.join(d, "shift02", chronicle_log.NAME)
        assert chronicle_log.chain(path) == [path, os.path.join(d, "shift01", chronicle_log.NAME)]
        h = chronicle_log.platform_history(path)
        assert h["Kestrel"] == {"created": 900, "by": "sol", "at": "fulgora", "left": []}, h
        assert h["Swiftlet"]["by"] == "luna" and h["Swiftlet"]["left"] == [] and "Wayfarer" not in h, h
        assert "Peregrine" not in h and h["Spindle"] == {"created": 960, "by": "sol", "at": "nauvis", "left": []}, h
        return h


def moment_model(h):
    m = model.Model({"agents": {"luna": {}, "sol": {}, "astra": {}}})
    m.platform_history = {k: dict(v, left=list(v["left"])) for k, v in h.items()}
    m.ingest({"tick": 1000, "agents": [], "chronicle": {"entries": [], "events": [
        ev("platform_left", "Swiftlet", 1000, 11, at="nauvis", to="aquilo")]}}, 5000)
    ms = [x for x in m.moments if x["kind"] == "maiden_flight"]
    assert len(ms) == 1 and ms[0]["title"] == "Maiden flight of Swiftlet to Aquilo", list(m.moments)
    assert ms[0]["facts"] == {"platform": "Swiftlet", "from": "Nauvis", "to": "Aquilo", "built_by": "Luna",
                              "game_time": model.fmt_game_time(1000 / 60)}, ms[0]
    alert = [a for a in m.alerts if (a.get("facts") or {}).get("headline") == "maiden_flight"]
    assert alert and alert[-1]["kind"] == "space" and alert[-1]["facts"]["built_by"] == "Luna", m.alerts
    # its next departure, a ship with no creation in the chronicle, a late read: no moment
    m.ingest({"tick": 2000, "agents": [], "chronicle": {"entries": [], "events": [
        ev("platform_left", "Swiftlet", 2000, 12, at="aquilo", to="nauvis"),
        ev("platform_left", "Wayfarer", 2000, 13, at="nauvis", to="gleba")]}}, 5100)
    m.ingest({"tick": 2000 + 121 * 60, "agents": [], "chronicle": {"entries": [], "events": [
        ev("platform_left", "Helios", 2000, 14, at="aquilo", to="nauvis")]}}, 5200)
    assert [x["facts"]["platform"] for x in m.moments if x["kind"] == "maiden_flight"] == ["Swiftlet"], list(m.moments)
    assert m.platform_history["Helios"]["left"] == [2000]  # the late read still counts as its departure
    # renamed before its first departure (platform_renamed): the maiden flight under the new name
    m.ingest({"tick": 2100, "agents": [], "chronicle": {"entries": [], "events": [
        ev("platform_renamed", "Spindle II", 2050, 17, **{"from": "Spindle"}),
        ev("platform_left", "Spindle II", 2100, 18, at="nauvis", to="gleba")]}}, 5250)
    ren = [x for x in m.moments if x["kind"] == "maiden_flight" and x["facts"]["platform"] == "Spindle II"]
    assert len(ren) == 1 and ren[0]["facts"]["built_by"] == "Sol" and ren[0]["title"] == "Maiden flight of Spindle II to Gleba", ren
    # built again under the same name: a new maiden flight
    m.ingest({"tick": 9000, "agents": [], "chronicle": {"entries": [], "events": [
        ev("platform_created", "Swiftlet", 8000, 15, by="astra", at="nauvis"),
        ev("platform_left", "Swiftlet", 9000, 16, at="nauvis", to="vulcanus")]}}, 5300)
    ms = [x for x in m.moments if x["kind"] == "maiden_flight"]
    assert len(ms) == 3 and ms[-1]["facts"]["built_by"] == "Astra" and ms[-1]["id"] != ms[0]["id"], ms
    return ms[0]


def maiden(m, t, name="Starling"):
    return dict(m, id=f"m-maiden:{name}:1", t=t, facts=dict(m["facts"], platform=name),
                title=m["title"].replace(m["facts"]["platform"], name))


def three_cameras(m):
    d, _ = world(map_every=0, platform_every=0)
    a, t = team(), 1000
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    mo = maiden(m, t + 40)
    for k in range(40, 44):
        s = snap(a, [plat(at="nauvis->vulcanus 1%")])
        s["space"]["moments"] = [mo]
        d.step(s, t + k)
    row = main_row(d, t + 43)
    assert row["platform"]["label"] == "Starling · maiden flight · Nauvis to Aquilo · built by Luna", row
    assert row["platform"]["why"] == "departure" and d.platforms[-1][1:] == ("Starling", "departure"), d.platforms
    end = None
    for k in range(44, 170):
        s = snap(a, [plat(at=f"nauvis->vulcanus {min(99, k - 40)}%")])
        s["space"]["moments"] = [mo]   # the same moment again: once per platform
        d.step(s, t + k)
        if not main_row(d, t + k).get("platform"):
            end = k
            break
    assert end is not None and 40 + d.cfg["maiden_hold"] <= end <= 40 + d.cfg["maiden_hold"] + 4, (end, d.cuts)
    assert len([p for p in d.platforms if p[2] == "departure"]) == 1, d.platforms
    # the departure on air first, the chronicle's event a few seconds later: the shot becomes the maiden flight
    d, _ = world(map_every=0, platform_every=0)
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    for k in range(40, 48):
        d.step(snap(a, [plat(at="nauvis->vulcanus 1%")]), t + k)
    assert main_row(d, t + 47)["platform"]["label"].startswith("Starling · leaving Nauvis"), main_row(d, t + 47)
    s = snap(a, [plat(at="nauvis->vulcanus 2%")])
    s["space"]["moments"] = [maiden(m, t + 48)]
    d.step(s, t + 48)
    row = main_row(d, t + 48)
    assert row["platform"]["maiden"] and row["platform"]["label"].startswith("Starling · maiden flight"), row
    assert d.state[d.onair]["until"] >= t + 48 + d.cfg["maiden_hold"], d.state[d.onair]


def one_camera(m):
    sent = []
    d = OneCam(cams.slots("1"), lambda b: sent.append(b) or {"ok": True}, None, map_every=0, platform_every=0)
    d.started = 0
    a, t = team(), 1000
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    for k in range(40, 50):  # a plain departure: not with one camera
        d.step(snap(a, [plat(at="nauvis->vulcanus 1%")]), t + k)
    assert not d.platforms, d.platforms
    # a maiden flight: the one client goes to the ship and stays
    p2 = plat("Swiftlet", view=dict(plat()["view"], surface="platform-2"))
    for k in range(50, 54):
        d.step(snap(a, [plat(at="nauvis->vulcanus 2%"), p2]), t + k)
    mo = maiden(m, t + 54, "Swiftlet")
    for k in range(54, 54 + 100):
        s = snap(a, [plat(at="nauvis->vulcanus 3%"), plat("Swiftlet", at="nauvis->aquilo 1%", view=p2["view"])])
        s["space"]["moments"] = [mo]
        d.step(s, t + k)
        if k >= 56:
            row = main_row(d, t + k)
            assert (row.get("platform") or {}).get("name") == "Swiftlet", (k, row, d.cuts)
    shot = [b for b in sent if b.get("surface") == "platform-2"]
    assert shot and shot[-1]["player"] == 1, sent[-3:]


def ranks(m):
    # a big loss cuts in; the maiden flight comes back for what is left of it
    d, _ = world(map_every=0, platform_every=0)
    a, t = team(), 1000
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    mo = maiden(m, t + 40)
    for k in range(40, 50):
        s = snap(a, [plat(at="nauvis->vulcanus 2%")])
        s["space"]["moments"] = [mo]
        d.step(s, t + k)
    assert (main_row(d, t + 49).get("platform") or {}).get("maiden"), main_row(d, t + 49)
    loss = {"id": "l1", "kind": "loss", "t": t + 50, "text": "26 lost near (-128, 38): 14 transport belt, 7 inserter",
            "position": {"x": -128, "y": 38, "extent": 20}, "key": "loss:-128,38"}
    for k in range(50, 54):
        d.step(snap(a, [plat(at="nauvis->vulcanus 3%")], alerts=[loss] if k == 50 else []), t + k)
    assert main_row(d, t + 53).get("attack") and not main_row(d, t + 53).get("platform"), main_row(d, t + 53)
    back = None
    for k in range(54, 160):
        d.step(snap(a, [plat(at=f"nauvis->vulcanus {k - 40}%")]), t + k)
        row = main_row(d, t + k)
        if back is None and row.get("platform"):
            back = k
            assert row["platform"]["maiden"] and "maiden flight" in row["platform"]["label"], row
        if back is not None and not row.get("platform"):
            break
    assert back is not None and k <= 40 + 1.5 + d.cfg["maiden_hold"] + 4, (back, k, d.cuts)
    # a segment on air first (its own card): the maiden flight waits for it
    d, _ = world(map_every=0, platform_every=0)
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    seg = {"id": "s1", "label": "Maiden flight of Starling to Aquilo", "until": t + 60, "zoom": 0.5,
           "position": {"x": 0, "y": 1}, "surface": "platform-1"}
    for k in range(40, 58):
        s = snap(a, [plat(at="nauvis->vulcanus 2%")])
        s["space"]["moments"] = [mo]
        d.step(s, t + k, segment=seg)
        assert main_row(d, t + k).get("segment") or k < 42, (k, main_row(d, t + k))
    for k in range(58, 70):
        d.step(snap(a, [plat(at="nauvis->vulcanus 3%")]), t + k)
    assert (main_row(d, t + 69).get("platform") or {}).get("maiden"), main_row(d, t + 69)


def host_view(m):
    # Nick's own view on air (hostview.py): the maiden flight waits, then goes on air while still within maiden_late
    d, _ = world(map_every=0, platform_every=0)
    a, t = team(), 1000
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    d.set_host({"until": t + 70, "caption": "the new smelting column", "label": "NickWinter (host)", "by": "nick"}, t + 40)
    mo = maiden(m, t + 40)
    for k in range(40, 70):
        s = snap(a, [plat(at=f"nauvis->vulcanus {k - 39}%")])
        s["space"]["moments"] = [mo]
        d.step(s, t + k)
        assert not (main_row(d, t + k).get("platform") or {}).get("maiden"), (k, main_row(d, t + k))
    assert mo["id"] not in d.maiden_done
    for k in range(70, 80):
        s = snap(a, [plat(at=f"nauvis->vulcanus {k - 39}%")])
        s["space"]["moments"] = [mo]
        d.step(s, t + k)
    assert (main_row(d, t + 79).get("platform") or {}).get("maiden"), main_row(d, t + 79)
    # a host view longer than maiden_late: the moment has passed
    d, _ = world(map_every=0, platform_every=0)
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    d.set_host({"until": t + 40 + d.cfg["maiden_late"] + 10, "caption": "", "label": "NickWinter (host)", "by": "nick"}, t + 40)
    for k in range(40, int(40 + d.cfg["maiden_late"] + 20)):
        s = snap(a, [plat(at="nauvis->vulcanus 5%")])
        s["space"]["moments"] = [mo]
        d.step(s, t + k)
    assert not (main_row(d, t + k).get("platform") or {}).get("maiden") and mo["id"] in d.maiden_done, main_row(d, t + k)


def card_and_hosts(m):
    from segments import Segments
    seg = Segments(spacing=0)
    view = plat()["view"]
    s = {"agents": [], "space": {"moments": [maiden(m, 0, "Starling")], "platforms": [{"name": "Starling", "view": view}]}}
    title, facts, camera = seg.build_space_moment({}, s, 0)
    assert title == "Maiden flight of Starling to Aquilo" and facts["moment"] == "maiden_flight", (title, facts)
    assert facts["built_by"] == "Luna" and camera == model.platform_shot(view, travelling=True), camera
    js = open(os.path.join(HERE, "static", "overlay.js")).read()
    assert 'f.moment === "maiden_flight"' in js and 'factRow("Built by", f.built_by)' in js
    import caster
    e = {"kind": "space", "text": "Maiden flight of Starling to Aquilo", "facts": dict(facts, headline="maiden_flight")}
    f = caster.facts_for(e, {"agents": []})
    assert f["headline"]["built_by"] == "Luna" and "first trip since it was built" in f["how_to_call_it"], f


def main():
    h = history()
    m = moment_model(h)
    three_cameras(m)
    one_camera(m)
    ranks(m)
    host_view(m)
    card_and_hosts(m)
    print("maiden: ok (history along the run chain, a name used again starts over, a renamed ship keeps it; the first departure since a ship "
          "was built is a moment, later ones and late reads are not; held maiden_hold with its caption, also with one "
          "camera, once per platform, after a big loss and a segment; the card's route and builder, the hosts' call)")


if __name__ == "__main__":
    main()
