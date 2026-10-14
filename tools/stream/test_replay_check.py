#!/usr/bin/env python3
"""Replays show the moment, or don't air (task-replaycheck; viewer awoo3391, shift09 00:44: "death replays are a great
idea, but the one we just saw didnt actually capture the death at all"): python3 tools/stream/test_replay_check.py

shift09 00:38:56-00:40:39: the main camera followed Sol fighting pentapods on Gleba near (264, 25); he died, the
director cut to Astra ("sol unavailable"), then to the spot (the urgent death cut). Three clips were saved for that
one death (the death, the loss of his character, and the same loss re-reported 90 s later) and two aired; the loss
clip was the aftermath after the urgent cut (from 33193 ms of 42966 ms).

1. The moment: a loss's tick (the incident's last_tick) maps to wall time through the snapshots' (tick_t, tick)
   samples; a death takes the tick of its character's loss where the agent last stood.
2. On air: the dead agent (followed, or inside the frame) or the loss's spot in the main view for 3 s of the 15 s
   before the moment; otherwise no replay, logged "not on air at the time". Footage after the moment (the urgent cut)
   does not count.
3. The clip: 8 s before the moment to 3 s after, saved 1 s after its end; the seek offset from the save time.
4. One replay per moment: Sol's death and his character's loss are one (the death's clip, whichever is judged
   first); the same loss re-reported is no new moment; a later moment of one incident replaces the waiting clip only
   if it was on air longer.
5. model.py and live.py carry the tick: the loss event's last_tick, fights' loss_ticks, the snapshot's tick_t.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replays as rp  # noqa: E402
from segments import Segments  # noqa: E402
from test_replay_footage import SeekOBS, FRAC  # noqa: E402

rp.time.sleep = lambda s: None

SPOT = {"x": 264.0, "y": 25.0, "extent": 16.0, "surface": "gleba"}
LOSS = "1 lost on Gleba near (264, 25): 1 character (by small wriggler pentapod prematures)"
TICK0 = 6_800_000
logs = []


def world():
    seg = Segments(spacing=0)
    rpl = rp.Replays(seg, obs=SeekOBS(), log=lambda *a: logs.append(" ".join(map(str, a))), start=False)
    rpl.work(0)
    return seg, rpl


def tick_at(t, t0):
    return TICK0 + round((t - t0) * 60)


def sol(t, death):
    return {"name": "sol", "alive": t < death, "position": {"x": 264.0, "y": 25.0}, "surface": "gleba"}


ASTRA = {"name": "astra", "alive": True, "position": {"x": 0.0, "y": 0.0}, "surface": "nauvis"}


def shift09_cams(death, t0, on_sol=True):
    """Main on Sol until a second after he died (or on Astra all along), Astra for 3 s, then the urgent cut to the
    spot (the death cut) for 26 s, then Astra again."""
    def cams(t):
        if t < death + 1:
            return {"main": {"agents": ["sol"], "since": t0 - 100, "frame": {"follow": "sol", "zoom": 1.42, "frac": FRAC}}
                    if on_sol else {"agents": ["astra"], "since": t0 - 100, "frame": {"follow": "astra", "zoom": 1.2, "frac": FRAC}}}
        if t < death + 4:
            return {"main": {"agents": ["astra"], "since": death + 1, "frame": {"follow": "astra", "zoom": 1.2, "frac": FRAC}}}
        if t < death + 30:
            return {"main": {"agents": [], "since": death + 4,
                             "frame": {"position": {"x": 264.0, "y": 25.0}, "surface": "gleba", "zoom": 1.1, "frac": FRAC}}}
        return {"main": {"agents": ["astra"], "since": death + 30, "frame": {"follow": "astra", "zoom": 1.2, "frac": FRAC}}}
    return cams


def run(seg, rpl, t0, t1, death, cams, loss_seen=(), alert_at=None, attack_until=None):
    """One tick a second. The loss entry as model.py reports it: each report time in losses, its tick beside it.
    Sol's own fight (combat flag) until he dies. The death alert reaches on_attack_cut at alert_at."""
    aired = []
    tick_d = tick_at(death, t0)
    for t in range(t0, t1):
        fights = []
        if attack_until is None or t <= attack_until:
            if t <= death + 20:
                fights.append({"key": "attack:sol", "kind": "attack", "text": "Sol is under attack", "position": dict(SPOT),
                               "first": t0, "last": min(t, death), "losses": [], "loss_ticks": []})
        seen = [x for x in loss_seen if x <= t]
        if seen:
            fights.append({"key": "loss:gleba:#96", "kind": "loss", "text": LOSS, "position": dict(SPOT), "first": seen[0],
                           "last": t, "losses": seen, "loss_ticks": [tick_d] * len(seen)})
        # the tick as read half a second before the snapshot (the status poll)
        snap = {"agents": [sol(t, death), ASTRA], "fights": fights, "alerts": [], "tick": tick_at(t - 0.5, t0), "tick_t": t - 0.5}
        if alert_at is not None and t == alert_at:
            rpl.on_attack_cut({"kind": "death", "agent": "sol", "text": "Sol died on Gleba", "t": t}, snap, t)
        seg.step(snap, t)
        rpl.tick(snap, cams(t), t)
        rpl.work(t)
        if rpl.playing and rpl.playing not in [c for _, c in aired]:
            aired.append((rpl.status["last"]["label"], rpl.playing))
    return [label for label, _ in aired]


