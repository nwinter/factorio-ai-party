#!/usr/bin/env python3
"""Speech-linked framing and still agents' remote work (d28 batch324 SF, viewer Aurora 16:46, site:5414-5415), one client
with two camera panels (the live slots): python3 tools/stream/test_speechframe.py

Speech (onecam maybe_speech, speech_*):
1. A host line naming an agent (its event's facts, caster.subjects_of) while another story has been up speech_min:
   one cut to it, held while the line plays (the still rules wait), and the hold ends with the playback.
2. A line about the agent on air: held, no cut.
3. The main view busy (a fight on air): the subject in a panel inset until the line ends; a line that stops early
   takes its inset with it.
4. Two subjects: a cut to the first, the second in a panel beside it; a third is not shown (one cut a line).
5. The same subject again within speech_merge: no second cut; a tour on air keeps the camera (inset instead).
6. Unknown names are skipped; an Operator line's own names (an agent, a platform) count.
Remote work (maybe_swap, swap_*):
7. The agent on air stands still while its attention inset shows where it works: after swap_still the work goes on
   the main view and the agent into a panel; back to the agent after swap_hold, or at once when it acts again.
8. caster.subjects_of: the event's agent and platform fields (also nested), never words of the line.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from onecam import OneCam  # noqa: E402
from test_onecam import agent  # noqa: E402
from test_platformcam import VIEW, plat  # noqa: E402

PANELS = [{"slot": "main", "player": 1},
          {"slot": "cam2", "player": 1, "panel": 1, "rect": [2388, 0, 492, 277], "scale": 0.171},
          {"slot": "cam3", "player": 1, "panel": 2, "rect": [0, 0, 492, 277], "scale": 0.171}]
T = 1000


def director(**cfg):
    d = OneCam(PANELS, lambda body: {"ok": True}, None,
               **dict({"trio": False, "map_every": 0, "platform_every": 0, "bow": False, "stories": False,
                       "attention": False, "quiet_story": 1e9, "tour_every": 0}, **cfg))
    d.started = 0
    return d


def team(**kw):
    a = [agent("luna", 0, 0, 5), agent("sol", 300, 0, 3), agent("astra", -300, 0, 2)]
    for x in a:
        x.update(kw.get(x["name"], {}))
    return a


def snap(agents, speech=(), plats=()):
    return {"agents": agents, "alerts": [], "speech": list(speech), "space": {"platforms": list(plats)}}


def line(i, started, dur, subjects, channel="caster", **kw):
    return dict({"id": f"c{i}", "channel": channel, "speaker": "Rook", "started": started, "duration": dur,
                 "subjects": subjects}, **kw)


def main_subj(d):
    return (d.state.get(d.onair) or {}).get("subject")


def warm(d, a, k1=40):
    for k in range(0, k1):
        d.step(snap(a), T + k)
    assert main_subj(d) == "luna", main_subj(d)


def cut_and_hold():
    d = director()
    a = team()
    warm(d, a)
    ln = line(1, T + 40, 10.0, [{"agent": "Sol"}])
    for k in range(40, 50):
        d.step(snap(a, [ln]), T + k)
    assert main_subj(d) == "sol" and d.speeches[-1][2] == "cut", d.speeches
    cuts = [c for c in d.cuts if c[0] >= T + 40]
    assert len(cuts) == 1 and cuts[0][2].startswith("speech: Rook: sol"), cuts
    for k in range(50, 53):
        d.step(snap(a), T + k)  # the line ended
    assert d.speech is None
    print("1. a host line about another agent: one cut, held while it plays, over with the playback: ok")
    # 2. a line about the agent on air: held, no cut
    d = director()
    warm(d, a)
    n = len(d.cuts)
    still = team(luna={"activity": "idle", "active": None})
    for k in range(40, 80):
        d.step(snap(still, [line(2, T + 40, 40.0, [{"agent": "luna"}])]), T + k)
    assert len(d.cuts) == n and main_subj(d) == "luna" and d.speeches[-1][2] == "hold", (d.cuts[n:], d.speeches)
    print("2. a line about the agent on air: held, no cut: ok")


def busy_inset():
    d = director()
    a = team()
    warm(d, a)
    fight = team(luna={"combat": True})
    ln = line(3, T + 40, 20.0, [{"agent": "sol"}])
    d.step(snap(fight, [ln]), T + 40)
    assert main_subj(d) == "luna" and d.inset and d.inset["why"] == "speech", (main_subj(d), d.inset, d.speeches)
    assert d.state[d.inset["slot"]]["subject"] == "sol" and d.slot(d.inset["slot"]).get("panel")
    d.step(snap(fight), T + 44)  # the line stopped early: its inset goes too
    assert not d.inset and d.speech is None, d.inset
    print("3. the main view busy: the subject in a panel until the line ends (early stop: at once): ok")


def topics_merge_tour():
    d = director()
    a = team()
    warm(d, a)
    n = len(d.cuts)
    ln = line(4, T + 40, 12.0, [{"agent": "sol"}, {"agent": "astra"}, {"platform": "Starling"}])
    d.step(snap(a, [ln], [plat()]), T + 40)
    assert main_subj(d) == "sol" and d.inset and d.state[d.inset["slot"]]["subject"] == "astra", (main_subj(d), d.inset)
    assert len(d.cuts) == n + 1, d.cuts[n:]  # one cut for three names
    for k in range(41, 120):
        d.step(snap(a, [], [plat()]), T + k)
    m = len(d.cuts)
    d.step(snap(a, [line(5, T + 120, 8.0, [{"agent": "sol"}])], [plat()]), T + 120)
    assert d.speeches[-1][2] in ("hold", "inset", "drop") and len(d.cuts) == m, (d.speeches[-1], d.cuts[m:])
    print("4/5. three subjects: one cut and one comparison inset; the same subject again within speech_merge: no cut: ok")
    # a tour on air keeps the camera
    d = director()
    warm(d, a)
    cur = d.state[d.onair]
    cur.update(subject="@tour", until=T + 200, position={"x": 0, "y": 0})
    d.step(snap(a, [line(6, T + 40, 8.0, [{"agent": "sol"}])]), T + 40)
    assert main_subj(d) == "@tour" and d.speeches[-1][2] == "inset" and "tour held" in d.speeches[-1][3], d.speeches[-1]
    print("5. a tour on air keeps the camera: the subject in a panel: ok")


def verified():
    d = director()
    a = team()
    warm(d, a)
    n = len(d.speeches)
    d.step(snap(a, [line(7, T + 40, 8.0, [{"agent": "Zed"}, {"platform": "Nowhere"}])]), T + 40)
    assert len(d.speeches) == n and main_subj(d) == "luna", d.speeches[n:]
    v = {"id": "o1", "channel": "operator", "speaker": "Operator", "text": "Starling is back and Sol fixed it",
         "started": T + 41, "duration": 6.0}
    d.plat_rows = {"Starling": plat()}
    assert d.speech_subjects(v, {x["name"]: x for x in a}) == [("platform", "Starling"), ("agent", "sol")]
    print("6. unknown names skipped; an Operator line's own names count, in its order: ok")


def swap():
    d = director(attention=True)
    a = team()
    warm(d, a)
    att = {"far": True, "age_s": 2, "kind": "looking", "text": "inspecting 80 m north", "position": {"x": 0, "y": -80},
           "surface": "nauvis"}
    still = team(luna={"activity": "idle", "active": None, "attention": att})
    k0 = None
    for k in range(40, 120):
        d.step(snap(still), T + k)
        if main_subj(d) == "@work":
            k0 = k
            break
    assert k0 is not None and d.swaps and d.swaps[-1][1] == "luna", (d.swaps, d.attns, d.inset)
    assert d.inset and d.inset["why"] == "away" and d.state[d.inset["slot"]]["subject"] == "luna", d.inset
    assert d.public(T + k0)["main"].get("work") == "Luna inspecting 80 m north", d.public(T + k0)["main"]
    for k in range(k0 + 1, k0 + 40):
        d.step(snap(still), T + k)
        if main_subj(d) != "@work":
            break
    # over after swap_hold: back to the story (or on, by the still rules: Luna still stands, Sol moves)
    assert main_subj(d) in ("luna", "sol", "astra") and k - k0 <= d.cfg["swap_hold"] + 2, (k - k0, main_subj(d))
    # acting again ends it at once
    d = director(attention=True)
    warm(d, a)
    for k in range(40, 120):
        d.step(snap(still), T + k)
        if main_subj(d) == "@work":
            break
    moving = team(luna={"attention": att, "position": {"x": 30, "y": 0}})
    for j in range(1, 4):
        d.step(snap(moving), T + k + j)
    assert main_subj(d) == "luna", main_subj(d)
    print(f"7. a still agent's remote work on the main view after {d.cfg['swap_still']:g} s, the agent in a panel; back "
          "after swap_hold (to the story or on) or when it moves: ok")


def subjects():
    import caster
    assert caster.subjects_of({"arrival": {"platform": "Anvil", "planet": "Nauvis"}}) == [{"platform": "Anvil"}]
    assert caster.subjects_of({"agents": ["Sol", "Luna"]}, {"agent": "sol"}) == [{"agent": "sol"}, {"agent": "Sol"}, {"agent": "Luna"}]
    assert caster.subjects_of({"text": "Sol and Anvil", "what_happened": "Rocket launched"}) == []
    print("8. caster.subjects_of: the event's own agent and platform fields only: ok")


def main():
    cut_and_hold()
    busy_inset()
    topics_merge_tour()
    verified()
    swap()
    subjects()
    print("speechframe: ok")


if __name__ == "__main__":
    main()
