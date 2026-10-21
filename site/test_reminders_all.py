#!/usr/bin/env python3
"""The live page's reminder list opens in full, with Active and Overdue filters: python3 site/test_reminders_all.py

d20 batch65 AA4 (viewer Aurora 08:56: "Could the reminder list expand beyond its first 12 entries? It shows '+13 more'
without a way to open them. Active/overdue filters would make the full list easier to review"). Checks: push_live keeps
the whole list within the reminders' share (over it, jobs past the first 12 go, finished ones first, total kept); the
panel shows the first 12 and "Show all N", opens to every job with All / Active / Overdue and their counts, filters,
says how many were not sent, and keeps the reader's choice across a refresh.
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import push_live  # noqa: E402


def job(i, **kw):
    return dict({"id": i, "name": f"job {i}", "owner": "sol", "agent": "sol", "message": f"message {i}", "cadence": "every 30m00s",
                 "enabled": True, "done": False, "next_due_in_s": 600, "states": "sol acknowledged"}, **kw)


def jobs25():
    """A mix like world n's at 09:10: 12 finished, 3 off, 7 on, 3 on with a recipient overdue."""
    out = []
    for i in range(25):
        if i % 2 and len([j for j in out if j["done"]]) < 13:
            out.append(job(i, enabled=False, done=True, states="sol acknowledged"))
        elif i in (4, 10, 22):
            out.append(job(i, states="astra overdue (2 runs missed (the first at tick 7200, 1m00s ago; the last at tick 9000, 30s ago)); sol acknowledged"))
        elif i in (0, 8, 24):
            out.append(job(i, enabled=False))
        else:
            out.append(job(i))
    return out


def payload_tests():
    rem = {"jobs": jobs25(), "total": 25}
    assert push_live.public_reminders(rem) == rem  # 25 small jobs fit whole
    big = {"jobs": [job(i, last_result="r" * 1000, done=i % 3 == 0) for i in range(40)], "total": 40}
    pr = push_live.public_reminders(big)
    n = len(json.dumps(pr, ensure_ascii=False))
    assert n <= push_live.REMINDER_BYTES and pr["total"] == 40, (n, pr["total"])
    ids = [j["id"] for j in pr["jobs"]]
    assert ids[:12] == list(range(12)), ids  # the first view whole
    dropped = set(range(40)) - set(ids)
    assert dropped and (all(big["jobs"][i]["done"] for i in dropped)  # finished ones go first
                        or all(i in dropped for i in range(12, 40) if big["jobs"][i]["done"])), ids
    assert ids == sorted(ids), ids  # the order kept


JS_STUB = """
var stored = STORE;
function store(k, v) { if (v === undefined) return stored[k] === undefined ? null : stored[k]; stored[k] = v; }
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
function ago(s) { return Math.round(s / 60) + ' min ago'; }
function avatar(o) { return '<i></i>'; }
var listeners = [], app = { addEventListener: function (t, f) { if (t === 'click') listeners.push(f); }, querySelector: function () { return null; } };
var lastState = null, team = { sol: { name: 'sol', display_name: 'Sol' }, astra: { name: 'astra', display_name: 'Astra' } };
"""


def page_tests():
    if not shutil.which("node"):
        print("reminders all: live.js part skipped (no node)")
        return
    code = open(os.path.join(HERE, "static", "live.js")).read()
    fn = code[code.index("  var openLong = {};"):code.index("  function projectsHtml(board, byName, card, withNext) {")]
    rem = {"jobs": jobs25(), "total": 27}  # two more than the push sent
    driver = """
var rem = REM, out = {};
lastState = { reminders: rem };
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
out.overdue = click({ remFilter: 'overdue' });
out.refresh = remindersHtml(rem, team);
out.stored = JSON.parse(JSON.stringify(stored));  // before the close below
out.back = click({ action: 'reminders-all' });
process.stdout.write(JSON.stringify(out));
"""
    js = JS_STUB.replace("STORE", "{}") + fn + driver.replace("REM", json.dumps(rem))
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    o = json.loads(r.stdout)
    li = lambda h: h.count("<li>")  # noqa: E731
    # the first view: 12 and the button to the rest
    assert li(o["first"]) == 12 and 'data-action="reminders-all" aria-expanded="false">Show all 27 reminders (+15 more)</button>' in o["first"], o["first"]
    assert "data-rem-filter" not in o["first"]
    # opened: every job sent, the filters with their counts, the ones not sent
    assert li(o["all"]) == 25 and 'aria-expanded="true">Show the first 12</button>' in o["all"], o["all"]
    assert 'data-rem-filter="all" aria-pressed="true">All (25)' in o["all"] and ">Active (10)<" in o["all"] and ">Overdue (3)<" in o["all"], o["all"]
    assert "+2 more not sent (the page's size limit)" in o["all"], o["all"]
    # Active: on and not finished (7 + 3 overdue); Overdue: a recipient overdue, its chip whole
    assert li(o["active"]) == 10 and 'data-rem-filter="active" aria-pressed="true"' in o["active"] and "message 1<" not in o["active"], o["active"]
    assert li(o["overdue"]) == 3 and all(f"message {i} " in o["overdue"] for i in (4, 10, 22)), o["overdue"]
    assert 'fx-chip--red">Astra overdue (2 runs missed (the first at tick 7200, 1m00s ago; the last at tick 9000, 30s ago))</span>' in o["overdue"], o["overdue"]
    # a refresh keeps the reader's choice; stored for the next visit; closing goes back to the first 12
    assert o["refresh"] == o["overdue"] and o["stored"] == {"remindersAll": "1", "remindersFilter": "overdue"}, o["stored"]
    assert li(o["back"]) == 12, o["back"]
    # a reader who left it open with Active on comes back to it; an empty filter says so
    js = JS_STUB.replace("STORE", json.dumps({"remindersAll": "1", "remindersFilter": "overdue"})) + fn + \
        "process.stdout.write(remindersHtml(" + json.dumps({"jobs": [job(i) for i in range(14)], "total": 14}) + ", team));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0 and "No overdue reminders." in r.stdout and ">Overdue (0)<" in r.stdout, r.stdout + r.stderr
    # 12 or fewer: no button
    js = JS_STUB.replace("STORE", "{}") + fn + "process.stdout.write(remindersHtml(" + json.dumps({"jobs": [job(i) for i in range(12)], "total": 12}) + ", team));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0 and "reminders-all" not in r.stdout and r.stdout.count("<li>") == 12, r.stdout


def main():
    payload_tests()
    page_tests()
    print("reminders all: ok (the whole list within the reminders' share; the first 12, Show all with All / Active / "
          "Overdue and their counts, the ones not sent, the choice kept)")


if __name__ == "__main__":
    main()
