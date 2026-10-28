#!/usr/bin/env python3
"""An engineering highlight from captured footage (d28 batch312 C, viewer Aurora 10:50): python3 tools/stream/test_highlight.py

1. onecam: the main row says a build's close-up is on air (work_close: the ship, the agent, since when), from the move
   to the work (not during the whole-ship overview), with one client and camera panels.
2. replays.py: that close-up on air highlight_min_s is saved from the OBS buffer (from 1 s before it, highlight_len, or
   less when the shot ends sooner) and kept, not aired; a story result that passed on that ship later puts it on air
   as a replay labelled "Highlight: <the build>, then <the result>", the banner tag "Replay · highlight" and minutes
   ago, the hosts told the payoff; a failed result or another ship's does not; one highlight per highlight_gap, each
   once; an attack cut ends it (segments.attack_cut) and the program goes back to the stream.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replays as rp  # noqa: E402
from segments import Segments  # noqa: E402
from test_fight_replays import FakeOBS  # noqa: E402
import test_buildclose as B  # noqa: E402

rp.time.sleep = lambda s: None
logs = []


def director_row():
    from onecam import OneCam
    from test_onecam import agent
    from test_platformcam import plat, snap, main_row
    slots = [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 1, "panel": 1, "rect": [0, 0, 10, 10], "scale": 0.2}]
    d = OneCam(slots, lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0)
    d.started = 0
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 1)]
    for k in range(0, 22):
        d.step(snap(a, [plat(view=B.BIG)]), B.T + k)
    w = B.build("sol", B.T + 22)
    rows = []
    for k in range(22, 50):
        d.step(snap(a, [plat(view=B.BIG)], work=[w]), B.T + k)
        r = main_row(d, B.T + k)
        if (r.get("platform") or {}).get("why") == "work":
            rows.append((k, r.get("work_close")))
    over = [k for k, wc in rows if wc is None]
    close = [(k, wc) for k, wc in rows if wc]
    assert over and close and max(over) < close[0][0], rows[:8]
    k, wc = close[0]
    assert wc["platform"] == "Starling" and wc["agent"] == "sol" and wc["since"] == B.T + k, wc
    print(f"1. the director's main row: work_close from the move to the work ({len(over)} s of whole ship before it): ok")


def world():
    seg = Segments(spacing=0)
    obs = FakeOBS()
    rpl = rp.Replays(seg, obs=obs, log=lambda *a: logs.append(" ".join(map(str, a))), start=False)
    rpl.work(0)
    return seg, rpl, obs


LABEL = "Sol placing 5 ghosts (3 assembling machine 2, 2 inserter) on Resolute · near the stern, starboard side"


def cams(since, platform="Resolute"):
    return {"main": {"agents": ["sol"], "work": LABEL, "platform": {"name": platform, "why": "work"},
                     "work_close": {"platform": platform, "agent": "sol", "since": since}}}


def step(seg, rpl, t, c, stories=()):
    snap = {"agents": [], "fights": [], "alerts": [], "stories": list(stories)}
    seg.step(snap, t)
    rpl.tick(snap, c, t)
    rpl.work(t)


def result(t, platform="Resolute", verdict="passed", key="astra:flight#1585:result"):
    return {"key": key, "beat": "result", "platform": platform, "agent": "astra", "t": t, "verdict": verdict,
            "caption": "Resolute flight watch · Passed: arrived at aquilo, nothing lost during the watch (Astra's read of the watch)"}


def highlight():
    seg, rpl, obs = world()
    t0 = 1000
    for t in range(t0, t0 + 20):  # the close-up on air 20 s
        step(seg, rpl, t, cams(t0))
    assert obs.saved == 1 and len(rpl.hl_saved) == 1 and rpl.clip is None, (obs.saved, rpl.hl_saved, rpl.clip)
    c = rpl.hl_saved[0]
    assert c["show_from"] == t0 - 1 and c["show_to"] == t0 - 1 + 12 and c["label"] == LABEL, c
    # a shot that ends sooner: the clip ends with it
    for t in range(t0 + 100, t0 + 108):
        step(seg, rpl, t, cams(t0 + 100, platform="Kestrel"))
    for t in range(t0 + 108, t0 + 112):
        step(seg, rpl, t, {"main": {"agents": ["astra"]}})
    k = [x for x in rpl.hl_saved if x["platform"] == "Kestrel"]
    assert k and k[0]["show_to"] == t0 + 108, list(rpl.hl_saved)
    # results: a failed one and another ship's do nothing; a pass on Resolute airs it
    for t in range(t0 + 200, t0 + 210):
        step(seg, rpl, t, {"main": {"agents": ["astra"]}}, [result(t0 + 200, verdict="failed", key="a:1:result"),
                                                           result(t0 + 200, platform="Lark", key="a:2:result")])
    assert rpl.clip is None and seg.cur is None, (rpl.clip, seg.cur)
    t1 = t0 + 900
    on = cur = None
    for t in range(t1, t1 + 30):
        step(seg, rpl, t, {"main": {"agents": ["astra"]}}, [result(t1)])
        if on is None and obs.program == "replay":
            on, cur = t, seg.cur
            break
    assert on is not None and cur, logs[-6:]
    f = cur["facts"]
    assert cur["type"] == "attack_replay" and f["kind"] == "highlight" and f["payoff"].startswith("Resolute flight watch · Passed"), cur
    assert f["highlight"] == LABEL and cur["title"] == f"Replay: Highlight: {LABEL}, then {f['payoff']}", cur["title"]
    assert f["ago_s"] >= 880, f  # minutes ago on the banner
    import caster
    cf = caster.card_facts(cur)
    assert "payoff" in cf["how_to_call_it"] and cf["on_screen_now"]["payoff"] == f["payoff"], cf
    html = open(os.path.join(HERE, "static", "replay.html")).read()
    assert '"Replay · highlight"' in html and '" min ago"' in html
    # an attack cut ends it; back to the stream
    seg.attack_cut(on + 3)
    step(seg, rpl, on + 4, {"main": {"agents": ["astra"]}}, [result(t1)])
    assert obs.program == "stream" and seg.cur["cut"] == "attack", (obs.program, seg.cur)
    # one per highlight_gap, each once: Kestrel's pass 5 min later is not aired; the same result again neither
    for t in range(on + 300, on + 320):
        step(seg, rpl, t, {"main": {"agents": ["astra"]}}, [result(t1), result(on + 300, platform="Kestrel", key="k:1:result")])
    assert obs.program == "stream" and rpl.clip is None and any("less than 20 min ago" in x for x in logs), logs[-4:]
    print(f"2. a build close-up saved from the buffer and kept; aired as 'Highlight: ..., then ...' when its ship's watch "
          f"passed {t1 - t0} s later ({f['ago_s'] // 60} min ago on the banner), the payoff for the hosts; failed or other "
          f"ships' results, a second within 20 min: not aired; an attack cut ends it: ok")


if __name__ == "__main__":
    director_row()
    highlight()
    print("highlight: ok")
