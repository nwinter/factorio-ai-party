#!/usr/bin/env python3
"""A project's owner's running test beside its progress check: python3 tools/stream/test_project_tests.py

d22 batch99 BI5 (viewer Aurora site:4333: "Asterion still shows stalled while Astra's timed flight watch is running.
Could the board show the active test and its deadline alongside the last progress check?"). Checks: model.project_state
gives owner_work, the owner's running or armed watches (status work rows, flight watches included) and its current wait,
each with its line and end tick, and the items a watch names (an #id in its scope or reason; this project when its title
names the watch's scope as a word); finished or stalled watches are left out; the check's own state stays as it is; the
live page writes them under the check ("Astra's test: ... (until tick N); names this project").
d23 batch119 CB3 (viewer Aurora site:4347: "Could the board separate owner activity from project progress? Asterion's
rocket watch also appears on the blocked production-cell project"): a project lists only the watches that name it
("Astra's test for this project: ..."); the board card's Owner activity lists each owner's watches and wait once, with
the projects each is for, the other items it names, or "no project named", and a watch's end as time left when its line
does not say it.
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
function avatar(a) { return '<i>' + a.name + '</i>'; }
var lastState = { tick: 48000000 };
""" + fn
    team = "{ astra: { name: 'astra', display_name: 'Astra' } }"
    other = dict(row, id=1999, title="Standard production cells", status="blocked")
    other["owner_work"] = [dict(w, this=None) if w.get("this") else w for w in row["owner_work"]]
    board = {"projects": [row], "projects_more": [other]}
    js += ("var out = { facts: projectFacts(" + json.dumps(row) + ", " + team + "), other: projectFacts(" + json.dumps(other) + ", " + team +
           "), activity: ownerActivityHtml(" + json.dumps(board) + ", " + team + "), ends: [" +
           "workEnd({ kind: 'uptime', line: 'uptime watch', end_tick: 48003600 }), workEnd({ kind: 'uptime', line: 'x: ends in 1 min', end_tick: 48003600 }), " +
           "workEnd({ kind: 'wait', line: 'waiting', end_tick: 48003600 }), workEnd({ kind: 'uptime', line: 'over', end_tick: 47000000 })] }; process.stdout.write(JSON.stringify(out));")
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    o = json.loads(r.stdout)
    out = o["facts"]
    assert "Progress check 40 s ago: stalled: unchanged across 3 checks" in out, out
    # on the project: the two watches that name it (the flight watch on Asterion, the asteroid watch on Asterion)
    assert out.count("test for this project: ") == 2, out
    assert "Astra's test for this project: flight watch flight#7, Asterion: ends in 1 h 30 min</span>" in out, out
    assert "railgun" not in out.lower() and "wait" not in out and "until tick" not in out, out
    # another project of the same owner: none of them (the blocked production cells of site:4347)
    assert "test for this project" not in o["other"] and "Progress check" in o["other"], o["other"]
    act = o["activity"]
    assert act.startswith("<h4>Owner activity</h4>") and act.count('<li class="job">') == 1, act
    lines = [l.split("</span> ", 1)[1].split("</span>")[0] for l in act.split('<span class="small project-fact">')[1:]]
    assert len(lines) == 5, lines
    assert lines[0] == "flight watch flight#7, Asterion: ends in 1 h 30 min; for #1910 Asterion edge qualification", lines[0]
    assert lines[1].startswith("uptime watch ") and lines[1].endswith("; names #1923 Railgun recharge proof"), lines[1]
    assert lines[2].endswith("; no project named"), lines[2]  # flight#8 (armed, on Kestrel II)
    assert lines[4].startswith("waiting: ") and "project" not in lines[4], lines[4]
    assert "until tick" not in act, act
    # a line without its end gets the time left from the state's tick; one that says it, and a wait, nothing
    assert o["ends"] == [" (ends in 60 s)", "", "", ""], o["ends"]


def main():
    page(rows())
    print("project tests: ok (the owner's running watches and wait with their ends beside the check; what each names; on a project only those naming it, the rest under Owner activity)")


if __name__ == "__main__":
    main()
