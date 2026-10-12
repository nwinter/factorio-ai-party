#!/usr/bin/env python3
"""Which replay airs, and when (shake12: three replays within 41 s at 04:04, often of one pipe or one belt, and two
research completions with no card, the replay scene on air): python3 tools/stream/test_replay_selection.py

1. At least 90 s between replays; the same loss line airs once in 5 minutes (live.py re-reports a loss).
2. A single cheap building lost (pipe, belt, pole, inserter) airs only when nothing else has for a while, and gives
   way to a clip waiting behind it.
3. The research card and a fresh Space Age moment win over a routine replay: it is refused while they are up, and one
   queued or on air is cut. A death replay is not routine.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replays as rp  # noqa: E402
import segments as sg  # noqa: E402
from segments import Segments  # noqa: E402
from test_fight_replays import FakeOBS  # noqa: E402

rp.time.sleep = lambda s: None


class Clips:
    """replays.py as segments.py sees it: the waiting clip, its availability and facts."""
    def __init__(self, *labels):
        self.queue = [self.make(x) for x in labels]
        self.clip = self.queue[0] if self.queue else None

    @staticmethod
    def make(label):
        kind = "death" if label.endswith("died") else "loss"
        return {"id": label, "label": label, "kind": kind, "show_from": 0, "show_to": 10}

    def why(self, now=None):
        return None if self.clip else "no fresh clip"

    def facts(self, now):
        c = self.clip
        return {"event": c["label"], "kind": c["kind"], "seconds": 10, "ago_s": 0}, c["id"]

    def aired(self):  # what replays.py does once the clip is on air
        self.queue.pop(0)
        self.clip = self.queue[0] if self.queue else None


def world(*labels, **kw):
    seg = Segments(lull_after=1e9, **kw)
    seg.replays = Clips(*labels)
    seg.last_recap = 1e12  # no recap in these tests
    return seg


def offer(seg, now):
    return seg.request({"type": "attack_replay", "by": "director", "reason": "replay"}, now, ignore_spacing=True)


def play(seg, t0, t1, snap=None, offer_every=1):
    """One tick a second: replays.py offers its clip, segments steps. -> [(label, went live at)]."""
    out = []
    for t in range(t0, t1):
        if seg.replays.clip and t % offer_every == 0:
            offer(seg, t)
        before = seg.cur and seg.cur["state"]
        seg.step(snap or {}, t)
        cur = seg.cur
        if cur and cur["type"] == "attack_replay" and before == "starting" and cur["state"] == "live":
            out.append((cur["facts"]["event"], t))
            seg.replays.aired()
    return out


BIG = "26 lost near (-128, 38): 14 transport belt, 7 inserter (by medium biters)"
TURRET = "2 lost near (12, -66): 2 gun turret (by big biters)"
WALL = "3 lost near (-226, -93): 2 stone wall, 1 gun turret (by medium biters)"
PIPE = "1 lost near (39, 84): 1 pipe to ground (by flamethrower turrets)"
BELT = "1 lost near (-70, 62): 1 transport belt (by big spitters)"


def cheap():
    assert sg.cheap_loss(PIPE) and sg.cheap_loss(BELT)
    assert sg.cheap_loss("1 lost near (38, -57): 1 small electric pole (by small spitters)")
    assert sg.cheap_loss("1 lost near (-122, 39): 1 inserter (by medium biters)")
    assert sg.cheap_loss("1 lost near (1, 2): 1 fast inserter")
    assert not sg.cheap_loss("1 lost near (-101, -7): 1 gun turret (by big spitters)")
    assert not sg.cheap_loss("2 lost near (10, -66): 2 transport belt (by medium spitters)")  # more than one
    assert not sg.cheap_loss("1 lost near (-325, 64): 1 character (by medium worm turrets)")
    assert not sg.cheap_loss("Base under attack near (16, 80): flamethrower turret")
    assert sg.big_replay({"kind": "death", "label": "Luna died"})
    assert sg.big_replay({"kind": "loss", "label": "1 lost near (-325, 64): 1 character (by medium worm turrets)"})
    assert not sg.big_replay({"kind": "loss", "label": BIG})


def spacing():
    """Rule 1: shake12 04:04, three clips waiting at once."""
    seg = world(BIG, TURRET, WALL)
    aired = play(seg, 1000, 1400)
    assert [x for x, _ in aired] == [BIG, TURRET, WALL], aired
    gaps = [b - a for (_, a), (_, b) in zip(aired, aired[1:])]
    assert all(g >= 90 for g in gaps) and max(gaps) < 110, gaps
    code, rep = offer(world(TURRET), 1000)
    assert code == 200
    seg = world(TURRET, TURRET)  # the same loss, re-reported
    aired = play(seg, 1000, 1200)
    assert [x for x, _ in aired] == [TURRET], aired
    assert offer(seg, 1200) == (409, {"error": "declined", "why": "this loss already aired", "skip": True,
                                      "retry_after": 60})
    seg = world("Luna died", "Luna died")  # deaths are never repeats
    assert len(play(seg, 1000, 1300)) == 2


def cheap_waits():
    """Rule 2: one pipe after a segment started 60 s ago waits; with nothing on for 3 minutes it airs."""
    seg = world(PIPE)
    seg.last_start = 940
    code, rep = offer(seg, 1000)
    assert code == 409 and rep["skip"] and "cheap" in rep["why"], rep
    aired = play(seg, 1000, 1200)
    assert aired and aired[0][0] == PIPE and aired[0][1] >= 940 + 180, aired
    seg = world(BELT)
    seg.last_attack_cut = 990  # a fight on the main camera 10 s ago
    seg.last_start = 0
    assert offer(seg, 1025)[0] == 409 and offer(seg, 1051)[0] == 200
    # in replays.py: a cheap clip refused with another clip behind it is dropped, and the next one is offered
    seg = Segments(lull_after=1e9)
    rpl = rp.Replays(seg, obs=FakeOBS(), log=lambda *a: None, start=False)
    rpl.work(0)
    seg.last_start = 990
    rpl.clip = dict(Clips.make(PIPE), path="r1.mkv", saved_t=995, show_from=985, show_to=995)
    rpl.more_clips.append(dict(Clips.make(TURRET), id="t", path="r2.mkv", saved_t=995, show_from=985, show_to=995))
    rpl.offer(1000)
    assert rpl.clip["label"] == TURRET and seg.queue is None
    rpl.offer(1001)
    assert seg.queue and seg.queue["facts"]["event"] == TURRET
    rpl.clip = dict(Clips.make(PIPE), path="r3.mkv", saved_t=995, show_from=985, show_to=995)  # alone: it waits
    seg.queue = None
    rpl.offer(1002)
    assert rpl.clip["label"] == PIPE and seg.queue is None


def research_wins():
    """Rule 3: a technology finishes; the card (overlay research_news, 30 s) shows instead of a replay."""
    news = {"research_news": [{"name": "steel-processing", "label": "Steel processing", "t": 1000}]}
    seg = world(TURRET)
    seg.step(news, 1000)
    code, rep = offer(seg, 1001)
    assert code == 409 and rep["why"] == "the research card is up", rep
    assert play(seg, 1001, 1031, news) == []
    assert play(seg, 1031, 1040) and seg.cur["facts"]["event"] == TURRET  # card gone: the replay airs
    # a routine replay on air when a technology finishes is cut
    seg = world(TURRET)
    play(seg, 1000, 1005)
    assert seg.cur["state"] == "live"
    seg.step(news, 1006)
    assert seg.cur["state"] == "ended" and seg.cur["cut"] == "research" and seg.public()["cut"] == "research"
    seg.step(news, 1007)  # the same completion again: nothing more to cut
    # queued: dropped
    seg = world(TURRET)
    assert offer(seg, 1000)[0] == 200
    seg.step(news, 1000)
    assert seg.queue is None and seg.cur is None
    # a death replay is not routine: it airs over the card
    seg = world("Luna died")
    play(seg, 1000, 1005)
    seg.step(news, 1006)
    assert seg.cur["state"] == "live"
    seg = world("Luna died")
    seg.step(news, 1000)
    assert offer(seg, 1001)[0] == 200


def moment_wins():
    moment = {"id": "m1", "kind": "first_platform", "title": "First space platform", "t": 1000,
              "facts": {"platform": "Alpha"}}
    snap = {"space": {"active": True, "moments": [moment]}}
    seg = world(TURRET)
    play(seg, 1000, 1005)
    assert seg.cur["state"] == "live" and seg.cur["type"] == "attack_replay"
    seg.step(snap, 1006)  # cut, and the moment starts on the next tick
    seg.step(snap, 1007)
    assert seg.cur["type"] == "space_moment", seg.cur
    seg = world(TURRET)
    seg.snap = snap
    assert offer(seg, 999)[1]["why"] == "a Space Age moment goes first"
    seg.step(snap, 1000)  # the moment is asked for, then on air; the replay waits for it (busy), then airs
    seg.step(snap, 1001)
    assert seg.cur["type"] == "space_moment"
    ends = seg.cur["ends"]
    aired = play(seg, 1002, 1060, snap)
    assert aired and aired[0][1] >= ends, (aired, ends)


def main():
    cheap()
    spacing()
    cheap_waits()
    research_wins()
    moment_wins()
    print("replay selection: ok (90 s apart, no repeats, one cheap building only when quiet, research card and Space "
          "Age moments first)")


if __name__ == "__main__":
    main()
