#!/usr/bin/env python3
"""Every task and reminder on the live page, with paging: python3 site/test_board_all.py

d22 batch99 BI3 (viewer Aurora site:4316: "Could the board show all tasks and reminders, with paging if needed? Hidden
jobs and the nine omitted reminders make it hard to check what's actually finished."). Checks: push_live keeps the full
board document within its share (evidence, then finished projects' steps, then the reminders' results, then the oldest
tasks), sends it to /v1/board when it changed and at most every BOARD_EVERY s, again after BOARD_STALE s, and backs
off 10 minutes from a worker without the route; the page's full task list reads it, filters Open / In progress /
Finished / Dropped / All with counts, marks finished ones, and pages 20 at a time; the reminders' "Show all" pages the
document's whole list.
"""
import io, json, os, shutil, subprocess, sys
import urllib.error
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import push_live  # noqa: E402


def doc(n_items=60, ev=1, steps=0, results=0):
    items = [{"id": i, "title": f"task {i}", "kind": "task", "owner": "sol", "agent": "sol",
              "status": ("done" if i % 3 == 0 else "doing" if i % 3 == 1 else "open"), "updated_tick": 1000 - i,
              "evidence": [f"line {k} " + "e" * 200 for k in range(ev)]} for i in range(n_items)]
    projects = [{"id": 900, "title": "done one", "status": "done", "steps": [{"text": "s" * 300}] * steps}]
    rem = [{"id": i, "name": f"r{i}", "message": "m", "last_result": "r" * 100,
            "latest": [{"name": "sol", "state": "done", "result": "x" * results}]} for i in range(31)]
    return {"tick": 1, "items": items, "items_total": n_items, "claims": [], "projects": projects, "reminders": rem,
            "reminders_total": 31}


def payload_tests():
    small = doc()
    assert push_live.public_board_all(small) == small, "a document that fits goes whole"
    size = lambda d: len(json.dumps(d, ensure_ascii=False, separators=(",", ":")))  # noqa: E731
    big = doc(n_items=400, ev=5)
    out = push_live.public_board_all(big)
    assert size(out) <= push_live.BOARD_ALL_BYTES and len(out["items"]) == 400, size(out)
    assert out["items"][0]["evidence"] == big["items"][0]["evidence"][-1:] and out["items"][0]["evidence_more"] == 4
    huge = doc(n_items=400, ev=5, steps=200, results=900)
    out = push_live.public_board_all(huge, limit=120 * 1024)
    assert size(out) <= 120 * 1024 and out["projects"][0]["steps"] is None and out["projects"][0]["steps_cut"], size(out)
    assert out["reminders"][0]["latest"][0]["result"] is None and len(out["reminders"]) == 31, "every reminder kept"
    assert len(out["items"]) < 400 and out["items_total"] == 400 and out["items"][0]["id"] == 0, len(out["items"])
    assert push_live.board_url("http://127.0.0.1:8788/state.json") == "http://127.0.0.1:8788/board.json"


