#!/usr/bin/env python3
"""Job cards from each agent's board_focus, with its age and a labelled fallback (d20 batch54 N3, viewer Aurora,
shift47 13:39: "Old plan text still shows manual top-ups or availability after assignments change"):
python3 tools/stream/test_jobcard.py

1. Model.job_card: the focus (with its step and blocker) labelled "focus, set N ago"; no focus: the plan line labelled
   "plan line, set N ago; no focus set"; then the notes.md Now line with the file's age; neither: said so. A runtime
   with no focus rows: the plan line without "no focus set".
2. live.py read_focus: the board_focus read's rows; a runtime without rows or the action is not asked again.
3. push_live sends job_label, job_age_s and job_tick; the overlay card draws the label.
"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
from model import Model, fmt_age  # noqa: E402

H = 3600 * 60  # an hour of game ticks


def model():
    m = Model({"agents": {"astra": {"model": "gpt"}, "sol": {"model": "x"}, "haiku": {"model": "y"}, "luna": {"model": "z"}}})
    now = time.time()
    m.ingest({"agents": [{"name": "astra"}, {"name": "sol"}, {"name": "haiku", "notes_job": "Keep burners fuelled", "notes_job_t": now - 720},
                         {"name": "luna"}], "tick": 10 * H}, now)
    m.tick = 10 * H
    plan = {"goals": "Reach the edge", "doing": ["astra: manual top-ups at Fulgora (set by astra)", "sol: available for any request"],
            "lines": [{"agent": "astra", "tick": 8 * H}, {"agent": "sol", "tick": 10 * H - 300 * 60, "by": "astra"}]}
    focus = [{"agent": "astra", "id": 1355, "title": "Steel line coal", "step": "step 2 coal filter at x 53 (done)", "blocker": "no coal on the trunk",
              "tick": 10 * H - 5 * 3600}]
    m.ingest({"board": {"items": [], "plan": plan, "focus": focus}}, now)
    rows = {a["name"]: a for a in m.snapshot(now)["agents"]}
    a = rows["astra"]
    assert (a["job"], a["job_from"], a["job_label"], a["job_age_s"]) == (
        "#1355 Steel line coal; step 2 coal filter at x 53 (done); blocker: no coal on the trunk", "focus", "focus, set 5 min ago", 300), a
    s = rows["sol"]
    assert (s["job"], s["job_from"], s["job_label"]) == ("available for any request", "plan", "plan line, set 5 min ago; no focus set"), s
    h = rows["haiku"]
    assert (h["job"], h["job_from"], h["job_label"]) == ("Keep burners fuelled", "notes", "notes.md Now line, saved 12 min ago; no focus set"), h
    l = rows["luna"]
    assert (l["job"], l["job_from"], l["job_label"]) == (None, None, "no focus, plan line or notes job"), l
    # a stale plan line: its age, two hours
    focus[:] = []
    m.ingest({"board": {"items": [], "plan": plan, "focus": focus}}, now)
    a = {r["name"]: r for r in m.snapshot(now)["agents"]}["astra"]
    assert (a["job"], a["job_label"]) == ("manual top-ups at Fulgora", "plan line, set 2 h ago; no focus set"), a
    # a runtime whose board_focus read has no rows: the focus is unknown, not "no focus set"
    m.ingest({"board": {"items": [], "plan": plan, "focus": None}}, now)
    rows = {r["name"]: r for r in m.snapshot(now)["agents"]}
    assert rows["astra"]["job_label"] == "plan line, set 2 h ago", rows["astra"]
    assert rows["luna"]["job_label"] == "no plan line or notes job", rows["luna"]
    # a focus on an item gone from the board, its tick unknown
    m.ingest({"board": {"items": [], "plan": plan, "focus": [{"agent": "luna", "id": 9}]}}, now)
    l = {r["name"]: r for r in m.snapshot(now)["agents"]}["luna"]
    assert (l["job"], l["job_label"]) == ("#9 (item gone)", "focus, age unknown"), l
    assert [fmt_age(x) for x in (40, 89, 720, 7200, 8100)] == ["40 s", "89 s", "12 min", "2 h", "2 h 15 min"]


def live_focus():
    from live import LiveSource as Live

    class Fake:
        focus_ok = None
        def __init__(self, reply): self.reply, self.calls = reply, 0
        def reader(self): return {"bot": "astra"}
        def read(self, action, args=None, **who):
            assert action == "board_focus" and args == {}, (action, args)
            self.calls += 1
            if isinstance(self.reply, Exception):
                raise self.reply
            return self.reply, {}
    rows = [{"agent": "sol", "id": 7, "tick": 60}]
    f, errors = Fake({"focus": ["sol focus (set 0s ago): #7 x"], "rows": rows}), {}
    assert Live.read_focus(f, errors) == rows and f.focus_ok is True and not errors
    old = Fake({"focus": ["sol focus (set 0s ago): #7 x"]})
    assert Live.read_focus(old, errors) is None and old.focus_ok is False
    assert Live.read_focus(old, errors) is None and old.calls == 1, "not asked again"
    gone = Fake(RuntimeError("unknown action board_focus"))
    assert Live.read_focus(gone, errors) is None and gone.focus_ok is False and not errors
    flaky = Fake(RuntimeError("timeout"))
    assert Live.read_focus(flaky, errors) is None and flaky.focus_ok is None and errors["board_focus"] == "timeout"


def site_and_overlay():
    import push_live
    assert {"job", "job_from", "job_label", "job_age_s", "job_tick"} <= set(push_live.AGENT_KEYS)
    code = open(os.path.join(HERE, "static", "overlay.js")).read()
    assert 'el("span", "job-from", jobFrom ? jobFrom + ": " : "")' in code and "a.job_label" in code


def main():
    model()
    live_focus()
    site_and_overlay()
    print("job cards: ok (focus with its age, plan line and notes labelled with theirs, neither said; focus read; site keys)")


if __name__ == "__main__":
    main()
