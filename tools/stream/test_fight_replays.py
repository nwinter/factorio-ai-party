#!/usr/bin/env python3
"""Fight replays (shake10: the main camera showed a fight live, then the replay aired that same stretch while the
battle went on): python3 tools/stream/test_fight_replays.py

1. Never during the fight: a clip about a fight waits until it has been quiet 20 s; a death clip waits for a fight
   within 40 tiles.
2. A fight the main camera showed live gets no replay of it.
3. A loss: a clip from 8 s before the moment of loss to 3 s after, aired after the fight, if the camera on air showed
   the spot in the 15 s before it.
4. A fight only a side camera showed: that camera's stretch, aired after the fight; no camera, no replay.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replays as rp  # noqa: E402
from segments import Segments  # noqa: E402

rp.time.sleep = lambda s: None  # the fake OBS answers at once


class FakeOBS:
    def __init__(self):
        self.saved, self.program = 0, "stream"

    def call(self, req, data=None):
        if req == "GetSceneList":
            return {"scenes": [{"sceneName": "stream"}, {"sceneName": "replay"}]}
        if req == "GetInputList":
            return {"inputs": [{"inputName": "stream overlay"}, {"inputName": "replay clip"}, {"inputName": "replay banner"}]}
        if req == "GetSceneItemList":
            return {"sceneItems": [{"sourceName": "replay clip"}, {"sourceName": "replay banner"}, {"sourceName": "stream overlay"}]}
        if req == "GetReplayBufferStatus":
            return {"outputActive": True}
        if req == "SaveReplayBuffer":
            self.saved += 1
        if req == "GetLastReplayBufferReplay":
            if not self.saved:
                raise rp.OBSError("no replay yet")
            return {"savedReplayPath": f"r{self.saved}.mkv"}
        if req == "GetMediaInputStatus":
            return {"mediaDuration": 45000}
        if req == "SetCurrentProgramScene":
            self.program = data["sceneName"]
        if req == "GetCurrentProgramScene":
            return {"currentProgramSceneName": self.program}
        if req == "CreateSceneItem":
            return {"sceneItemId": 1}
        return {}


FIGHT = {"key": "area:290,0", "kind": "attack", "text": "Base under attack near (290, 0): gun turret",
         "position": {"x": 290, "y": 0, "extent": 32.0, "surface": "nauvis"}}
AGENTS = [{"name": "astra", "position": {"x": 0, "y": 0}, "alive": True},      # at the factory
          {"name": "luna", "position": {"x": 300, "y": 5}, "alive": True}]     # at the fight


def world():
    seg = Segments(spacing=0)
    rpl = rp.Replays(seg, obs=FakeOBS(), log=lambda *a: logs.append(" ".join(map(str, a))), start=False)
    rpl.work(0)  # connect, scene ready
    return seg, rpl


logs = []


def run(seg, rpl, t0, t1, fight_until, cams, losses=(), agents=AGENTS, extra=None):
    """One tick a second from t0 to t1: the fight is reported until fight_until; returns the clip labels aired."""
    aired = []
    for t in range(int(t0), int(t1)):
        f = dict(FIGHT, last=min(t, fight_until), first=t0, losses=[x for x in losses if x <= t])
        snap = {"agents": agents, "fights": [f] if t >= t0 else [], "alerts": []}
        if extra:
            snap["fights"] += extra(t)
        seg.step(snap, t)
        rpl.tick(snap, cams(t), t)
        rpl.work(t)
        if rpl.playing and rpl.playing not in [c for _, _, c in aired]:
            aired.append((rpl.status["last"]["label"], t, rpl.playing))
        if seg.cur and seg.cur["type"] == "attack_replay" and seg.cur["state"] in ("starting", "live"):
            assert t - fight_until >= rpl.cfg["quiet_s"], f"a replay went on air during the fight (t={t})"
    aired = [(label, when) for label, when, _ in aired]
    return aired


def main_watched():
    """Rules 1-3: the main camera on the fight live; a turret destroyed at t+10."""
    seg, rpl = world()
    t = 1000
    on_fight = lambda now: {"main": {"agents": [], "fight": FIGHT["key"]}, "cam2": {"agents": ["astra"]}}  # noqa: E731
    aired = run(seg, rpl, t, t + 40, t + 40, on_fight)
    assert aired == [] and rpl.pending is None and rpl.clip is None, (aired, rpl.pending, logs[-3:])  # rule 2
    seg, rpl = world()
    aired = run(seg, rpl, t, t + 100, t + 40, on_fight, losses=[t + 10])
    assert len(aired) == 1, (aired, logs[-5:])
    label, when = aired[0]
    assert label == FIGHT["text"] and when >= t + 40 + rpl.cfg["quiet_s"], aired  # rule 1: after 20 s of quiet
    last = rpl.status["last"]
    # rule 3: the loss's moment (alert at t+10, about 2 s after it happened): 8 s before to 3 s after
    assert rpl.status["replays"] == 1 and "r1.mkv" in last["path"]
    clip_log = [x for x in logs if "pending loss" in x]
    assert clip_log, logs[-8:]
    seg, rpl = world()
    t_loss = t + 10 - rpl.cfg["loss_lag"]
    run(seg, rpl, t, t_loss + 5, t + 40, on_fight, losses=[t + 10])  # judged and saved once its clip's end is over
    c = rpl.clip  # saved, waiting for the fight to end
    assert (c["show_from"], c["show_to"], c["saved_t"]) == (t_loss - 8, t_loss + 3, t_loss + 4) and c["fight"] == FIGHT["key"], c
    assert seg.queue is None and rpl.why(t_loss + 5).startswith("the fight is still going on")


def loss_alert_lingers():
    """As live.py reports it: the loss is its own entry (loss:x,y), re-reported for ~2 minutes; the clip waits for the
    attack around it to go quiet, not for the loss alert."""
    seg, rpl = world()
    t = 1500
    on_fight = lambda now: {"main": {"agents": [], "fight": FIGHT["key"]}}  # noqa: E731
    loss = lambda now: [{"key": "loss:288,-4", "kind": "loss", "text": "3 lost near (288, -4): gun turret",  # noqa: E731
                         "position": {"x": 292, "y": 0, "extent": 16.0, "surface": "nauvis"}, "first": t + 10,
                         "last": now, "losses": [t + 10]}] if now >= t + 10 else []
    aired = run(seg, rpl, t, t + 100, t + 40, on_fight, extra=loss)
    assert [a for a, _ in aired] == ["3 lost near (288, -4): gun turret"], (aired, logs[-6:])
    assert t + 60 <= aired[0][1] < t + 75, aired  # after the attack's 20 s of quiet, not the loss alert's 2 minutes


def side_only():
    """Rule 4: only cam2 (following Luna at the fight) showed it; the main camera was on Astra at the factory."""
    seg, rpl = world()
    t = 2000
    cams = lambda now: {"main": {"agents": ["astra"]}, "cam2": {"agents": ["luna"]}}  # noqa: E731
    aired = run(seg, rpl, t, t + 90, t + 30, cams)
    assert [a for a, _ in aired] == [FIGHT["text"]] and aired[0][1] >= t + 50, (aired, logs[-6:])
    # nobody near the fight on any camera: no replay
    seg, rpl = world()
    far = [dict(AGENTS[0]), dict(AGENTS[1], position={"x": -400, "y": 0})]
    aired = run(seg, rpl, t, t + 90, t + 30, cams, losses=[t + 5], agents=far)
    assert aired == [] and rpl.clip is None and any("skipped loss" in x for x in logs), (aired, logs[-4:])


def death_waits():
    """Rule 1 for deaths: Luna dies at the fight on the main camera; the death clip airs once the fight is quiet."""
    seg, rpl = world()
    t = 3000
    cams = lambda now: {"main": {"agents": ["luna"]}}  # noqa: E731
    for k in range(12):  # the main camera on Luna before she dies
        rpl.tick({"agents": AGENTS, "fights": []}, cams(t + k), t + k)
    rpl.on_attack_cut({"kind": "death", "agent": "luna", "text": "Luna died"}, {"agents": AGENTS}, t + 12)
    seg.last_attack_cut = t - 100
    aired = run(seg, rpl, t + 13, t + 90, t + 40, cams)
    assert [a for a, _ in aired] == ["Luna died"] and aired[0][1] >= t + 60, (aired, logs[-6:])


def main():
    main_watched()
    loss_alert_lingers()
    side_only()
    death_waits()
    print("fight replays: ok (none while the fight goes on, none of what main showed live, loss clips, side-camera clips)")


if __name__ == "__main__":
    main()
