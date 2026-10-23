#!/usr/bin/env python3
"""An agent resting between turns (operator 17:17: Gemini plays short turns with long sleeps to pace its weekly quota):
python3 tools/stream/test_pacing.py

1. pacing.resting reads runs/RUN/AGENT/resting.json (tools/agy-quota.py) while its until is ahead, and labels it.
2. The stream: live.py puts it on the agent row; model.py's card says "resting until 18:17 · pacing quota"
   (activity resting, not idle or offline), the hosts get it once as a fact (an alert of kind rest, a new one per rest),
   and the director does not pick the agent; once the rest ends it is an agent as before.
3. tools/idle_nudge.py sends no tell while the agent rests.
4. (d22 batch108 BR1, Grok's weekly limit at 20:04 Thursday, reset Sat 15:59) a rest of a non-agy agent written by
   tools/quota_rest.py: the card says "out of quota until Sat 15:59" (the day named when it ends on
   another day), the nudger skips it, and the agent's own request in its journal after the rest began ends it
   (describe and peeks do not).
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
        assert pacing.label(r, now) == "resting until " + pacing.clock(now + 4440, now) + " · pacing quota"
        assert pacing.resting(g, now + 5000) is None  # over
        write_rest(g, now - 60, now + 600, "quota")
        assert pacing.label(pacing.resting(g, now)).startswith("out of quota until ")
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


def req(at, action, args=None):
    iso = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(at))
    return json.dumps({"at": iso, "event": "request", "request": {"id": "x", "action": action, "bot": "grok",
                                                                   "args": args or {}}}, separators=(",", ":")) + "\n"


def grok():
    tz = os.environ.get("TZ")
    os.environ["TZ"] = "America/Los_Angeles"
    time.tzset()
    try:
        hit = time.mktime((2026, 10, 22, 20, 4, 0, 0, 0, -1))      # Thursday 20:04 PDT
        reset = time.mktime((2026, 10, 24, 15, 59, 0, 0, 0, -1))   # Sat 15:59
        assert pacing.clock(reset, hit) == "Sat 15:59" and pacing.clock(hit + 600, hit) == "20:14"
        row = {"since": hit, "until": reset, "reason": "quota"}
        assert pacing.label(row, hit) == "out of quota until Sat 15:59"
        assert pacing.label(row, reset - 3600) == "out of quota until 15:59"  # Saturday itself
    finally:
        if tz is None:
            os.environ.pop("TZ")
        else:
            os.environ["TZ"] = tz
        time.tzset()
    import quota_rest
    os.environ["POG_REST_PUSH"] = "off"
    try:
        with tempfile.TemporaryDirectory() as run:
            g = os.path.join(run, "grok")
            os.makedirs(g)
            now = time.time()
            # its journal: its last requests before the rest
            with open(os.path.join(g, "journal.jsonl"), "w") as j:
                j.write(req(now - 400, "status") + req(now - 300, "sleep"))
            old = now - 200
            os.utime(os.path.join(g, "journal.jsonl"), (old, old))
            line, ok = quota_rest.mark(g, now + 2 * 86400, "quota")
            assert ok and "resting until " in line and "not pushed: off" in line, line
            r = pacing.resting(g, now)
            assert r and r["reason"] == "quota" and r["resets"] == quota_rest.when(now + 2 * 86400), r
            lab = pacing.label(r, now)
            assert lab.startswith("out of quota until ") and lab.split()[4] in pacing.DAYS, lab
            m = Model({"agents": {"grok": {"display_name": "Grok"}}})
            m.ingest({"agents": [{"name": "grok", "display_name": "Grok", "alive": True, "position": {"x": 0, "y": 0},
                                  "resting": r}]}, now=now)
            card = m.snapshot(now)["agents"][0]
            assert card["activity"] == "resting" and card["action"] == pacing.label(r), card
            import idle_nudge
            n = idle_nudge.Nudger(members=["grok"], start=now - 3600, run_dir=run)
            assert n.due({"name": "grok", "alive": True, "standing_s": 3000, "counted": {"text": "x"}}, now) == lab
            # a relaunch's describe and a peek: still resting; its own status: over
            with open(os.path.join(g, "journal.jsonl"), "a") as j:
                j.write(req(r["since"] + 5, "describe") + req(r["since"] + 6, "chat", {"peek": True}))
            assert pacing.resting(g, now) is not None
            with open(os.path.join(g, "journal.jsonl"), "a") as j:
                j.write(req(r["since"] + 30, "status", {"brief": True}))
                j.write('{"at":"x","event":"response","response":{"ok":true}}\n')
            assert pacing.resting(g, now) is None
    finally:
        os.environ.pop("POG_REST_PUSH", None)
    print("grok (a quota rest of days): ok")


if __name__ == "__main__":
    reads()
    stream()
    nudge()
    grok()
    print("test_pacing: ok")
