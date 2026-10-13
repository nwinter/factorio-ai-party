#!/usr/bin/env python3
"""Key battles (onecam.py watch_battle, replays.py; Nick 12:54: "is there a good way to ensure we don't miss entirety
of key battles like that?", and on the 12:58 replay: "a few seconds on Nauvis, several seconds of an empty field
somewhere else on Nauvis, then nothing on the demolisher battle"): python3 tools/stream/test_battles.py

The timeline is shift06's 12:58 battle as its alerts came in (runs/shift06/stream-service.log): Sol alone on
Vulcanus behind gun turrets at (-236, 68), small demolishers; 19 turrets lost at 12:58:27, 44, 55 pieces, Sol dead at
12:58:45, 67 pieces (59 turrets) and the poles and drills by ~12:59:40. That shift's director cut to the first loss,
then to the death, and at 12:59:02 left for a trio; the replay was 10 s, of the wrong surface.

1. What makes a key battle: a big enemy, a big loss (battle_losses), an attack going on past battle_long.
2. The director: on the battle from its first sign until it has been quiet battle_after (fights near it are one
   battle; its death shot holds; no trio, rotation or base map; another agent's real loss elsewhere is an inset), on
   the battle's surface the whole time; then back to the story it interrupted.
3. Replays: a clip of the program's footage of the battle only (its surface and area), its length scaled with the
   losses (59 turrets: 40 s, the buffer's limit), saved while it is in the buffer, aired once the battle is over, and
   only when the program missed part of it; no footage: no replay. The battle's loss alerts get no loss clips.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replays as rp  # noqa: E402
from segments import Segments  # noqa: E402
from test_fight_replays import FakeOBS  # noqa: E402
from test_onecam import agent, world  # noqa: E402
from onecam import loss_pieces  # noqa: E402

rp.time.sleep = lambda s: None

V = "vulcanus"
# (seconds after 12:58:27, text, x, y): live.py's loss alerts for the raid, as the service log has them
LOSSES = [(0, "19 lost near (-226, 68): 19 gun turret (by small demolishers)", -226, 68),
          (12, "44 lost near (-237, 64): 40 gun turret, 2 accumulator (by small demolishers)", -237, 64),
          (18, "55 lost near (-241, 64): 50 gun turret, 3 solar panel (by small demolishers)", -241, 64),
          (25, "4 lost near (-235, 54): 2 medium electric pole, 1 big mining drill (by small demolishers)", -235, 54),
          (60, "67 lost near (-245, 64): 59 gun turret, 4 solar panel (by small demolishers)", -245, 64),
          (70, "10 lost near (-243, 51): 5 medium electric pole, 2 big mining drill (by small demolishers)", -243, 51)]
DEATH_T = 18


def snapshot(t, t0, team, elsewhere=()):
    """The snapshot at t: fights as model.py reports them (a loss entry re-reported ~2 minutes, its `losses` the
    moment it came in), the alerts of this second, Sol's own fight while it is alive and in combat."""
    s = t - t0
    sol = team[0]
    sol["alive"] = s < DEATH_T
    sol["combat"] = 0 <= s < DEATH_T
    fights, alerts = [], []
    for at, text, x, y in LOSSES:
        if at <= s < at + 120:
            pos = {"x": x, "y": y, "surface": V, "extent": 16}
            fights.append({"key": f"loss:{x},{y}", "kind": "loss", "text": text, "first": t0 + at, "last": t,
                           "losses": [t0 + at], "position": pos, "agent": None})
            if at == s:
                alerts.append({"id": f"l{at}", "kind": "loss", "t": t, "text": text, "position": pos,
                               "key": f"loss:{x},{y}"})
    if 0 <= s < DEATH_T:  # model.py: the agent's own fight (its position has no surface: shift06's alert surface bug)
        fights.append({"key": "attack:sol", "kind": "attack", "text": "Sol is under attack", "first": t0, "last": t,
                       "losses": [], "position": {"x": -236, "y": 68}, "agent": "sol"})
    if s == DEATH_T:
        alerts.append({"id": "d1", "kind": "death", "t": t, "text": "Sol died on Vulcanus",
                       "position": {"x": -236, "y": 68, "surface": V}})
    for e in elsewhere:
        if e["t"] == t:
            alerts.append(e)
    return {"agents": team, "fights": fights, "alerts": alerts}


def team():
    sol = agent("sol", -236, 68, 2)
    sol["surface"] = V
    return [sol, agent("astra", 0, 0, 6), agent("luna", 300, 0, 1)]


