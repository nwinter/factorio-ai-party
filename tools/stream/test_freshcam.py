#!/usr/bin/env python3
"""The director's repetition decay, fresh events, quiet-time base tours and remote vehicles (d26 batch222 CD, viewers
Aurora 20:09 / site:4851 / site:4876-4879 and Caleb d25): python3 tools/stream/test_freshcam.py

1. A short walk loop (Grok's ag-watch-walk, (62,18) <-> (20,30)): its score halves every loop_half, its walk gets no
   move boost, and on air it gives way to a fresh agent after still_min ("grok on a loop ...").
2. Fresh events: a new action kind scores up and fades over fresh_s; a fresh agent takes a stale story after
   still_min, a lively one only after onair_dwell at fresh_ratio; pieces placed score progress_boost.
3. Quiet time: every agent stale quiet_story -> a base tour (basetour.py from a chart folder: chart-checked points,
   a camera move) framed on a standby and cut to (one client: the client on air), held its seconds, then the best
   agent that is not stale; at 1, 2 and 3 cameras; platform visits and the base map join the rotation with a standby.
   An operator look takes the camera from a tour; host view: no tour; a fight anywhere: none.
4. A remote vehicle (work.VehicleFeed from journal replies; status active.remote for a drive): the agent's shot is a
   view on the vehicle, moved with it, labelled; a stale read goes back to the character.
5. airtime.py measures a log and journals: idle and loop share on air, time to a fresh event, cuts a minute.
"""
import atexit, json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, snap, SLOTS  # noqa: E402
from onecam import OneCam, onair_info  # noqa: E402
import airtime, basetour, work  # noqa: E402


def world(cams=3, **cfg):
    sent = []
    d = OneCam(SLOTS[:cams], lambda body: sent.append(body) or {"ok": True, "camera": {"move": bool(body.get("move"))}},
               None, **dict({"trio": False, "map_every": 0, "platform_every": 0}, **cfg))
    d.started = d.onair_since = 0
    return d, sent


def subject(d):
    t = d.state.get(d.onair) or {}
    return t.get("subject")


def scratch():
    root = tempfile.mkdtemp()
    atexit.register(shutil.rmtree, root, True)
    return root


def chart_dir():
    """A chart out/ folder: four complete cells round the origin of Nauvis, 24 machines along y = 10.5 from x = 0 to 230."""
    root = scratch()
    out = os.path.join(root, "out")
    os.makedirs(os.path.join(out, "nauvis"))
    cells = {"0,0": [1, 0, 0, 144, 0, 0, 384, 384], "-1,0": [2, 0, 0, 144, -384, 0, 0, 384],
             "0,-1": [3, 0, 0, 144, 0, -384, 384, 0], "-1,-1": [4, 0, 0, 144, -384, -384, 0, 0]}
    json.dump({"v": 1, "cell": 384, "tick": 1, "surfaces": {"nauvis": {"cells": cells, "complete": True}}},
              open(os.path.join(out, "index.json"), "w"))
    json.dump({"recipes": [[x * 10.0 + 0.5, 10.5, "iron-gear-wheel"] for x in range(24)], "stops": []},
              open(os.path.join(out, "nauvis", "0_0.labels.json"), "w"))
    return out


