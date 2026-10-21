#!/usr/bin/env python3
"""The camera goes to a ship entering the dense asteroids of an edge leg (d20 batch57 S3, viewer Foobator, shift48
operator inbox 17:40: "if a ship reaches the dense part of edge asteroids, can you switch to it?"):
python3 tools/stream/test_edgecam.py

- edgedense.py: 2.0.77's spawn definitions (read on the private copy) give the dense part of Aquilo -> edge as 39.7% to
  91.9% of the way (8.1% to 60.3% flying back), edge -> Shattered Planet 76.5% to 99.9%; other legs have none.
- onecam maybe_edge, over the recorded shift47 leg of Limestone-spare-unbuilt (Astra's and Luna's platform reads,
  2026-10-20 14:16-16:04 PDT: aquilo->solar-system-edge 14%, 18%, 22%, 42%, 48%, 49%): no cut before 39.7%; at 42% the
  platform shot, why "edge", labelled "Limestone-spare-unbuilt · dense asteroids near the solar system edge", framed
  as platform_shot frames it (guns' reach), held platform_hold; not again on the same leg; again on the next leg (it
  turned back toward Aquilo: edge->aquilo, 41% of the way and in that leg's dense part); a danger shot takes it over;
  it waits while an urgent attack shot holds the camera.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import edgedense  # noqa: E402
from test_onecam import world  # noqa: E402
from test_platformcam import VIEW, plat, snap, team, main_row  # noqa: E402

NAME = "Limestone-spare-unbuilt"
GUNS_VIEW = dict(VIEW, surface="platform-7", guns=[{"x": 0, "y": -8, "range": 18}, {"x": 6, "y": 8, "range": 40}])
RECORDED = [14, 18, 22, 42, 48, 49]  # aquilo->solar-system-edge, toward the edge


def row(pct, toward="solar-system-edge", conn="aquilo->solar-system-edge"):
    return plat(NAME, at=f"{conn} {pct}%", view=GUNS_VIEW, toward=toward)


def spans():
    assert edgedense.trip_span("aquilo", "solar-system-edge") == (39.7, 91.9), edgedense.trip_span("aquilo", "solar-system-edge")
    lo, hi = edgedense.trip_span("solar-system-edge", "aquilo")
    assert round(lo, 1) == 8.1 and round(hi, 1) == 60.3, (lo, hi)
    assert edgedense.trip_span("solar-system-edge", "shattered-planet") == (76.5, 99.9)
    assert edgedense.trip_span("aquilo", "gleba") is None and edgedense.leg(plat("K", at="aquilo->gleba 50%")) is None
    assert edgedense.density("aquilo-solar-system-edge", 0.9) == 12.5
    r = row(42)
    assert r["route_ids"] == ["aquilo", "solar-system-edge"] and edgedense.in_dense(r) and not edgedense.in_dense(row(22))
    # flown the other way on the same connection name: the route turns round (model.platform_where)
    back = row(59, toward="aquilo", conn="aquilo->solar-system-edge")
    assert back["route_ids"] == ["solar-system-edge", "aquilo"] and back["route"]["pct"] == 41 and edgedense.in_dense(back)


def on(d, t):
    return main_row(d, t).get("platform") or {}


def recorded_leg():
    d, sent = world(map_every=0, platform_every=0)
    a, t = team(), 1000
    d.step(snap(a), t)
    cuts = []
    for k, pct in enumerate(RECORDED):
        for s in range(30):  # 30 s per platform read
            now = t + 1 + 30 * k + s
            d.step(snap(a, [row(pct)]), now)
            p = on(d, now)
            if p.get("why") == "edge" and (not cuts or cuts[-1][1] != pct):
                cuts.append((now, pct, p))
    assert [c[1] for c in cuts] == [42], [c[:2] for c in cuts]  # at 42%, not before; held through 48%
    first, _, p = cuts[0]
    assert p["name"] == NAME and p["label"] == f"{NAME} · dense asteroids near the solar system edge" and p["kind"] == "edge", p
    cfg = d.cfg
    # framed as the platform shots are (d20 batch50 A: the guns' reach in flight)
    import model
    zoom = model.platform_shot(GUNS_VIEW, travelling=True, frac=cfg["view_frac"])["zoom"]
    assert any(b.get("surface") == "platform-7" and b.get("zoom") == zoom for b in sent), (zoom, sent[-3:])
    # held platform_hold (+ ready_s), then the story comes back; not again on this leg
    end = first + cfg["ready_s"] + cfg["platform_hold"] + 3
    for now in range(int(first) + 1, int(end) + 60):
        d.step(snap(a, [row(49)]), now)
    assert on(d, end + 60).get("why") != "edge"
    # it turns back toward Aquilo (the shift47 reads after 16:04: edge->aquilo 58%-60%, 41% of the way back): a new leg
    t2 = end + 120
    for s in range(10):
        d.step(snap(a, [row(59, toward="aquilo")]), t2 + s)
    assert on(d, t2 + 9).get("why") == "edge", on(d, t2 + 9)
    # back at Aquilo, then out to the edge again: counts again
    t3 = t2 + 120
    for s in range(60):
        d.step(snap(a, [plat(NAME, at="aquilo", view=GUNS_VIEW)]), t3 + s)
    assert on(d, t3 + 59).get("why") != "edge"
    for s in range(10):
        d.step(snap(a, [row(45)]), t3 + 60 + s)
    assert on(d, t3 + 69).get("why") == "edge", on(d, t3 + 69)
    return d


def danger_and_busy():
    a, t = team(), 1000
    # a danger shot on the same ship takes the edge shot over
    d, _ = world(map_every=0, platform_every=0)
    d.step(snap(a), t)
    for s in range(1, 5):
        d.step(snap(a, [row(45)]), t + s)
    assert on(d, t + 4).get("why") == "edge", on(d, t + 4)
    hot = dict(row(46), danger={"kind": "fire", "reason": f"{NAME} under fire: 2 buildings lost", "last": t + 5, "level": 2000})
    for s in range(5, 9):
        d.step(snap(a, [hot]), t + s)
    assert on(d, t + 8).get("why") == "danger", on(d, t + 8)
    # an edge shot never takes the camera from a danger shot already on air
    d, _ = world(map_every=0, platform_every=0)
    d.step(snap(a), t)
    for s in range(1, 6):
        d.step(snap(a, [dict(row(30), danger={"kind": "fire", "reason": f"{NAME} under fire", "last": t + s, "level": 10})]), t + s)
    assert on(d, t + 5).get("why") == "danger", on(d, t + 5)
    for s in range(6, 12):  # into the dense part while the hits go on
        d.step(snap(a, [dict(row(41), danger={"kind": "fire", "reason": f"{NAME} under fire", "last": t + s, "level": 10})]), t + s)
    assert on(d, t + 11).get("why") == "danger", on(d, t + 11)


def main():
    spans()
    recorded_leg()
    danger_and_busy()
    print("edge cam: ok (Aquilo -> edge dense from 39.7%: the recorded Limestone leg cut once at 42%, again on the way "
          "back; a danger shot takes it over)")


if __name__ == "__main__":
    main()
