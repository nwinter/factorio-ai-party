#!/usr/bin/env python3
"""A project's owner's running test beside its progress check: python3 tools/stream/test_project_tests.py

d22 batch99 BI5 (viewer Aurora site:4333: "Asterion still shows stalled while Astra's timed flight watch is running.
Could the board show the active test and its deadline alongside the last progress check?"). Checks: model.project_state
gives owner_work, the owner's running or armed watches (status work rows, flight watches included) and its current wait,
each with its line and end tick, and the items a watch names (an #id in its scope or reason; this project when its title
names the watch's scope as a word); finished or stalled watches are left out; the check's own state stays as it is; the
live page writes them under the check ("Astra's test: ... (until tick N); names this project").
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model  # noqa: E402

SITE = os.path.join(os.path.dirname(os.path.dirname(HERE)), "site")


def rows():
    m = model.Model({"agents": {n: {} for n in ("astra", "sol")}})
    m.tick = 48000000
    m._ingest_board({"items": [
        {"id": 1910, "kind": "project", "title": "Asterion edge qualification", "status": "doing", "owner": "astra",
         "progress": "3 of 6 steps", "updated_tick": 47000000},
        {"id": 1923, "kind": "task", "title": "Railgun recharge proof", "status": "doing", "owner": "astra", "updated_tick": 47900000},
        {"id": 1800, "kind": "project", "title": "Fulgora quality", "status": "doing", "owner": "sol", "progress": "1 of 3 steps"}],
        "open_unowned": 0,
        "progress": [{"id": 1910, "state": "stalled: unchanged across 3 checks", "stalled": True, "unchanged_checks": 3, "checked_s": 40}]})
    m.space = dict(m.space or {}, platforms=[{"name": "Asterion"}, {"name": "Kestrel II"}])
    astra = m.agent("astra")
    astra.watches = [
        {"id": "flight#7", "kind": "flight_watch", "scope": "Asterion", "state": "running", "start_tick": 47990000,
         "end_tick": 48000000 + 90 * 3600, "line": "flight watch #7 on Asterion: ..."},
        {"id": "uptime@1", "kind": "uptime", "scope": "8 railguns", "state": "running", "start_tick": 47999000,
         "end_tick": 48000000 + 600 * 60, "reason": "board #1923 proof"},
        {"id": "belt_flow@2", "kind": "belt_flow", "scope": "belt line", "state": "late", "end_tick": 47000000},
        {"id": "flight#8", "kind": "flight_watch", "scope": "Kestrel II", "state": "armed", "minutes": 30},
        # as world n read it at 17:05: a platform named inside the scope
        {"id": "asteroid_watch@48664936", "kind": "asteroid_watch", "scope": "asteroids and 97 turrets on Asterion",
         "state": "running", "start_tick": 48664936, "end_tick": 48682936, "reason": "Probe562 outbound to guarded turn",
         "latest": {"tick": 48666226, "line": "150 asteroids seen, 57 in view, 0 hits on the platform"}}]
    astra.wait = {"kind": "sleep", "tick": 48000000, "at": 1000.0, "until_tick": 48000000 + 1800, "estimates": [],
                  "condition": None, "idle_s": 0}
    m.snap_now = 1010.0  # the snapshot's time: the wait was read 10 s before
    p = {r["id"]: r for r in m.projects_snapshot()}
    w = p[1910]["owner_work"]
    assert p[1910]["check"]["state"] == "stalled: unchanged across 3 checks", "the check as it is"
    assert [x["kind"] for x in w] == ["flight_watch", "uptime", "flight_watch", "asteroid_watch", "wait"], w
    assert w[3]["this"] is True and w[3]["end_tick"] == 48682936 and "latest: 150 asteroids seen" in w[3]["line"], w[3]
    assert w[0]["this"] is True and w[0]["end_tick"] == 48000000 + 90 * 3600 and "ends in 1 h 30 min" in w[0]["line"], w[0]
    assert w[1].get("this") is None and w[1]["names"] == [{"id": 1923, "title": "Railgun recharge proof"}], w[1]
    assert "waiting for its next departure, then at most 30 min" in w[2]["line"] and "this" not in w[2], w[2]
    assert w[4]["end_tick"] == 48000000 + 1800, w[4]
    assert "owner_work" not in p[1800], "sol runs nothing"
    for x in w:  # facts as lines, json-ready
        json.dumps(x)
    return p[1910]


def page(row):
    if not shutil.which("node"):
        print("project tests: live.js part skipped (no node)")
        return
    code = open(os.path.join(SITE, "static", "live.js")).read()
    fn = code[code.index("  var STATUS_CHIP = {"):code.index("  function projectItem(p, byName, card, withNext) {")]
    js = """
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function ago(s) { return Math.round(s) + ' s ago'; }
function gameAgo() { return ''; }
var lastState = null;
""" + fn + "process.stdout.write(projectFacts(" + json.dumps(row) + ", { astra: { name: 'astra', display_name: 'Astra' } }));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    out = r.stdout
    assert "Progress check 40 s ago: stalled: unchanged across 3 checks" in out, out
    assert "Astra&#39;s test: flight watch flight#7, Asterion: ends in 1 h 30 min" in out or "Astra's test: flight watch flight#7, Asterion: ends in 1 h 30 min" in out, out
    assert "(until tick 48324000); names this project" in out, out
    assert "names #1923 Railgun recharge proof" in out and "s wait: " in out, out


def main():
    page(rows())
    print("project tests: ok (the owner's running watches and wait with their ends beside the check; what each names)")


if __name__ == "__main__":
    main()
