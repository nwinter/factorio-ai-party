#!/usr/bin/env python3
"""An agent resting between turns (operator 17:17: Gemini plays short turns with long sleeps to pace its weekly quota):
python3 tools/stream/test_pacing.py

1. pacing.resting reads runs/RUN/AGENT/resting.json (tools/agy-quota.py) while its until is ahead, and labels it.
2. The stream: live.py puts it on the agent row; model.py's card says "resting until 18:17 · pacing its weekly quota"
   (activity resting, not idle or offline), the hosts get it once as a fact (an alert of kind rest, a new one per rest),
   and the director does not pick the agent; once the rest ends it is an agent as before.
3. tools/idle_nudge.py sends no tell while the agent rests.
"""
import json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import pacing  # noqa: E402
from model import Model  # noqa: E402
from test_onecam import agent, world  # noqa: E402


def write_rest(d, since, until, reason="pace"):
    os.makedirs(d, exist_ok=True)
    json.dump({"since": since, "until": until, "reason": reason, "sleep_s": until - since, "used": 89.0,
               "resets": "Sun 12:51"}, open(os.path.join(d, "resting.json"), "w"))


def reads():
    with tempfile.TemporaryDirectory() as run:
        g = os.path.join(run, "gemini")
        now = time.time()
        assert pacing.resting(g) is None
        write_rest(g, now - 60, now + 4440)
        r = pacing.resting(g, now)
        assert r and r["reason"] == "pace", r
        assert pacing.label(r) == "resting until " + time.strftime("%H:%M", time.localtime(now + 4440)) + " · pacing its weekly quota"
        assert pacing.resting(g, now + 5000) is None  # over
        write_rest(g, now - 60, now + 600, "quota")
        assert pacing.label(pacing.resting(g, now)).startswith("waiting until ") and "for its quota to reset" in pacing.label(pacing.resting(g, now))
        open(os.path.join(g, "resting.json"), "w").write("{broken")
        assert pacing.resting(g, now) is None
    print("reads: ok")


def stream():
    with tempfile.TemporaryDirectory() as run:
        g = os.path.join(run, "gemini")
        now = time.time()
        write_rest(g, now - 60, now + 4440)
        # live.py: each agent row carries pacing.resting of runs/RUN/AGENT (its journals folder is the run folder)
        assert 'a["resting"] = pacing.resting(os.path.join(self.journals, name))' in open(os.path.join(HERE, "live.py")).read()
        m = Model({"agents": {"gemini": {"display_name": "Gemini"}, "sol": {}}})
        rest = pacing.resting(g, now)
        row = {"name": "gemini", "display_name": "Gemini", "alive": True, "position": {"x": 0, "y": 0}, "resting": rest}
        m.ingest({"agents": [row, {"name": "sol", "alive": True, "position": {"x": 5, "y": 5}, "active": "walk", "resting": None}]}, now=now)
        snap = m.snapshot(now)
        gem = next(a for a in snap["agents"] if a["name"] == "gemini")
        assert gem["activity"] == "resting" and gem["action"] == pacing.label(rest), gem
        assert gem["resting_until"] == rest["until"]
        rests = [a for a in m.alerts if a["kind"] == "rest"]
        assert len(rests) == 1 and rests[0]["text"] == "Gemini is " + pacing.label(rest), rests
        m.ingest({"agents": [row]}, now=now + 20)  # the same rest: no second fact
        assert len([a for a in m.alerts if a["kind"] == "rest"]) == 1
        # the director: the resting agent is no pick, the other one is
        d, _ = world()
        scores = d.scores(snap["agents"], now)
        assert "gemini" not in scores and "sol" in scores, scores
        # the rest ends: an agent as before
        later = now + 4500
        m.ingest({"agents": [dict(row, resting=None)]}, now=later)
        gem = next(a for a in m.snapshot(later)["agents"] if a["name"] == "gemini")
        assert gem["activity"] != "resting" and gem["resting_until"] is None, gem
        # a new rest: a new fact
        rest2 = dict(rest, since=later, until=later + 3600)
        m.ingest({"agents": [dict(row, resting=rest2)]}, now=later)
        assert len([a for a in m.alerts if a["kind"] == "rest"]) == 2
    print("stream: ok")


def nudge():
    import idle_nudge
    with tempfile.TemporaryDirectory() as run:
        now = time.time()
        write_rest(os.path.join(run, "gemini"), now - 60, now + 4440)
        r = idle_nudge.Nudger(members=["gemini"], start=now - 3600, run_dir=run)
        row = {"name": "gemini", "alive": True, "standing_s": 3000, "counted": {"text": "x"}}
        why = r.due(row, now)
        assert why and why.startswith("resting until"), why
        os.remove(os.path.join(run, "gemini", "resting.json"))
        assert r.due(row, now) is None
    print("idle nudge: ok")


if __name__ == "__main__":
    reads()
    stream()
    nudge()
    print("test_pacing: ok")
