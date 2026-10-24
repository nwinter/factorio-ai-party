#!/usr/bin/env python3
"""The live page's reminder list opens in full, with Active and Overdue filters: python3 site/test_reminders_all.py

d20 batch65 AA4 (viewer Aurora 08:56: "Could the reminder list expand beyond its first 12 entries? It shows '+13 more'
without a way to open them. Active/overdue filters would make the full list easier to review"). Checks: push_live keeps
the whole list within the reminders' share (over it, jobs past the first 12 go, finished ones first, total kept); the
panel shows the first 12 and "Show all N", opens to every job with All / Active / Overdue and their counts, filters,
says how many were not sent, and keeps the reader's choice across a refresh.
d24 batch150 PV1 (viewer Aurora 07:31: "Reminder 42 says "no result given" in the collapsed view, but both recipients
have results in the full board"): results left out for size say so (the same as the last result, or left out), the job
says how many recipients gave one and the first (shortened, said); "no result given" only where none was given.
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
    # (d20 batch70 AF2) the recipients' latest results go before any job: those repeating the last result first
    lat = lambda r: [{"name": n, "state": "acknowledged", "acked_ago_s": 60, "result": r} for n in ("sol", "astra", "luna")]  # noqa: E731
    mid = {"jobs": [job(i, last_result="a" * 300, latest=lat("a" * 300)) for i in range(25)], "total": 25}
    pr = push_live.public_reminders(mid)
    assert len(pr["jobs"]) == 25 and all(x["result"] is None for j in pr["jobs"] for x in j["latest"]), len(pr["jobs"])
    other = {"jobs": [job(i, last_result="a" * 100, latest=lat("b" * 300)) for i in range(25)], "total": 25}
    pr = push_live.public_reminders(other)
    assert len(pr["jobs"]) == 25 and len(json.dumps(pr)) <= push_live.REMINDER_BYTES, len(json.dumps(pr))
    assert pr["jobs"][0]["latest"][0]["state"] == "acknowledged" and pr["jobs"][0]["latest"][0]["result"] is None
    small = {"jobs": [job(i, latest=lat("ok")) for i in range(3)], "total": 3}
    assert push_live.public_reminders(small) == small


JS_STUB = """
var stored = STORE;
function store(k, v) { if (v === undefined) return stored[k] === undefined ? null : stored[k]; stored[k] = v; }
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
function ago(s) { return Math.round(s / 60) + ' min ago'; }
function avatar(o) { return '<i></i>'; }
var listeners = [], app = { addEventListener: function (t, f) { if (t === 'click') listeners.push(f); }, querySelector: function () { return null; } };
var lastState = null, team = { sol: { name: 'sol', display_name: 'Sol' }, astra: { name: 'astra', display_name: 'Astra' } };
var demo = true, API = '';  // (d22 batch99 BI3) no live API: the board document is not read
function getJSON() { return new Promise(function () {}); }
function gameAgo() { return ''; }
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
out.page2 = click({ page: 'rem', to: '1' });  // (d22 batch99 BI3) 20 a page
click({ page: 'rem', to: '0' });
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
    # opened: every job sent, 20 a page (BI3), the filters with their counts, the ones not sent
    assert li(o["all"]) == 20 and 'aria-expanded="true">Show the first 12</button>' in o["all"], o["all"]
    assert '1–20 of 25' in o["all"] and li(o["page2"]) == 5 and '21–25 of 25' in o["page2"], o["page2"]
    assert ">Waiting or open (3)<" in o["all"] and ">Finished (22)<" in o["all"], o["all"]
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
    # (d20 batch70 AF2, viewer Aurora) the backup and each recipient's latest: waiting with the runs missed and the
    # last result, a result a backup recorded for them, acknowledged with none given, never acknowledged
    j = job(107, name="verify-native-freight-receipts", backup="sol", latest=[
        {"name": "astra", "agent": "astra", "state": "overdue", "acked_ago_s": 8820, "result": "K2 Fulgora PU777/1000", "waiting_s": 8580,
         "missed": 15, "backup_told": True},
        {"name": "sol", "agent": "sol", "state": "acknowledged", "acked_ago_s": 60, "result": "pod ledger: PU 346 landed", "by": "astra"},
        {"name": "luna", "state": "acknowledged", "acked_ago_s": 120},
        {"name": "grok", "state": "scheduled"}])
    js = JS_STUB.replace("STORE", "{}") + fn + "process.stdout.write(remindersHtml(" + json.dumps({"jobs": [j], "total": 1}) + ", team));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    out = r.stdout
    assert r.returncode == 0 and '<div class="rem-latest"><span class="fx-muted small">Backup: Sol</span>' in out, out + r.stderr
    assert "Astra: waiting 143 min, 15 runs missed, backup told; last acknowledged 147 min ago:</span> K2 Fulgora PU777/1000" in out, out
    assert "Sol: acknowledged 1 min ago by Astra for them:</span> pod ledger: PU 346 landed" in out, out
    assert "luna: acknowledged 2 min ago, no result given" in out and "grok: scheduled, never acknowledged" in out, out
    # (d22 batch94 BD1) open and deferred stay open on the panel, done is green
    j = job(114, name="personal-equipment-standard", states="haiku open (gap: energy-shield-mk2-equipment); sol done; luna deferred (open): until Thursday", latest=[
        {"name": "haiku", "state": "open (gap: energy-shield-mk2-equipment)", "acked_ago_s": 60, "result": "shield mk2 missing"},
        {"name": "sol", "state": "done", "acked_ago_s": 120, "result": "300/300"},
        {"name": "luna", "state": "deferred (open): until Thursday", "acked_ago_s": 180}])
    js = JS_STUB.replace("STORE", "{}") + fn + "process.stdout.write(remindersHtml(" + json.dumps({"jobs": [j], "total": 1}) + ", team));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    out = r.stdout
    assert r.returncode == 0 and "acknowledged 1 min ago (open (gap: energy-shield-mk2-equipment)):</span> shield mk2 missing" in out, out + r.stderr
    assert "acknowledged 3 min ago (deferred (open): until Thursday), no result given" in out, out
    assert 'fx-chip fx-chip--green">Sol done' in out and 'fx-chip fx-chip--orange">' in out and 'deferred (open): until Thursday</span>' in out, out
    # an older state without them: nothing added
    js = JS_STUB.replace("STORE", "{}") + fn + "process.stdout.write(remindersHtml(" + json.dumps({"jobs": [job(1)], "total": 1}) + ", team));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0 and "rem-latest" not in r.stdout, r.stdout


