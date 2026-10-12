#!/usr/bin/env python3
"""A loss replay is the program's own footage of the loss site (shift01, 15:14: four clips of small biters taking
chests and poles near (75, -55) aired Sol walking in the base; the loss was 35 tiles north of him, off frame):
python3 tools/stream/test_replay_footage.py

1. "Shown" is geometry: the spot inside the frame of the camera on air or the inset (the client's view at the zoom
   sent to the game, after the on-air crop). Sol followed at zoom 1.42 with the landscape crop shows ~28 x 24 tiles.
2. Off frame all along: no clip. A cut to the fight after the loss: a clip from the cut on (where the footage starts).
   An inset on it counts. Ticks while a replay is on air count for nothing (the program is the replay).
3. Losses of one fight inside one clip's stretch: one clip.
4. The seek offset: the clip ends at saved_t (the Mac's clock when SaveReplayBuffer was sent); playback starts
   saved_t - show_from before the file's end. The file name (box local time, an hour behind) is never read.
5. The director (onecam): an alert outside the on-air frame is not "already on air" (shift01 used 60 tiles), so a
   minor loss gets an inset and a real one a cut.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replays as rp  # noqa: E402
from segments import Segments  # noqa: E402
from test_fight_replays import FakeOBS  # noqa: E402
from onecam import OneCam  # noqa: E402

rp.time.sleep = lambda s: None

FRAC = 0.658  # layout.json main 1208x1032 on a 16:9 client (cuts.view_frac)
SITE = {"x": 75, "y": -55, "extent": 12.0, "surface": "nauvis"}
LOSS_TEXT = "7 lost near (75, -55): 4 small electric pole, 2 wooden chest (by small biters)"
logs = []


class SeekOBS(FakeOBS):
    def __init__(self):
        super().__init__()
        self.cursor = None

    def call(self, req, data=None):
        if req == "SetMediaInputCursor":
            self.cursor = data["mediaCursor"]
        return super().call(req, data)


def world():
    seg = Segments(spacing=0)
    rpl = rp.Replays(seg, obs=SeekOBS(), log=lambda *a: logs.append(" ".join(map(str, a))), start=False)
    rpl.work(0)
    return seg, rpl


def sol_at(t, t0):
    """Sol walks north from (83, -17) toward the fight, as in the director log (15:14:10 to 15:15:28)."""
    return {"name": "sol", "alive": True, "position": {"x": 83 - (t - t0) * 0.1, "y": -17 - (t - t0) * 0.5}}


def on_sol(now):
    return {"main": {"agents": ["sol"], "frame": {"follow": "sol", "zoom": 1.42, "frac": FRAC}}}


def run(rpl, seg, t0, t1, cams, losses, extra_fights=()):
    """One tick a second; the loss entry (as live.py reports it) from its first loss on."""
    for t in range(t0, t1):
        f = {"key": "loss:75,-55", "kind": "loss", "text": LOSS_TEXT, "position": SITE, "first": t0,
             "last": t, "losses": [x for x in losses if x <= t]}
        snap = {"agents": [sol_at(t, t0)], "fights": ([f] if any(x <= t for x in losses) else []) + list(extra_fights),
                "alerts": []}
        seg.step(snap, t)
        rpl.tick(snap, cams(t), t)
        rpl.work(t)


def geometry():
    from director import in_frame
    fr = {"follow": "sol", "zoom": 1.42, "frac": FRAC}
    by = {"sol": {"position": {"x": 83, "y": -30}}}
    assert in_frame(fr, {"x": 83, "y": -30}, by)
    assert not in_frame(fr, SITE, by)  # 25 tiles north: the frame reaches 11.9 (less a 2-tile edge)
    assert in_frame(fr, {"x": 83, "y": -39.5}, by) and not in_frame(fr, {"x": 83, "y": -40.5}, by)
    assert not in_frame(fr, {"x": 83, "y": -30, "surface": "vulcanus"}, by)
    wide = {"position": {"x": 79, "y": -42}, "zoom": 0.66, "frac": FRAC}  # the 15:18:16 cut to the fight
    assert in_frame(wide, SITE, by)


def off_frame():
    seg, rpl = world()
    t = 10_000
    run(rpl, seg, t, t + 40, on_sol, losses=[t + 10])
    assert rpl.pending is None and rpl.clip is None and rpl.status["replays"] == 0, rpl.public()
    assert any("skipped loss: the program showed its spot never" in x for x in logs), logs[-3:]


def cut_to_it():
    """The director cuts to the fight 4 s after the alert: the clip starts at the cut."""
    seg, rpl = world()
    t = 20_000
    cut = t + 14
    fight = {"position": {"x": 79, "y": -42}, "surface": "nauvis", "zoom": 0.66, "frac": FRAC}
    cams = lambda now: on_sol(now) if now < cut else {"main": {"agents": [], "frame": fight}}  # noqa: E731
    run(rpl, seg, t, t + 24, cams, losses=[t + 10])  # judged at t + 23, not aired yet
    c = rpl.clip
    # from the cut to the end of the window (loss_watch after the loss, 2 s before its alert): 9 s
    assert c and (c["show_from"], c["show_to"]) == (cut, t + 8 + rpl.cfg["loss_watch"]), (c, logs[-3:])


def inset():
    seg, rpl = world()
    t = 30_000
    box = {"position": {"x": 75, "y": -55}, "surface": "nauvis", "zoom": 0.99, "frac": 1.0}
    cams = lambda now: dict(on_sol(now), inset={"agents": [], "frame": box}) if now >= t + 9 else on_sol(now)  # noqa: E731
    run(rpl, seg, t, t + 24, cams, losses=[t + 10])  # judged at t + 23, not aired yet
    c = rpl.clip
    assert c and c["show_from"] == t + 9 and c["show_to"] - c["show_from"] == rpl.cfg["loss_len"], c


def during_replay():
    seg, rpl = world()
    rpl.playing = "clip-9"
    rpl.tick({"agents": [], "fights": []}, {"main": {"agents": [], "frame": {"position": SITE, "zoom": 1, "frac": 1}}}, 5)
    assert not rpl.frames
    rpl.playing = None
    rpl.tick({"agents": [], "fights": []}, {"main": {"agents": [], "frame": {"position": SITE, "zoom": 1, "frac": 1}}}, 6)
    assert len(rpl.frames) == 1


def one_clip_per_fight():
    seg, rpl = world()
    t = 40_000
    box = {"position": {"x": 75, "y": -55}, "surface": "nauvis", "zoom": 0.8, "frac": FRAC}
    run(rpl, seg, t, t + 50, lambda now: {"main": {"agents": [], "frame": box}}, losses=[t + 10, t + 13, t + 16])
    assert rpl.status["replays"] == 1 and not rpl.more_clips and not rpl.more_pending, rpl.public()
    assert sum("inside the clip of the same fight" in x for x in logs) == 2, logs[-4:]


def seek():
    seg, rpl = world()
    t = 50_000
    box = {"position": {"x": 75, "y": -55}, "surface": "nauvis", "zoom": 0.8, "frac": FRAC}
    run(rpl, seg, t, t + 24, lambda now: {"main": {"agents": [], "frame": box}}, losses=[t + 10])
    c = rpl.clip
    assert c["saved_t"] == t + 8 + rpl.cfg["loss_watch"], c  # judged and saved once loss_watch is over
    rpl.play(c)
    # FakeOBS: a 45 s file that ends at saved_t; show_from 6 s before the loss, 21 s before saved_t
    assert rpl.obs.cursor == 45000 - (c["saved_t"] - c["show_from"]) * 1000 == 24000, rpl.obs.cursor
    assert "Replay_" not in open(rp.__file__).read()  # no box-local file-name times


def director_frame():
    sent = []
    slots = [{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}, {"slot": "cam3", "player": 5}]
    d = OneCam(slots, lambda body: sent.append(body) or {"ok": True}, None, view_frac=FRAC)
    sol = {"name": "sol", "alive": True, "position": {"x": 83, "y": -30}}
    d.state["main"] = {"agents": ["sol"], "follow": "sol", "subject": "sol", "zoom": 0.95, "game_zoom": 1.42}
    by = {"sol": sol}
    assert d.near_onair("sol", None, by)
    assert d.near_onair(None, {"x": 85, "y": -25}, by)
    assert not d.near_onair(None, SITE, by)  # shift01: 25 tiles away was "on air"; it is off frame
    fr = d.public()["main"]["frame"]
    assert fr == {"zoom": 1.42, "frac": FRAC, "follow": "sol"}, fr


def main():
    geometry()
    off_frame()
    cut_to_it()
    inset()
    during_replay()
    one_clip_per_fight()
    seek()
    director_frame()
    print("replay footage: ok (shown = inside the program's frame; off frame no clip; from the cut on; insets; "
          "one clip per fight; seek offset from the Mac clock; the director cuts or insets what is off frame)")


if __name__ == "__main__":
    main()
