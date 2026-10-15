#!/usr/bin/env python3
"""The live page's projects open to their steps, and "show all" lists the hidden and finished ones (viewer Foobator, d15
08:31): python3 site/test_projects.py  (needs node; prints a skip without it)

static/live.js in a stub DOM: on the Board and Team plan cards each project is a <details> whose body lists its steps
(done with who and when, the next one tagged, the rest open), needs, handoff and who asked; a project known only from a
list read says its list is partial; "Show all N projects" holds state.board.projects_more and projects_done hidden until
pressed, and the press is remembered (localStorage projectsAll); a project the reader opened stays open on the next
refresh (about 5 s here).
"""
import json, os, re, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))

JS = r"""
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
function cls() { const s = new Set(); return { add: (c) => s.add(c), remove: (c) => s.delete(c), toggle: (c, on) => (on ? s.add(c) : s.delete(c)), contains: (c) => s.has(c) }; }
const kids = {};
const find = (s) => kids[s] || (/^#(cb-|map-|mm)/.test(s) ? null : (kids[s] = el(s)));
function el(name) {
  const e = { name, dataset: {}, textContent: '', value: '', hidden: false, classList: cls(), attrs: {}, _html: '', style: {}, on: {},
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; },
    addEventListener(t, f) { (this.on[t] = this.on[t] || []).push(f); }, appendChild() {},
    querySelector: (s) => find(s), querySelectorAll: () => [], scrollTop: 0, scrollHeight: 0, clientHeight: 0 };
  Object.defineProperty(e, 'innerHTML', { get() { return this._html; }, set(v) { this._html = v; for (const m of String(v).matchAll(/id="([\w-]+)"/g)) kids['#' + m[1]] = kids['#' + m[1]] || el(m[1]); } });
  return e;
}
for (const id of ['dash', 'strip', 'alerts', 'run-title', 'run-sub', 'updated', 'next-shift', 'offline', 'live-badge', 'watching']) kids['#' + id] = el(id);
const app = el('app');
app.querySelector = find;
const more = [el('more1'), el('more2')], buttons = [el('btn1')];
more.forEach((m) => { m.hidden = true; });
app.querySelectorAll = (sel) => (sel === '.projects-more' ? more : sel === '[data-action="projects-all"]' ? buttons : []);
app.dataset = { api: 'https://api.test', status: '/live/status.json', poll: '5', video: '', channel: '' };
global.window = global;
global.addEventListener = () => {};
global.requestAnimationFrame = (f) => setImmediate(f);
global.document = { getElementById: (id) => (id === 'live-app' ? app : kids['#' + id] || null), hidden: false, documentElement: { dataset: {} },
  addEventListener() {}, querySelector: () => null, createElement: (t) => (kids['new:' + t] = el(t)) };
global.matchMedia = () => ({ matches: true });
global.location = { search: '', hostname: 'localhost' };
const stored = {};
global.localStorage = { getItem: (k) => (k in stored ? stored[k] : null), setItem: (k, v) => { stored[k] = String(v); } };
global.PogAvatar = { svg: () => '<svg/>' };
global.PogMap = { create: () => ({ set: () => {} }) };
const reply = (body) => Promise.resolve({ ok: true, json: () => Promise.resolve(body) });
let stateReads = 0;
global.fetch = (url) => {
  if (url.indexOf('/v1/state') >= 0) { stateReads++; state.now += 10; return reply({ schema: 1, received: Date.now() / 1000, age_s: 4, state, site_watching: 1 }); }
  if (url.indexOf('/v1/chat') >= 0) return reply({ schema: 1, open: true, messages: [], last_seq: 0, hidden: [] });
  return reply({ schema: 1 });
};
require(process.argv[2]);
const out = {};
setTimeout(() => {
  out.board = (kids['#cb-board'] || {}).innerHTML; out.plan = (kids['#cb-plan'] || {}).innerHTML;
  // the reader opens a project, then presses "show all"
  (app.on.toggle || []).forEach((f) => f({ target: { dataset: { project: 'board:16' }, open: true } }));
  const press = { target: { closest: (sel) => (sel.indexOf('projects-all') >= 0 ? buttons[0] : null) } };
  (app.on.click || []).forEach((f) => f(press));
  out.after_press = { hidden: more.map((m) => m.hidden), text: buttons[0].textContent, aria: buttons[0].attrs['aria-expanded'], stored: stored.projectsAll };
}, 300);
setTimeout(() => {
  out.reads = stateReads;
  out.board2 = (kids['#cb-board'] || {}).innerHTML;
  process.stdout.write(JSON.stringify(out), () => process.exit(0));
}, 5800);
"""