def run(d, rpl, seg, t0, t1, tm, follow=None, elsewhere=()):
    """One tick a second, director then replays (serve.py's ticker); -> [(t, public main row)]."""
    rows = []
    for t in range(t0 - 10, t1):
        if follow and t == follow[1]:
            d.set_follow(follow[0], follow[2], None, "test", t)
        sn = snapshot(t, t0, tm, elsewhere)
        segment = seg.step(sn, t) if seg else None
        cams = d.step(sn, t, seg.camera() if seg else None)
        sn["battle"] = d.battle_info(t)
        if rpl:
            rpl.tick(sn, cams, t)
            rpl.work(t)
        rows.append((t, dict(cams.get("main") or {}, _inset=cams.get("inset")), sn["battle"]))
    return rows


def what_counts():
    """Which fights become battles is threats.py's (test_threats.py); here: the demolisher raid scores far above
    the bar, and the pieces read from the loss texts."""
    d, _ = world()
    rows = run(d, None, None, 60000, 60030, team())
    assert d.battles and d.battles[0][2].startswith("score "), d.battles
    assert float(d.battles[0][2].split()[1]) >= 10, d.battles  # tier 5 (demolishers) against a usual tier 1
    assert loss_pieces(LOSSES[4][1]) == 67 and loss_pieces("Sol died") == 0
    print(f"what counts: ok (the 12:58 raid: {d.battles[0][2]})")


def director():
    d, _ = world(trio=True, trio_every=30, trio_gap=0, map_every=60, map_first=0)
    tm, t0 = team(), 10000
    # another agent dies on Nauvis mid-battle (a death skips the alert spacing; normally a cut): an inset
    death_nauvis = {"id": "n1", "kind": "death", "t": t0 + 40, "text": "Luna died", "agent": "luna",
                    "position": {"x": 300, "y": 0, "surface": "nauvis"}}
    rows = run(d, None, None, t0, t0 + 160, tm, elsewhere=[death_nauvis])
    before = [r for t, r, b in rows if t < t0]
    assert before and before[-1]["agents"] == ["astra"], before[-1]
    on = [(t - t0, r) for t, r, b in rows if t0 + 3 <= t <= t0 + 114]
    for s, r in on:  # the battle's surface the whole time, from 3 s after its first sign
        fr = r.get("frame") or {}
        where = fr.get("surface") or ("vulcanus" if fr.get("follow") == "sol" else "?")
        assert where == V, (s, r)
    assert d.battles and d.battles[0][2].startswith("score "), d.battles
    during = [x for x in d.layouts + d.maps if t0 < x[0] <= t0 + 114]  # (a trio before it ends at its first sign)
    assert d.mode == "onecam" and not during, during
    assert any(c[2].startswith("battle (big enemy)") or c[2].startswith("loss: 19 lost") for c in d.cuts), d.cuts
    r41 = next(r for t, r, b in rows if t == t0 + 41)
    assert (r41.get("frame") or {}).get("surface") == V and (r41["_inset"] or {}).get("attack") == "Luna died", r41
    b = next(b for t, r, b in rows if t == t0 + 65)
    assert b["lost"] == 67 and "59 gun turret" in b["label"] and b["agent"] is None and b["on_air"], b
    assert b["position"]["surface"] == V and b["first"] == t0, b
    end = next(t for t, r, b in rows if t > t0 and b is None)
    assert t0 + 114 <= end <= t0 + 118, end - t0  # the last loss at +70: no loss for battle_loss_after (45 s)
    after = [r for t, r, b in rows if t > end + 3]
    assert after[-1]["agents"] == ["astra"], after[-1]  # back to the story it interrupted
    print(f"director: ok (on Vulcanus +3..+114 s, death shot inside, no trio/map, a Nauvis death an inset, over at "
          f"+{end - t0} s, back to Astra)")


def replays_world():
    seg = Segments(spacing=0)
    logs = []
    rpl = rp.Replays(seg, obs=FakeOBS(), log=lambda *a: logs.append(" ".join(map(str, a))), start=False)
    rpl.work(0)
    return seg, rpl, logs


def replay_aftermath():
    """The camera pinned elsewhere for the first 30 s (an operator follow on Astra): footage starts long after the
    first loss, so it is aftermath (Nick, 13:40): no replay."""
    d, _ = world()
    seg, rpl, logs = replays_world()
    t0 = 20000
    run(d, rpl, seg, t0, t0 + 200, team(), follow=("astra", t0 - 5, t0 + 30))
    over = next(l for l in logs if l.startswith("[replays] battle over"))
    assert "replay none, aftermath only" in over and rpl.status["replays"] == 0, logs
    assert not any("pending loss" in l for l in logs), [l for l in logs if "loss" in l]  # the battle's losses: no loss clips
    print(f"replay, aftermath: ok ({over.split('): ')[1]})")


