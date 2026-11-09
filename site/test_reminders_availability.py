#!/usr/bin/env python3
"""Reminder availability, recorded cover vs request, result ages and held capacity.

Runs offline with a fixed clock: python3 site/test_reminders_availability.py
Exercises the model -> public state/full board -> actual live.js rendering path.
"""
import datetime
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import push_live
from test_reminders_schedule import JS_STUB
sys.path.insert(0, str(HERE.parent / "tools/stream"))
import model
import live
import pacing
import reminder_view

NOW = datetime.datetime.fromisoformat("2026-11-06T09:15:00-08:00").timestamp()
RUN = {"agents": {n: {"display_name": n.title()} for n in ("astra", "sol", "luna")}}


def render(state, doc=None, opened=False):
    code = (HERE / "static/live.js").read_text()
    code = code[code.index("  var openLong = {};"):code.index("  function projectsHtml(board, byName, card, withNext) {")]
    driver = """
lastState = STATE;
team = {};
lastState.agents.forEach(function(a) { team[a.name] = a; });
boardDoc = DOC;
remAll = OPENED;
process.stdout.write(remindersHtml(lastState.reminders, team));
""".replace("STATE", json.dumps(state)).replace("DOC", json.dumps(doc)).replace("OPENED", json.dumps(opened))
    result = subprocess.run(["node", "-e", JS_STUB.replace("STORE", "{}") + code + driver],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout


def public(m):
    return push_live.public_state(m.snapshot(NOW))


def observe(items, jobs):
    """Exercise the actual separate claim and active task/request read paths, offline."""
    src = live.LiveSource.__new__(live.LiveSource)
    def read(action, args=None, **who):
        args = args or {}
        if action == "reminders":
            return {"reminders": jobs, "tick": 1000}, 1000
        rows = [it for it in items if not args.get("kind") or it["kind"] == args["kind"]]
        return {"items": rows, "tick": 1000}, 1000
    class Harness:
        def dispatch(self, *args, **kwargs):
            return {"events": [], "cursor": 0}, 1000
    src.h, src.read, src.reader = Harness(), read, lambda: {"bot": "sol"}
    src.caps, src.has_board = {"harness": True}, True
    src.has_confess = src.has_tells = src.has_operator = False
    for suffix in ("groups", "hauling", "efficiency", "loadout", "clouds", "library_areas", "net_map", "terrain", "chart"):
        setattr(src, "observe_" + suffix, lambda *a: None)
    src.read_focus, src.read_progress, src.full_steps = lambda *a: None, lambda *a: [], lambda *a: None
    src.board_seq, src.next_board, src.board_every, src.journals = 0, 0, 15.0, None
    src.plan_ticks_ok = None
    obs, errors = {}, {}
    with patch.object(live.time, "time", return_value=NOW):
        src.observe_board(obs, errors)
    assert not errors, errors
    return obs


def main():
    lim = reminder_view.limits()
    assert lim and set(lim) == {"MAX_JOBS", "MAX_OWN"}
    # A changed declaration changes the displayed limits; missing source has no invented fallback.
    reminder_view.limits.cache_clear()
    with patch.object(Path, "read_text", return_value="  local MAX_JOBS, MAX_OWN, MAX_TEXT = 99, 7, 300\n"):
        assert reminder_view.limits() == {"MAX_JOBS": 99, "MAX_OWN": 7}
    reminder_view.limits.cache_clear()
    with patch.object(Path, "read_text", side_effect=OSError):
        assert reminder_view.limits() is None
    reminder_view.limits.cache_clear()

    m = model.Model(RUN)
    jobs = [{"id": i, "owner": "astra", "enabled": i == 0, "done": True, "message": f"review {i}",
             "recipients": "astra, sol", "states": "astra overdue (2 runs missed); sol overdue",
             "backup": "sol", "last_result": "long result " * 30, "result_age_s": 480,
             "last_fired_tick": 100, "board_item": 10} for i in range(lim["MAX_OWN"])]
    jobs += [{"id": 100, "owner": "sol", "enabled": False, "states": "luna overdue", "message": "request only", "board_item": 11},
             {"id": 101, "owner": "sol", "enabled": True, "states": "sol scheduled", "message": "age unknown", "last_result": "old"}]
    board = {"items": [{"id": 10, "kind": "claim", "status": "open", "owner": "astra", "covers": [{"name": "luna"}]},
                       {"id": 11, "kind": "request", "status": "claimed", "owner": "sol"}], "active_ids": [11], "claim_ids": [10]}
    observation = observe(board["items"], jobs)
    assert observation["board"]["claim_ids"] == [10] and observation["board"]["active_ids"] == [11]
    m.ingest(observation, now=NOW)
    cap = m.reminders_snapshot()["capacity"]
    assert cap["held"] == len(jobs) and cap["active"] == 2
    assert cap["owners"]["astra"] == {"held": lim["MAX_OWN"], "active": 1}
    assert cap["owners"]["sol"] == {"held": 2, "active": 1}  # being a recipient uses no slot
    assert cap["owners"]["luna"] == {"held": 0, "active": 0}

    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "resting.json"
        path.write_text(json.dumps({"since": NOW - 60, "until": NOW + 3600, "reason": "pace", "firm": True}))
        rest = pacing.resting(d, NOW)
        obs = {"agents": [{"name": "astra", "alive": True, "resting": rest},
                          {"name": "sol", "alive": True, "resting": None, "active": "walk"}]}
        m.ingest(obs, now=NOW)
        state = public(m)
        astra = next(a for a in state["agents"] if a["name"] == "astra")
        assert astra["resting_until"] == NOW + 3600 and astra["resting_known"]
        html = render(state)
        assert "Astra overdue (2 runs missed) · resting until 10:15 PT (Fri)" in html
        assert "Sol overdue · not resting, acting" in html
        assert "Configured backup: Sol" in html and "Recorded cover on claim #10: Luna" in html
        assert "Result age: 8 min (game time)" in html
        assert html.index("Result age: 8 min") < html.index('<details class="lt"')  # visible when result is collapsed
        assert f'Team: {len(jobs)} held / {lim["MAX_JOBS"]} slots · 2 active' in html
        assert f'Astra: {lim["MAX_OWN"]} held / {lim["MAX_OWN"]} slots · 1 active' in html

        # Full board/pagination retain counts; a request (even claimed) does not establish cover.
        doc = push_live.public_board_all(m.board_all_snapshot())
        html = render(state, doc, True)
        assert "Luna overdue · rest state unknown" in html
        assert "Linked request #11: Sol (claimed; not recorded cover)" in html
        assert "Recorded cover: unknown" in html and "Recorded cover on claim #11" not in html
        assert "Result age: no result recorded" in html and "Result age: unknown" in html
        assert doc["reminders_capacity"] == cap

        # Handoff/restart: a fresh model is unknown until the existing file is read again.
        fresh = model.Model(RUN)
        fresh.ingest({"reminders": {"jobs": jobs, "tick": 1000}}, now=NOW)
        assert "Astra overdue (2 runs missed) · rest state unknown" in render(public(fresh))
        fresh.ingest(obs, now=NOW)
        assert "resting until 10:15" in render(public(fresh))
        # Resume clears the deadline; the overdue/missed state is not hidden or reset.
        path.unlink()
        m.ingest({"agents": [{"name": "astra", "resting": pacing.resting(d, NOW)}]}, now=NOW)
        html = render(public(m))
        assert "Astra overdue (2 runs missed) · not resting" in html and "resting until" not in html
        path.write_text(json.dumps(rest))
        assert pacing.resting(d, NOW + 3601) is None

    # Coverage removed at handoff or absent from the latest board read must not remain recorded.
    board["items"][0]["covers"] = []
    m.ingest({"board": board}, now=NOW)
    assert "Recorded cover on claim #10" not in render(public(m))
    board["items"][0]["covers"] = [{"name": "luna"}]
    board["claim_ids"] = []
    m.ingest({"board": board}, now=NOW)
    assert m.reminders_snapshot()["jobs"][0]["board_context"] is None

    # Summary is from the full read, before the model cap and public byte budget.
    m.ingest({"reminders": {"jobs": jobs[:1] * (m.REMINDERS_MAX + 5)}}, now=NOW)
    snapshot = m.reminders_snapshot()
    assert len(snapshot["jobs"]) == m.REMINDERS_MAX and snapshot["capacity"]["held"] == m.REMINDERS_MAX + 5
    with patch.object(push_live, "REMINDER_BYTES", 1000):
        trimmed = push_live.public_reminders(snapshot)
    assert len(trimmed["jobs"]) < len(snapshot["jobs"]) and trimmed["capacity"] == snapshot["capacity"]
    m.ingest({"reminders": {"jobs": []}}, now=NOW)
    assert f'Team: 0 held / {lim["MAX_JOBS"]} slots · 0 active' in render(public(m))
    assert render({"agents": [], "reminders": None}) == ""
    print("reminder availability: ok (mixed recipients, rest/resume, handoff/restart, cover/request, ages, full capacity)")


if __name__ == "__main__":
    main()