def wall_of():
    _, rpl = world()
    assert rpl.wall_of(100) is None
    for t, k in ((10.0, 600), (11.0, 660), (13.0, 660), (14.0, 720)):  # paused from 11 to 13
        rpl.ticks.append((t, k))
    assert rpl.wall_of(630) == 10.5 and rpl.wall_of(690) == 13.5
    assert rpl.wall_of(540) == 9.0 and rpl.wall_of(780) == 15.0  # before the first sample, after the last
    assert rpl.wall_of(660) == 11.0
    print("wall_of: ok")


def shift09():
    """Sol on air until he died: one replay (the death), the moment from the tick, 8 s before to 3 s after; his
    character's loss and its re-report add none."""
    del logs[:]
    seg, rpl = world()
    t0, death = 100_000, 100_040
    cams = shift09_cams(death, t0)
    seek = {}
    obs = rpl.obs
    orig = obs.call

    def call(req, data=None):
        out = orig(req, data)
        if req == "SetMediaInputCursor":
            seek["cursor"] = data["mediaCursor"]
        return out
    obs.call = call
    aired = run(seg, rpl, t0, death + 130, death, cams, loss_seen=[death + 2, death + 92], alert_at=death + 3)
    assert aired == ["Sol died on Gleba"], (aired, logs[-12:])
    assert rpl.status["replays"] == 1, logs[-12:]
    pend = next(x for x in logs if "pending death: Sol died on Gleba" in x)
    assert "(tick), 16 s on air before it" in pend, pend
    assert any("skipped loss: the death replay of Sol died on Gleba covers it" in x for x in logs), logs
    assert any("skipped loss: its moment has left the replay buffer" in x for x in logs), logs  # the re-report
    last = rpl.status["last"]
    # saved at death + 4 (3 s after, + 1): the clip starts 12 s back from the file's end (45 s)
    assert seek["cursor"] == 45000 - 12000, seek
    assert last["path"] == "r1.mkv"
    print("shift09: ok (one replay: the death, from its tick, 8 s before to 3 s after; the character loss and its re-report none)")


def loss_first():
    """The character's loss judged before the death alert (a slow status poll): its clip waits; the death replaces it."""
    del logs[:]
    seg, rpl = world()
    t0, death = 200_000, 200_040
    aired = run(seg, rpl, t0, death + 90, death, shift09_cams(death, t0), loss_seen=[death + 2], alert_at=death + 6)
    assert aired == ["Sol died on Gleba"], (aired, logs[-10:])
    assert any("replaced the waiting clip of " + LOSS + ": the death's replay replaces its character loss's" in x
               for x in logs), logs[-10:]
    assert rpl.status["replays"] == 2, logs[-10:]  # both saved; the loss's dropped before it aired
    print("loss first: ok (the death's clip replaces its character loss's)")


def off_air():
    """Main on Astra all along: the death and the loss are not replayed, whatever the urgent cut shows after."""
    del logs[:]
    seg, rpl = world()
    t0, death = 300_000, 300_040
    aired = run(seg, rpl, t0, death + 60, death, shift09_cams(death, t0, on_sol=False), loss_seen=[death + 2],
                alert_at=death + 3)
    assert aired == [] and rpl.status["replays"] == 0 and rpl.pending is None and rpl.clip is None, (aired, logs[-6:])
    assert any("skipped death: not on air at the time (0 s of the 15 s before it) (Sol died on Gleba)" in x for x in logs), logs
    assert any("skipped loss: not on air at the time (0 s of the 15 s before it)" in x for x in logs), logs
    print("off air: ok (no replay; logged why)")


