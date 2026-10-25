#!/usr/bin/env python3
"""A recurring reminder's schedule apart from its last run: python3 site/test_reminders_schedule.py

d24 batch177 QT1 (viewer Aurora 17:20: "On the site, could recurring reminders show schedule and last-run status
separately? #151 is enabled every 20m but hidden from Active and labelled done despite its next run."). World n 17:25:
#151 read enabled true, done true (a one-time job that ran, then edited to every 20m and enabled), next in 17m51s,
states "sol done". An enabled job is active: its row says "Schedule: every 20m00s, next in 18 min" and, apart, "Last
run 2 min ago:" with the recipients' states; done belongs to a job that is off. Checked in the collapsed view, Show all
(Active, Finished) and the board document, and in push_live's trimming (finished jobs go first, an enabled one stays).
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import push_live  # noqa: E402

TICK = 58499151
R151 = {"id": 151, "name": "BF age and buffer review after rollback", "owner": "sol", "agent": "sol", "recipients": "sol",
        "message": "Review nativeBF MV20..30/pay10; count captive fuel/requester/storage ages and actual pods.",
        "cadence": "every 20m00s", "every_ticks": 72000, "enabled": True, "done": True, "next_due_tick": 58563383,
        "next_due_in_s": 1070, "last_fired_tick": 58491420, "last_result": "No expiry/stock/ETA gap; preserve 20..30/pay10.",
        "result_by": "sol", "result_tick": 58492035, "result_age_s": 118, "states": "sol done",
        "latest": [{"name": "sol", "agent": "sol", "state": "done", "acked_ago_s": 118, "result": "No expiry/stock/ETA gap; preserve 20..30/pay10."}]}


def job(i, **kw):
    return dict({"id": i, "name": f"job {i}", "owner": "astra", "agent": "astra", "message": f"message {i}", "cadence": "every 30m00s",
                 "every_ticks": 108000, "enabled": True, "next_due_in_s": 600, "last_fired_tick": TICK - 3600,
                 "states": "astra acknowledged"}, **kw)


def jobs():
    """14 jobs, #151 the 13th (past the collapsed view): 4 one-time jobs that ran (off, done), a job off, one never run."""
    out = [job(i, cadence="once at tick 58000000", every_ticks=None, enabled=False, done=True, next_due_in_s=None) for i in range(4)]
    out.append(job(4, enabled=False, next_due_in_s=None))
    out.append(job(5, states="astra scheduled", last_fired_tick=None))
    out += [job(i) for i in range(6, 12)]
    out.append(job(12))
    out.append(dict(R151))
    return out


def payload_tests():
    # trimmed for size: the finished jobs (done and off) go before an enabled one, whatever its stale done
    big = [job(i, last_result="r" * 1000) for i in range(12)] + \
          [job(100 + i, last_result="r" * 1000, enabled=False, done=True) for i in range(20)] + [dict(R151, last_result="r" * 1000)]
    pr = push_live.public_reminders({"jobs": big, "total": len(big), "tick": TICK})
    ids = [j["id"] for j in pr["jobs"]]
    assert 151 in ids and any(100 + i not in ids for i in range(20)) and pr["tick"] == TICK, ids
    # the board document keeps the fields the panel reads
    doc = push_live.public_board_all({"items": [], "claims": [], "projects": [], "reminders": [dict(R151)]}, limit=8000)
    r = doc["reminders"][0]
    assert r["enabled"] is True and r["last_fired_tick"] == 58491420 and r["cadence"] == "every 20m00s", r


JS_STUB = """
var stored = STORE;
function store(k, v) { if (v === undefined) return stored[k] === undefined ? null : stored[k]; stored[k] = v; }
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
function ago(s) { return Math.round(s / 60) + ' min ago'; }
function avatar(o) { return '<i></i>'; }
var listeners = [], app = { addEventListener: function (t, f) { if (t === 'click') listeners.push(f); }, querySelector: function () { return null; } };
var lastState = null, team = { sol: { name: 'sol', display_name: 'Sol' }, astra: { name: 'astra', display_name: 'Astra' } };
var demo = true, API = '';
function getJSON() { return new Promise(function () {}); }
function gameAgo() { return ''; }
"""