def looping():
    d, _ = world()
    grok = agent("grok", 62, 18, 6, active="move_to")
    sol = agent("sol", 300, 0, 1, activity="thinking", active=False)
    team = [grok, sol]
    legs = [(62, 18), (20, 30)]
    for t in range(1000, 1200):  # a 44-tile leg every 4 s; Sol thinks, standing still
        d.last_on_air["sol"] = t  # (no off-air bonus: Sol stays below the looping Grok)
        a, b = legs[(t // 4) % 2], legs[(t // 4 + 1) % 2]
        f = (t % 4) / 4
        grok["position"] = {"x": a[0] + (b[0] - a[0]) * f, "y": a[1] + (b[1] - a[1]) * f}
        d.step(snap(team), t)
    assert subject(d) == "grok", d.cuts
    assert d.loop_s("grok", 1199) >= 180, d.loop_s("grok", 1199)
    assert d.loop_s("sol", 1199) == 0
    s = d.scores(team, 1199)
    # without the loop it would score at least its interest x move_boost; on it 200 s, at most 2^-3 of that
    assert s["grok"] < 6 * d.cfg["move_boost"] / 8, s
    assert d.stale_s("grok", 1199) >= 180
    # Sol starts building: fresh; Grok on a loop gives way after still_min, Sol is not blocked by scores
    sol.update(active="build", activity="acting", interest=1)
    cut = None
    for t in range(1200, 1300):
        a, b = legs[(t // 4) % 2], legs[(t // 4 + 1) % 2]
        grok["position"] = {"x": a[0] + (b[0] - a[0]) * (t % 4) / 4, "y": a[1] + (b[1] - a[1]) * (t % 4) / 4}
        d.step(snap(team), t)
        if subject(d) == "sol":
            cut = t
            break
    assert cut is not None and cut - 1200 <= 5, (cut, d.cuts)
    assert "on a loop" in d.cuts[-1][2] and "fresh" in d.cuts[-1][2], d.cuts[-1]
    # it stops: standing still loop_end, the loop is over loop_end after that (the stand-still rule has it then)
    grok.update(position={"x": 62, "y": 18}, active=False, activity="thinking")
    for t in range(cut + 1, cut + 70):
        d.step(snap(team), t)
    assert d.loop_s("grok", cut + 69) == 0 and d.stale_s("grok", cut + 69) >= 60


def fresh_and_progress():
    d, _ = world()
    luna = agent("luna", 0, 0, 3, active="build")
    sol = agent("sol", 300, 0, 3, activity="thinking", active=False)
    team = [luna, sol]
    for t in range(1000, 1050):  # Luna builds on air; it moves a little (not stale)
        luna["position"] = {"x": (t % 10), "y": 0}
        d.step(snap(team), t)
    assert subject(d) == "luna"
    # Sol takes a new kind of action: fresh; Luna is lively, so no cut inside onair_dwell, then one at fresh_ratio
    sol.update(active="mine", activity="acting", interest=0.5)
    t0, cut = 1050, None
    for t in range(t0, t0 + 60):
        luna["position"] = {"x": (t % 10), "y": 0}
        d.step(snap(team), t)
        if subject(d) == "sol" and cut is None:
            cut = t
    assert d.fresh_age("sol", t0 + 10) < 30 and d.fresh_factor("sol", t0 + 10) > 1.5
    assert cut is not None and cut - 1002 >= d.cfg["onair_dwell"] and "fresh: mine" in d.cuts[-1][2], (cut, d.cuts)
    assert d.fresh_factor("sol", t0 + 400) == 1.0  # faded after fresh_s
    # visible progress: the plan's placed count rises
    luna["plan"] = {"kind": "build", "placed": 1}
    d.step(snap(team), t0 + 61)
    luna["plan"] = {"kind": "build", "placed": 4}
    d.step(snap(team), t0 + 62)
    assert d.progressed("luna", t0 + 62) and not d.progressed("sol", t0 + 62)
    assert not d.progressed("luna", t0 + 62 + d.cfg["progress_s"] + 1)


def quiet(cams):
    out = chart_dir()
    d, sent = world(cams)
    d.started = 1000  # (the periodic tour comes tour_first after this; the quiet one sooner)
    d.set_tours(basetour.Tours(out))
    team = [agent("luna", 0, 0, 3, activity="thinking", active=False),
            agent("sol", 300, 0, 2, activity="thinking", active=False)]
    t = 1000
    tour_t = None
    while t < 1400:
        d.step(snap(team), t)
        if subject(d) == "@tour" and tour_t is None:
            tour_t = t
            break
        t += 1
    assert tour_t is not None, (cams, d.cuts, d.quiets)
    shot = d.state[d.onair]
    assert shot["tour"]["surface"] == "nauvis" and shot["move"]["segments"][0]["pts"], shot
    assert d.public(tour_t)["main"]["look"]["label"] == "Nauvis base · a slow pan"
    assert onair_info({"agents": team}, d.public(tour_t))["tour"]["label"] == "Nauvis base · a slow pan"
    moved = [b for b in sent if b.get("move")]
    assert moved and moved[-1]["surface"] == "nauvis" and moved[-1]["zoom"] == basetour.ZOOM, moved[-1:]
    assert "tour: Nauvis base · a slow pan (quiet: luna still" in d.cuts[-1][2], d.cuts  # a cut row (one client too)
    assert moved[-1]["smooth"] is False  # framed off air (a standby; one client: a jump on air)
    if cams > 1:
        assert d.cuts[-1][1] != d.cuts[-2][1], d.cuts  # another client than the story's
    # held its seconds, then the best agent that is not stale (Sol just started walking), not the stale story
    team[1].update(active="move_to", activity="acting")
    for k in range(1, 80):
        team[1]["position"] = {"x": 300 + k, "y": 0}
        d.step(snap(team), tour_t + k)
        if subject(d) not in ("@tour", None) and k > 5:
            break
    assert subject(d) == "sol", (cams, subject(d), d.cuts[-2:])
    assert k >= int(basetour.SECONDS_MIN), k
    return d


def quiet_rotation():
    """With a standby: the quiet views take turns, the one shown longest ago first (tour, then a platform visit)."""
    out = chart_dir()
    d, _ = world(3, quiet_gap=60)
    d.started = 1000
    d.set_tours(basetour.Tours(out))
    d.plat_rows = {"Weaver": {"name": "Weaver", "at": "Nauvis", "view": {"surface": "platform-19", "hub": {"x": 0, "y": 0},
                                                                         "bounds": {"left": -20, "top": -40, "right": 20, "bottom": 30}}}}
    team = [agent("luna", 0, 0, 3, activity="thinking", active=False)]
    for t in range(1000, 1700):
        d.step(snap(team), t)
    kinds = [q[1] for q in d.quiets]
    assert kinds[:2] == ["tour", "platform"], d.quiets
    assert all(b[0] - a[0] >= 60 for a, b in zip(d.quiets, d.quiets[1:])), d.quiets


def quiet_guards():
    out = chart_dir()
    # an operator look takes the camera from a tour
    d, _ = world()
    d.set_tours(basetour.Tours(out))
    team = [agent("luna", 0, 0, 3, activity="thinking", active=False)]
    t = 1000
    while subject(d) != "@tour" and t < 1400:
        d.step(snap(team), t)
        t += 1
    assert subject(d) == "@tour"
    d.set_look({"surface": "nauvis", "position": {"x": 5, "y": 5}, "zoom": 1.0, "until": t + 30, "label": "Op",
                "by": "operator"}, t)
    for k in range(4):
        d.step(snap(team), t + k)
    assert subject(d) == "@look", subject(d)
    # host view: nothing cuts, no tour
    d2, _ = world()
    d2.set_tours(basetour.Tours(out))
    d2.set_host({"until": 5000, "label": "host"}, 999)
    for k in range(1000, 1400):
        d2.step(snap(team), k)
    assert not d2.tour_shots and not d2.quiets
    # a fight reported anywhere: no quiet view
    d3, _ = world()
    d3.set_tours(basetour.Tours(out))
    for k in range(1000, 1400):
        s = snap(team)
        s["fights"] = [{"key": "area:900,900", "kind": "attack", "first": 1000, "last": k, "position": {"x": 900, "y": 900}}]
        d3.step(s, k)
    assert not d3.quiets


def vehicles():
    feed = work.VehicleFeed()
    rows = [{"at": "2026-10-26T01:42:06.181Z", "event": "request", "request": {"id": "a", "action": "vehicle",
             "args": {"remote": True, "vehicle": 27069154, "go_to": {"x": -235, "y": -545}}}},
            {"at": "2026-10-26T01:42:06.240Z", "event": "response", "response": {"id": "a", "ok": True, "result": {
                "spidertron": "spidertron", "unit_number": 27069154, "position": {"x": -159.6, "y": -540.6},
                "go_to": {"x": -235, "y": -545}, "by": "remote view", "route": [{"x": -235, "y": -545}]}}},
            {"at": "2026-10-26T01:42:11.000Z", "event": "request", "request": {"id": "b", "action": "vehicle",
             "args": {"remote": True, "vehicle": 27069154}}},
            {"at": "2026-10-26T01:42:11.378Z", "event": "response", "response": {"id": "b", "ok": True, "result": {
                "spidertron": "spidertron", "unit_number": 27069154, "position": {"x": -214.7, "y": -543.9},
                "speed": 48, "by": "remote view", "route": [{"x": -235, "y": -545}]}}}]
    for r in rows:
        feed.ingest("opus", r)
    v = feed.current("opus", airtime.iso_t("2026-10-26T01:42:12Z"))
    assert v["position"] == {"x": -214.7, "y": -543.9} and v["speed"] == 48 and v["target"] == {"x": -235, "y": -545}, v
    drive = work.VehicleFeed()
    drive.ingest("sol", {"at": "2026-10-26T01:00:00Z", "event": "request", "request": {"id": "c", "action": "vehicle",
                         "args": {"remote": True, "vehicle": 311799, "drive": {"x": -80, "y": -150}}}})
    drive.ingest("sol", {"at": "2026-10-26T01:00:01Z", "event": "response", "response": {"id": "c", "ok": True, "result": {
        "remote": "by remote view: tank (-40,-150), unit_number 311799; your character stays at (240,-176)"}}})
    assert drive.current("sol", airtime.iso_t("2026-10-26T01:00:02Z"))["position"] == {"x": -40.0, "y": -150.0}
    for cams in (1, 3):
        d, sent = world(cams)
        now = v["t"] + 1
        opus = agent("opus", 0, 0, 5, activity="thinking", active=False)
        opus["remote_vehicle"] = v
        d.step(snap([opus]), now)
        d.step(snap([opus]), now + 2)
        shot = d.state[d.onair]
        assert shot.get("vehicle") == "Opus · spidertron by remote view" and "follow" not in shot, (cams, shot)
        # led on from the read toward its target at 48 km/h (13.3 tiles/s), at most to the target
        assert -235.0 <= shot["position"]["x"] < -214.7, shot["position"]
        assert d.vehicle_spot(dict(opus, position={"x": 0, "y": 0}), v["t"] + 0.75)["x"] == -224.7  # 10 tiles on
        assert d.public(now + 2)["main"]["vehicle"] == shot["vehicle"]
        # a later read further on: the view moves with it (a glide on the same client, no cut)
        v2 = dict(v, position={"x": -250.0, "y": -544.5}, t=now + 3, speed=0, target={"x": -260, "y": -545})
        opus["remote_vehicle"] = v2
        n = len(d.cuts)
        d.step(snap([opus]), now + 4)
        assert abs(d.state[d.onair]["position"]["x"] + 250) < 0.01 and len(d.cuts) == n and sent[-1].get("speed"), sent[-1]
        # the reads stop: twice vehicle_stale on, back to the character (a standby framed first, then the cut)
        late = now + 4 + 2 * d.cfg["vehicle_stale"] + 1
        for k in range(4):
            d.step(snap([opus]), late + k)
        assert d.state[d.onair].get("follow") == "opus" and not d.state[d.onair].get("vehicle"), d.state[d.onair]
        assert "back to the character" in d.cuts[-1][2], d.cuts[-1]
    # a drive by remote view, as status reports it every poll
    d, _ = world(1)
    sol = agent("sol", 240, -176, 5, active="drive")
    sol["plan"] = {"kind": "drive", "remote": "tank at (-40.0,-150.0) by remote view"}
    d.step(snap([sol]), 1000)
    assert d.state[d.onair]["position"] == {"x": -40.0, "y": -150.0} and "tank" in d.state[d.onair]["vehicle"]


def planner():
    out = chart_dir()
    p = basetour.plan("nauvis", out)
    pts = p["move"]["segments"][0]["pts"]
    assert 3 <= len(pts) <= 4 and pts[0]["x"] < pts[-1]["x"], pts  # west to east along the machines
    assert all(abs(q["y"] - 10.5) < 2 for q in pts), pts
    assert basetour.SECONDS_MIN <= p["seconds"] - 2 * basetour.REST_S <= basetour.SECONDS_MAX
    assert p["label"] == "Nauvis base · a slow pan"
    # only the cell at the origin charted: points whose frame reaches into the others are left out
    only = lambda s, cx, cy: 0 <= cx < 12 and 0 <= cy < 12  # noqa: E731
    q = basetour.plan("nauvis", out, charted=only)
    assert q is None or all(pt["x"] >= 0 for pt in q["move"]["segments"][0]["pts"]), q
    assert basetour.plan("gleba", out) is None  # no machines there
    assert basetour.plan("nauvis", out, charted=lambda s, cx, cy: False) is None


def measured():
    """airtime.measure over 20 minutes: Grok followed 0-300 s on its walk loop, Luna 300-600 s idle and on air after;
    Sol's build at 120 s never goes on air (missed); two cuts."""
    t0 = airtime.iso_t("2026-10-26T02:00:00Z")
    log = [{"t": t0, "slot": "main", "reason": "standby: grok", "target": {"agents": ["grok"]}, "cmd": {"follow": "grok"}},
           {"t": t0, "slot": "program", "reason": "cut to main: initial"},
           {"t": t0 + 299, "slot": "cam2", "reason": "standby: luna", "target": {"agents": ["luna"]}, "cmd": {"follow": "luna"}},
           {"t": t0 + 300, "slot": "program", "reason": "cut to cam2: rotate"},
           {"t": t0 + 600, "slot": "cam2", "reason": "reframe", "cmd": {"follow": "luna"}}]
    iso = lambda s: f"2026-10-26T02:{s // 60:02d}:{s % 60:02d}Z"  # noqa: E731
    grok = [{"at": iso(0), "event": "request", "request": {"id": "q", "action": "queue_repeat", "args": {
                "name": "w", "times": 99, "steps": [{"action": "move_to", "args": {"position": {"x": 62, "y": 18}}},
                                                    {"action": "move_to", "args": {"position": {"x": 20, "y": 30}}}]}}},
            {"at": iso(0), "event": "response", "response": {"id": "q", "ok": True, "result": {"repeating": True}}},
            {"at": iso(400), "event": "request", "request": {"id": "c", "action": "queue_cancel", "args": {}}}]
    luna = [{"at": iso(299), "event": "request", "request": {"id": "o", "action": "observe", "args": {}}},
            {"at": iso(599), "event": "response", "response": {"id": "o", "ok": True, "result": {
                "clock": "game 1h; +5m0s since your last request, character idle 5m0s of it (100%); hand crafting 0s queued"}}}]
    sol = [{"at": iso(120), "event": "request", "request": {"id": "b", "action": "build", "args": {}}},
           {"at": iso(120), "event": "response", "response": {"id": "b", "ok": True, "result": {}}}]
    js = {}
    for name, rows in (("grok", grok), ("luna", luna), ("sol", sol)):
        j = airtime.Journal(name).read(rows)
        j.close(t0 + 600)
        js[name] = j
    m = airtime.measure(log, js, t0, t0 + 1200)
    # Grok's loop on air 0-300 s (cancelled at 400, off air from 300), Luna idle on air 300-599 s: about 300 s each
    assert abs(m["loop_share"] - 0.25) < 0.01 and abs(m["idle_share"] - 0.25) < 0.01, m
    assert m["fresh_events"] == 1 and m["fresh_missed"] == 1 and m["cuts"] == 2, m


def replayed():
    """director_replay.py on a run folder: Grok's walk loop for 30 minutes, Luna and Sol thinking; this checkout's rules
    keep the loop off air most of the time (main's followed it: the operator's 19:43-21:40 log)."""
    import director_replay
    root = scratch()
    run = os.path.join(root, "shift1")
    iso = lambda s: f"2026-10-26T02:{s // 60:02d}:{s % 60:02d}Z"  # noqa: E731
    rows = {"grok": [{"at": iso(0), "event": "request", "request": {"id": "q", "action": "queue_repeat", "args": {
                "name": "w", "times": 999, "interval_ticks": 60,
                "steps": [{"action": "move_to", "args": {"position": {"x": 62, "y": 18}}},
                          {"action": "move_to", "args": {"position": {"x": 20, "y": 30}}}]}}},
                     {"at": iso(0), "event": "response", "response": {"id": "q", "ok": True, "result": {}}}]}
    for name, x in (("luna", 300), ("sol", -300), ("grok", 40)):
        rows.setdefault(name, [])
        for k in range(0, 1800, 120):  # a status read every 2 minutes: where it stands, idle between
            rows[name] += [{"at": iso(k + 1), "event": "request", "request": {"id": f"{name}{k}", "action": "status", "args": {}}},
                           {"at": iso(k + 1), "event": "response", "response": {"id": f"{name}{k}", "ok": True, "result": {
                               "position": {"x": x, "y": 0}, "surface": "nauvis",
                               "clock": "game 1h; +2m0s since your last request, character idle 2m0s of it (100%)"}}}]
        os.makedirs(os.path.join(run, name))
        with open(os.path.join(run, name, "journal.jsonl"), "w") as f:
            for r in sorted(rows[name], key=lambda r: r["at"]):
                f.write(json.dumps(r) + "\n")
    t0 = airtime.iso_t(iso(0))
    log = os.path.join(root, "director.jsonl")
    with open(log, "w") as f:
        f.write(json.dumps({"t": t0, "slot": "program", "reason": "cut to main: initial"}) + "\n")
        f.write(json.dumps({"t": t0 + 1800, "slot": "main", "reason": "reframe"}) + "\n")
    out = os.path.join(root, "replay.jsonl")
    for cams in (1, 3):
        _, js, (a, b) = director_replay.replay(log, [run], out, cams=cams, chart=chart_dir())
        m = airtime.measure(list(airtime.rows_of(out)), js, a, b)
        assert m["loop_share"] < 0.2 and m["cuts"] >= 3, (cams, m)
        assert any("quiet tour" in str(r.get("reason")) for r in airtime.rows_of(out)), cams


def main():
    looping()
    fresh_and_progress()
    for cams in (1, 2, 3):
        quiet(cams)
    quiet_rotation()
    quiet_guards()
    vehicles()
    planner()
    measured()
    replayed()
    print("freshcam: ok (a walk loop decays and gives way to a fresh agent; fresh and progress score up; quiet time "
          "airs chart-checked base tours at 1, 2 and 3 cameras behind host, operator looks and fights; a remote "
          "vehicle is shown where it is; airtime measures loop and idle share, fresh delays and cuts; director_replay replays a run's journals)")


if __name__ == "__main__":
    main()