def board_size_tests():
    """push_live.public_board keeps the board under BOARD_BYTES: finished projects' steps first, then the hidden ones',
    then the card's own cut to their next 5 open steps, each marked steps_cut."""
    sys.path.insert(0, SITE)
    import push_live
    step = lambda i, d: {"n": i, "text": "x" * 190, "done": d}
    proj = lambda i: {"id": i, "title": "t", "steps": [step(k, k < 10) for k in range(30)]}
    small = {"projects": [proj(1)], "projects_more": [], "projects_done": []}
    assert push_live.public_board(small) == small
    big = {"projects": [proj(i) for i in range(4)], "projects_more": [proj(i) for i in range(26)], "projects_done": [proj(i) for i in range(10)]}
    out = push_live.public_board(big)
    assert len(json.dumps(out)) <= push_live.BOARD_BYTES, len(json.dumps(out))
    assert all("steps" not in p and p["steps_cut"] for p in out["projects_done"] + out["projects_more"])
    assert [len(p["steps"]) for p in out["projects"]] == [30] * 4 and len(big["projects_more"][0]["steps"]) == 30  # input untouched
    huge = dict(big, projects=[dict(proj(i), steps=[step(k, k < 2) for k in range(30)], title="y" * 2000 * 8) for i in range(4)])
    out = push_live.public_board(huge)
    assert all(len(p["steps"]) == 5 and p["steps_cut"] and not any(s["done"] for s in p["steps"]) for p in out["projects"])


def main():
    board_size_tests()
    if not shutil.which("node"):
        print("projects: skipped (no node)")
        return
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    full = {"id": 16, "title": "Coal for the boilers", "owner": "opus", "agent": "opus", "status": "doing", "progress": "1 of 3 steps",
            "done": 1, "total": 3, "next": "Lay the belt", "goal": "Boilers never starve",
            "steps": [{"n": 1, "text": "Find a coal patch", "done": True, "by": "opus", "ago": "12m03s"},
                      {"n": 2, "text": "Lay the belt", "done": False, "next": True},
                      {"n": 3, "text": "Add turrets", "done": False}],
            "needs": {"iron-plate": 200}, "handoff": "Belt runs to (10,40).", "requested_by": "sol"}
    partial = {"id": 12, "title": "Laser wall", "owner": "haiku", "agent": "haiku", "status": "blocked", "progress": "0 of 2 steps",
               "done": 0, "total": 2, "next": "Research lasers", "steps": [{"n": 1, "text": "Research lasers", "done": False, "next": True}],
               "steps_partial": True}
    done = {"id": 30, "title": "Old silo", "owner": "sol", "agent": "sol", "status": "done", "progress": "1 of 1 step", "done": 1, "total": 1,
            "next": None, "steps": [{"n": 1, "text": "Build it", "done": True, "by": "sol", "ago": "2h01m"}]}
    s["board"] = dict(s.get("board") or {}, available=True, projects=[full], projects_total=2, projects_more=[partial], projects_done=[done])
    with tempfile.TemporaryDirectory() as d:
        js, path = os.path.join(d, "projects.js"), os.path.join(d, "state.json")
        open(js, "w").write(JS)
        json.dump(s, open(path, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), path], capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    for card, key in (("board", "board:16"), ("plan", "plan:16")):
        html = o[card]
        assert f'<details class="project" data-project="{key}">' in html, html
        text = re.sub(r"<[^>]+>", " ", html)
        assert "Find a coal patch" in text and "done by" in text and "12m03s ago" in text, text
        assert re.search(r'step-next[^>]*>.*Lay the belt.*next', html), html
        assert "Needs:" in text and "200 Iron plate" in text and "Handoff:" in text and "Belt runs to (10,40)." in text and "Asked by" in text, text
        # the hidden and finished ones: behind the button, hidden
        assert 'data-action="projects-all"' in html and "Show all 3 projects" in text, text
        assert re.search(r'<div class="projects-more" hidden>.*Laser wall.*Finished.*Old silo', html), html
        assert "The next open steps; the whole list comes with a later refresh." in text and ", finished" in text, text
    assert "Next:" in re.sub(r"<[^>]+>", " ", o["plan"]) and "Next:" not in re.sub(r"<[^>]+>", " ", o["board"])
    p = o["after_press"]
    assert p == {"hidden": [False, False], "text": "Show fewer projects", "aria": "true", "stored": "1"}, p
    # the next refresh: the opened project stays open, and "show all" stays on
    assert o["reads"] >= 2, o["reads"]
    assert '<details class="project" data-project="board:16" open>' in o["board2"], o["board2"]
    assert '<div class="projects-more">' in o["board2"] and "Show fewer projects" in o["board2"]
    print("projects: ok (each project opens to its steps, needs and handoff; show all lists the hidden and finished ones and is kept;"
          " an opened project stays open on refresh)")


if __name__ == "__main__":
    main()