def push_tests():
    sent, served = [], {"doc": doc()}

    class Resp(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def urlopen(req, timeout=None):
        url = req if isinstance(req, str) else req.full_url
        if url.endswith("/board.json"):
            return Resp(json.dumps(served["doc"]).encode())
        if served.get("missing"):
            raise urllib.error.HTTPError(url, 404, "not found", {}, None)
        sent.append((url, json.loads(req.data)))
        return Resp(b'{"ok": true}')
    real = push_live.urllib.request.urlopen
    push_live.urllib.request.urlopen = urlopen
    try:
        a = SimpleNamespace(source="http://127.0.0.1:8788/state.json", api="https://api.example", print=False)
        board = {"hash": None, "at": 0.0, "bytes": 0, "off_until": 0.0}
        assert push_live.push_board(a, "t", board, now=100.0) > 0 and sent[-1][0] == "https://api.example/v1/board"
        assert len(sent[-1][1]["items"]) == 60 and board["bytes"] > 0
        assert push_live.push_board(a, "t", board, now=110.0) is None, "at most every BOARD_EVERY s"
        assert push_live.push_board(a, "t", board, now=140.0) is None and len(sent) == 1, "unchanged: not sent"
        served["doc"] = dict(doc(), tick=2)
        assert push_live.push_board(a, "t", board, now=150.0) is None, "only the tick moved: not news"
        served["doc"]["items"][1]["status"] = "done"
        assert push_live.push_board(a, "t", board, now=180.0) and len(sent) == 2, "a change goes out"
        assert push_live.push_board(a, "t", board, now=180.0 + push_live.BOARD_STALE) and len(sent) == 3, "stale: again"
        served["missing"] = True
        served["doc"]["items"][2]["status"] = "done"
        assert push_live.push_board(a, "t", board, now=1000.0) is None and board["off_until"] == 1600.0
        assert push_live.push_board(a, "t", board, now=1100.0) is None and len(sent) == 3, "backing off"
    finally:
        push_live.urllib.request.urlopen = real


JS_STUB = """
var stored = {};
function store(k, v) { if (v === undefined) return stored[k] === undefined ? null : stored[k]; stored[k] = v; }
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
function ago(s) { return Math.round(s / 60) + ' min ago'; }
function gameAgo(s, t) { return t == null ? '' : Math.round((s.tick - t) / 3600) + ' min ago'; }
function avatar(o) { return '<i></i>'; }
var demo = false, API = 'https://api.example', fetched = [];
function getJSON(url) { fetched.push(url); return { then: function (f) { f(DOC); return { catch: function () { return { then: function (g) { g(); } }; } }; } }; }
var listeners = [], app = { addEventListener: function (t, f) { if (t === 'click') listeners.push(f); }, querySelector: function () { return null; } };
var team = { sol: { name: 'sol', display_name: 'Sol' } };
"""


def page_tests():
    if not shutil.which("node"):
        print("board all: live.js part skipped (no node)")
        return
    code = open(os.path.join(HERE, "static", "live.js")).read()
    fn = code[code.index("  var openLong = {};"):code.index("  function projectsHtml(board, byName, card, withNext) {")]
    d = doc(n_items=45)
    driver = """
var s = { tick: 3600 * 1000, board: { open_items: [], open_items_total: 15, doing_items: [], doing_items_total: 15 }, reminders: { jobs: DOC.board.reminders.slice(0, 19), total: 31 } };
lastState = s;
var out = {};
out.closed = allJobsHtml(s, team);
function click(attrs, cls) {
  var box = { outerHTML: '' };
  var b = { dataset: attrs, closest: function (sel) { return sel === cls ? box : null; } };
  listeners.forEach(function (f) { f({ target: { closest: function () { return b; } } }); });
  return box.outerHTML;
}
out.open = click({ action: 'jobs-all' }, '.board-all');
out.done = click({ jobsFilter: 'done' }, '.board-all');
out.all = click({ jobsFilter: 'all' }, '.board-all');
out.all2 = click({ page: 'jobs', to: '1' }, '.board-all');
out.rem = click({ action: 'reminders-all' }, '.board-rem');
out.rem2 = click({ page: 'rem', to: '1' }, '.board-rem');
out.fetched = fetched;
process.stdout.write(JSON.stringify(out));
"""
    js = JS_STUB.replace("DOC", json.dumps({"board": d, "age_s": 12})) + fn + driver.replace("DOC", json.dumps({"board": d}))
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    o = json.loads(r.stdout)
    li = lambda h: h.count("<li>")  # noqa: E731
    assert 'data-action="jobs-all" aria-expanded="false">Show every task and request, finished ones too (+30 not listed above)' in o["closed"], o["closed"]
    assert "jobs-filters" not in o["closed"] and o["fetched"][0] == "https://api.example/v1/board", o["fetched"]
    # opened: Open first, with every filter's count
    assert 'data-jobs-filter="open" aria-pressed="true">Open (15)' in o["open"] and ">In progress (15)<" in o["open"], o["open"]
    assert ">Finished (15)<" in o["open"] and ">Dropped (0)<" in o["open"] and ">All (45)<" in o["open"] and li(o["open"]) == 15, o["open"]
    # finished ones marked; All pages 20 at a time
    assert li(o["done"]) == 15 and o["done"].count('fx-chip--green">finished</span>') == 15, o["done"]
    assert 'changed ' in o["done"] and "Full list as of 0 min ago" in o["done"], o["done"]
    assert li(o["all"]) == 20 and "1–20 of 45" in o["all"] and li(o["all2"]) == 20 and "21–40 of 45" in o["all2"], o["all2"]
    # the reminders: every one from the document, 20 a page
    assert li(o["rem"]) == 20 and "1–20 of 31" in o["rem"] and "not sent" not in o["rem"], o["rem"]
    assert li(o["rem2"]) == 11 and "21–31 of 31" in o["rem2"], o["rem2"]


def main():
    payload_tests()
    push_tests()
    page_tests()
    print("board all: ok (the full board document within its share, sent when it changed; every task with filters "
          "and pages, finished ones marked; every reminder paged)")


if __name__ == "__main__":
    main()