def replay_start_then_away():
    """Sol on air when the first loss comes in (the start is live), then the camera is pinned elsewhere from +30 s:
    the start window (3 s before the first sign, 40 s for 59 turrets) airs once the battle is over."""
    d, _ = world()
    seg, rpl, logs = replays_world()
    t0 = 25000
    tm = team()
    tm[0]["interest"] = 30  # Sol on air before the raid
    run(d, rpl, seg, t0, t0 + 200, tm, follow=("astra", t0 + 30, t0 + 600))
    saved = next(l for l in logs if "battle start saved" in l)
    assert "40 s from 3 s before its first sign" in saved, saved
    c = rpl.status["last"] or {}
    assert c.get("label", "").startswith("Battle") and sum("on air: Battle" in l for l in logs) == 1, logs
    over = next(l for l in logs if l.startswith("[replays] battle over"))
    assert "replay its start" in over, over
    print(f"replay, start live then away: ok ({saved.split('] ')[1]})")


def replay_live_and_none():
    # on air from its first sign (the cut within 2 s) to the end: no replay (viewers saw it live)
    d, _ = world()
    seg, rpl, logs = replays_world()
    run(d, rpl, seg, 30000, 30200, team())
    over = next(l for l in logs if l.startswith("[replays] battle over"))
    assert "replay none, the program showed" in over and not any("on air: Battle" in l for l in logs), logs
    # pinned elsewhere the whole battle: no footage of it, no replay (never a clip of another place)
    d, _ = world()
    seg, rpl, logs = replays_world()
    run(d, rpl, seg, 40000, 40200, team(), follow=("astra", 40000 - 5, 40000 + 600))
    over = next(l for l in logs if l.startswith("[replays] battle over"))
    assert "no on-air footage of its start" in over and rpl.status["replays"] == 0, logs
    print("replay, live / no footage: ok (none either way)")


def episodes():
    """model.py: a fight reported again after FIGHT_EPISODE_GAP is a new fight (its own first sign); shift06 13:2x
    "Astra is under attack" kept a first from minutes before."""
    from model import Model, FIGHT_EPISODE_GAP
    m = Model({"agents": {"astra": {}}})
    m._fight("attack:astra", "attack", {"x": 0, "y": 0}, 1000, "Astra is under attack", agent="astra")
    m._fight("attack:astra", "attack", {"x": 0, "y": 0}, 1010, "Astra is under attack", agent="astra")
    assert m.fights["attack:astra"]["first"] == 1000
    m._fight("attack:astra", "attack", {"x": 0, "y": 0}, 1010 + FIGHT_EPISODE_GAP + 1, "Astra is under attack", agent="astra")
    assert m.fights["attack:astra"]["first"] == 1010 + FIGHT_EPISODE_GAP + 1
    print("episodes: ok")


def no_flicker():
    """Astra fights 60 s with a combat flag that flickers (shift06 13:29: cuts between Astra and the area view every
    few seconds): one cut to the battle, then the same shot."""
    d, _ = world()
    astra = agent("astra", 0, 0, 1)
    tm = [astra, agent("luna", 300, 0, 5), agent("sol", -300, 0, 1)]
    t0 = 50000
    for k in range(-5, 120):
        t = t0 + k
        astra["combat"] = 0 <= k < 90 and (k // 3) % 2 == 0
        fights = [{"key": "attack:astra", "kind": "attack", "text": "Astra is under attack", "first": t0, "last": t,
                   "losses": [], "position": {"x": 0, "y": 0}, "agent": "astra"}] if 0 <= k < 90 else []
        d.step({"agents": tm, "fights": fights, "alerts": []}, t)
    during = [c for c in d.cuts if t0 <= c[0] < t0 + 90]
    assert d.battles, d.battles  # (an agent attacked for a minute: agent + duration parts, over the floor)
    assert len(during) <= 1, during
    print(f"no flicker: ok ({len(during)} cut during the battle)")


def lengths():
    _, rpl, _ = replays_world()
    assert rpl.battle_len({"lost": 0}) == 15 and rpl.battle_len({"lost": 19}) == 24.5
    assert rpl.battle_len({"lost": 67}) == 40  # capped by the 45 s buffer
    print("lengths: ok (15 s + 0.5 s a piece, at most 40)")


if __name__ == "__main__":
    what_counts()
    director()
    replay_aftermath()
    replay_start_then_away()
    replay_live_and_none()
    episodes()
    no_flicker()
    lengths()