def row_of(html, rid):
    """The <li> of job rid (its message's start)."""
    key = "message %d " % rid if rid != 151 else "Review nativeBF"
    i = html.index(key)
    return html[html.rindex("<li>", 0, i):html.index("</li>", i)]


def page_tests():
    if not shutil.which("node"):
        print("reminders schedule: live.js part skipped (no node)")
        return
    code = open(os.path.join(HERE, "static", "live.js")).read()
    fn = code[code.index("  var openLong = {};"):code.index("  function projectsHtml(board, byName, card, withNext) {")]
    rem = {"jobs": jobs(), "total": 14, "tick": TICK}
    driver = """
var rem = REM, out = {};
lastState = { reminders: rem, tick: rem.tick };
out.alone = remindersHtml({ jobs: [rem.jobs[13], rem.jobs[0], rem.jobs[5]], total: 3, tick: rem.tick }, team);
out.first = remindersHtml(rem, team);
function click(attrs) {
  var box = { outerHTML: '' };
  var b = { dataset: attrs, closest: function (sel) { return sel === '.board-rem' ? box : null; } };
  var ev = { target: { closest: function () { return b; } } };
  listeners.forEach(function (f) { f(ev); });
  return box.outerHTML;
}
out.all = click({ action: 'reminders-all' });
out.active = click({ remFilter: 'active' });
out.finished = click({ remFilter: 'finished' });
// the board document: every job, as /v1/board gives it (the state carries 13 here)
click({ remFilter: 'active' });
boardDoc = { reminders: rem.jobs, reminders_total: 14 };
out.doc = remindersHtml({ jobs: rem.jobs.slice(0, 13), total: 14, tick: rem.tick }, team);
process.stdout.write(JSON.stringify(out));
"""
    js = JS_STUB.replace("STORE", "{}") + fn + driver.replace("REM", json.dumps(rem))
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    o = json.loads(r.stdout)
    # #151: its schedule with the next run, apart from its last run (when, and the recipient's state)
    row = row_of(o["alone"], 151)
    assert '<span class="fx-muted rem-schedule">Schedule: every 20m00s, next in 18 min</span>' in row, row
    assert '<span class="fx-muted small rem-run">Last run 2 min ago:</span> <span class="fx-chip fx-chip--green">Sol done</span>' in row, row
    assert "last result 2 min ago:" in row and ", done<" not in row, row
    # a one-time job that ran: done in its schedule, its states as the last run's; a job never run says so
    row = row_of(o["alone"], 0)
    assert "Schedule: once at tick 58000000, done</span>" in row and "Last run 1 min ago:" in row, row
    row = row_of(o["alone"], 5)
    assert "Schedule: every 30m00s, next in 10 min" in row and "Not run yet:</span>" in row, row
    # the collapsed view: the first 12; Show all: #151 among them
    assert o["first"].count("<li>") == 12 and "Review nativeBF" not in o["first"], o["first"]
    assert "Review nativeBF" in o["all"] and "next in 18 min" in row_of(o["all"], 151), o["all"]
    # Active: the 9 enabled jobs, #151 among them; Finished: the 4 one-time jobs that ran and the one off, not #151
    assert ">Active (9)<" in o["all"] and ">Finished (5)<" in o["all"], o["all"]
    assert o["active"].count("<li>") == 9 and "Review nativeBF" in o["active"], o["active"]
    assert o["finished"].count("<li>") == 5 and "Review nativeBF" not in o["finished"], o["finished"]
    # the board document's list: the same rows
    assert "Review nativeBF" in o["doc"] and "Schedule: every 20m00s, next in 18 min" in row_of(o["doc"], 151), o["doc"]
    assert "Last run 2 min ago:" in row_of(o["doc"], 151), o["doc"]


def main():
    payload_tests()
    page_tests()
    print("reminders schedule: ok (an enabled reminder is active, its schedule apart from its last run, in the collapsed "
          "view, Show all, its filters and the board document)")


if __name__ == "__main__":
    main()