def short_look():
    """On air only 2 s before the death (main reached Sol a second before): under 3 s, no replay."""
    del logs[:]
    seg, rpl = world()
    t0, death = 400_000, 400_040
    base = shift09_cams(death, t0, on_sol=False)

    def cams(t):
        if death - 1 <= t < death + 1:
            return {"main": {"agents": ["sol"], "since": death - 4, "frame": {"follow": "sol", "zoom": 1.42, "frac": FRAC}}}
        return base(t)
    run(seg, rpl, t0, death + 10, death, cams, loss_seen=[death + 2], alert_at=death + 3)
    assert any("skipped death: not on air at the time (2 s of the 15 s" in x for x in logs), logs[-4:]
    # a cut 2 s settles: footage from main's own cut on counts only after cut_settle
    del logs[:]
    seg, rpl = world()

    def cams2(t):
        if death - 4 <= t < death + 1:
            return {"main": {"agents": ["sol"], "since": death - 4, "frame": {"follow": "sol", "zoom": 1.42, "frac": FRAC}}}
        return base(t)
    run(seg, rpl, t0, death + 10, death, cams2, loss_seen=[death + 2], alert_at=death + 3)
    assert any("pending death: Sol died on Gleba; moment " in x and ", 3 s on air before it" in x for x in logs), logs[-4:]
    print("short look: ok (3 s of the 15 s before it, counted from 2 s after the cut)")


def incident_moments():
    """A raid's incident (one key) with two moments while the attack goes on: the second, on air longer, replaces the
    waiting clip; a third, barely on air, does not."""
    del logs[:]
    seg, rpl = world()
    t0 = 500_000
    key, spot = "loss:#7", {"x": 75.0, "y": -55.0, "extent": 12.0, "surface": "nauvis"}
    box = {"position": {"x": 75.0, "y": -55.0}, "surface": "nauvis", "zoom": 0.8, "frac": FRAC}
    away = {"follow": "astra", "zoom": 1.2, "frac": FRAC}
    m1, m2, m3 = t0 + 20, t0 + 50, t0 + 75  # the moments (ticks); alerts 2 s later

    def cams(t):
        on = (m1 - 3 <= t < m1 + 2) or (m2 - 20 <= t < m2 + 5) or (m3 - 1 <= t)
        return {"main": {"agents": [], "since": 0, "frame": box if on else away}}
    reports = [m1 + 2, m2 + 2, m3 + 2]
    for t in range(t0, t0 + 140):
        seen = [x for x in reports if x <= t]
        ticks = [tick_at(x - 2, t0) for x in seen]
        fights = [{"key": "area:75,-55", "kind": "attack", "text": "Base under attack near (75, -55)", "position": dict(spot),
                   "first": t0, "last": min(t, t0 + 85), "losses": [], "loss_ticks": []}]
        if seen:
            fights.append({"key": key, "kind": "loss", "text": "3 lost near (75, -55): 3 gun turret", "position": dict(spot),
                           "first": seen[0], "last": t, "losses": seen, "loss_ticks": ticks})
        snap = {"agents": [ASTRA], "fights": fights, "alerts": [], "tick": tick_at(t, t0), "tick_t": t}
        seg.step(snap, t)
        rpl.tick(snap, cams(t), t)
        rpl.work(t)
    assert any("replaced the waiting clip of 3 lost near (75, -55): 3 gun turret: on air 16 s before it, the waiting clip 4 s"
               in x for x in logs), logs
    assert any("skipped loss: not on air at the time (2 s of the 15 s before it)" in x for x in logs), logs  # m3: 2 s
    saved = [x for x in logs if x.startswith("[replays] saved")]
    aired = [x for x in logs if x.startswith("[replays] on air:")]
    assert len(aired) == 1, aired
    assert rpl.status["last"]["path"] == f"r{len(saved)}.mkv", (saved, rpl.status["last"])  # the second moment's file
    print("incident moments: ok (the clip on air longer replaces the waiting one; one airs)")


def carried_tick():
    """live.py's loss event keeps the incident's last_tick; model.py's fights keep it beside each report and the
    snapshot says when the tick was read."""
    from live import LiveSource
    from model import Model
    ev = LiveSource.loss_events({"incidents": [{"id": 96, "surface": "gleba", "box": {"x0": 262, "y0": 23, "x1": 266, "y1": 27},
                                                "total": 1, "names": "character", "by": "small-wriggler-pentapod-premature",
                                                "last_tick": 6_800_000}]}, tick=6_800_100)[0]
    assert ev["key"] == "loss:gleba:#96" and ev["tick"] == 6_800_000, ev
    m = Model({"agents": {"sol": {}}})
    m.ingest({"tick": 6_800_100, "agents": [], "events": [ev]}, now=1000.0)
    snap = m.snapshot(1000.5)
    f = next(f for f in snap["fights"] if f["key"] == "loss:gleba:#96")
    assert f["loss_ticks"] == [6_800_000] and f["losses"] == [1000.0], f
    assert snap["tick_t"] == 1000.0 and snap["tick"] == 6_800_100, (snap["tick"], snap["tick_t"])
    m.ingest({"agents": [], "events": []}, now=1001.0)  # a poll without a tick keeps when the last one was read
    assert m.snapshot(1001.5)["tick_t"] == 1000.0
    print("carried tick: ok")


def main():
    wall_of()
    shift09()
    loss_first()
    off_air()
    short_look()
    incident_moments()
    carried_tick()
    print("replay check: ok")


if __name__ == "__main__":
    main()