def pv1_tests():
    """(d24 batch150 PV1) reminder 42 on world n at 07:55: astra and sol done, sol's result the job's last result."""
    r42 = lambda i: job(i, name="Reconsider plan against changed world", owner="astra", agent="astra", states="astra done; sol done",  # noqa: E731
                        last_result="step 3: Sol owns red qualification " + "s" * 360, result_by="sol", latest=[
                            {"name": "astra", "agent": "astra", "state": "done", "acked_ago_s": 780, "result": "step 3: Continue2150 " + "a" * 360},
                            {"name": "sol", "agent": "sol", "state": "done", "acked_ago_s": 478, "result": "step 3: Sol owns red qualification " + "s" * 360},
                            {"name": "luna", "agent": "luna", "state": "acknowledged", "acked_ago_s": 120}])
    pr = push_live.public_reminders({"jobs": [r42(i) for i in range(30)], "total": 30})
    j = pr["jobs"][0]
    assert [x.get("result_omitted") for x in j["latest"]] == ["size", "same", None] and all(x.get("result") is None for x in j["latest"]), j["latest"]
    assert j["results_given"] == 2 and j["result_first"]["name"] == "astra" and j["result_first"]["shortened"], j.get("result_first")
    assert len(j["result_first"]["text"]) == 100 and j["result_first"]["text"].startswith("step 3: Continue2150 "), j["result_first"]
    # a first result that is the job's last result is not sent twice
    k = push_live.latest_without_results(dict(r42(0), latest=r42(0)["latest"][1:]), True)
    assert k["result_first"] == {"name": "sol", "agent": "sol", "same": True} and k["results_given"] == 1, k
    # nothing left out: the job as it came
    assert push_live.latest_without_results(job(1, latest=[{"name": "luna", "acked_ago_s": 60}]), False) == job(1, latest=[{"name": "luna", "acked_ago_s": 60}])
    # the full board document: the same marks
    doc = push_live.public_board_all({"items": [], "claims": [], "projects": [], "reminders": [r42(i) for i in range(30)]}, limit=8000)
    assert doc["reminders"][0]["results_given"] == 2 and doc["reminders"][0]["latest"][0]["result_omitted"], doc["reminders"][0]
    if not shutil.which("node"):
        print("reminders all: PV1 live.js part skipped (no node)")
        return
    code = open(os.path.join(HERE, "static", "live.js")).read()
    fn = code[code.index("  var openLong = {};"):code.index("  function projectsHtml(board, byName, card, withNext) {")]
    js = JS_STUB.replace("STORE", "{}") + fn + "process.stdout.write(remindersHtml(" + json.dumps({"jobs": [j, k], "total": 2}) + ", team));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    out = r.stdout
    assert r.returncode == 0, r.stderr
    assert "2 of 3 recipients gave a result; the first, Astra's, shortened: step 3: Continue2150 aaa" in out, out
    assert "Astra: acknowledged 13 min ago, result left out of this view for size" in out, out
    assert "Sol: acknowledged 8 min ago, result: the same as the last result above" in out, out
    assert "luna: acknowledged 2 min ago, no result given" in out and out.count("no result given") == 2, out  # luna in each job, and only she
    assert "1 of 2 recipients gave a result; the first, Sol's, is the last result above" in out, out


def main():
    payload_tests()
    page_tests()
    pv1_tests()
    print("reminders all: ok (the whole list within the reminders' share; the first 12, Show all with All / Active / "
          "Overdue and their counts, the ones not sent, the choice kept)")


if __name__ == "__main__":
    main()
