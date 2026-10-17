#!/usr/bin/env python3
"""The site's poll on the stream (pollstrip.py, overlay.js renderPollStrip, the hosts' fact): python3 tools/stream/test_pollstrip.py

- the strip while a poll is open: 30 s every 10 minutes from its opening, the top counts with viewers and agents
  apart, "Vote at factorio.nickwinter.net"; two open polls take turns; no intro or option details;
- when it closes (moved to the closed list, or its time ran out before the next read): its result for 60 s, once;
  a poll that closed before serve.py started, or long ago, shows nothing; stale poll data shows nothing;
- the hosts get the open poll's question, counts and where to vote, and not again for 20 minutes once a line of
  theirs mentions it;
- overlay.js draws the strip with textContent (a question with markup stays text) and hides it without one.
"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pollstrip  # noqa: E402

T0 = 1792200000.0


def poll(pid=1, opens=T0, hours=12, status="open", counts=(3, 1, 2), agents=(1, 0, 0)):
    viewers = [c - a for c, a in zip(counts, agents)]
    return {"id": pid, "question": f"Question {pid}?", "intro": "INTRO TEXT", "options": ["No", "Ideas only", "Yes"],
            "details": ["DETAIL A", "", "DETAIL C"], "counts": list(counts), "total": sum(counts), "viewer_counts": viewers,
            "viewer_total": sum(viewers), "agent_counts": list(agents), "agent_total": sum(agents), "opens": opens,
            "closes": opens + hours * 3600, "status": status, "left_s": 0, "comments": []}


def strip_at(ps, data, now):
    ps.data, ps.path = dict(data, fetched=now - 5), None
    out = ps.step(now)
    return out and out["strip"]


def timing():
    ps = pollstrip.PollStrip(None, url="factorio.nickwinter.net")
    data = {"open": [poll()], "closed": []}
    s = strip_at(ps, data, T0 + 1)
    assert s and s["kind"] == "open" and s["url"] == "factorio.nickwinter.net" and s["question"] == "Question 1?", s
    assert [(r["label"], r["n"], r["viewers"], r["agents"]) for r in s["rows"]] == [("No", 3, 2, 1), ("Yes", 2, 2, 0), ("Ideas only", 1, 1, 0)]
    assert "INTRO" not in json.dumps(s) and "DETAIL" not in json.dumps(s)
    assert strip_at(ps, data, T0 + 29)["kind"] == "open"
    assert strip_at(ps, data, T0 + 31) is None and strip_at(ps, data, T0 + 599) is None
    assert strip_at(ps, data, T0 + 600)["kind"] == "open" and strip_at(ps, data, T0 + 631) is None
    shown = sum(1 for t in range(0, 3600, 5) if strip_at(ps, data, T0 + t))
    assert shown == 6 * 6, shown  # 30 s of every 10 min: 6 steps of 5 s, 6 times an hour
    # two open polls take turns
    two = {"open": [poll(), poll(2, opens=T0 + 100)], "closed": []}
    assert strip_at(ps, two, T0 + 5)["id"] == 1 and strip_at(ps, two, T0 + 605)["id"] == 2 and strip_at(ps, two, T0 + 1205)["id"] == 1
    # the operator closes poll 1 early: its result for 60 s, once, then poll 2's windows go on
    ps = pollstrip.PollStrip(None)
    strip_at(ps, two, T0 + 700)
    closed = {"open": [poll(2, opens=T0 + 100)], "closed": [dict(poll(), status="closed", closes=T0 + 705, counts=[4, 1, 2])]}
    r = strip_at(ps, closed, T0 + 710)
    assert r["kind"] == "result" and r["id"] == 1 and r["rows"][0]["label"] == "No" and r["total"] == 6, r
    assert strip_at(ps, closed, T0 + 769)["kind"] == "result"
    assert strip_at(ps, closed, T0 + 771) is None  # 60 s; poll 2's windows now count from its opening (T0 + 100)
    assert strip_at(ps, closed, T0 + 1205) is None and strip_at(ps, closed, T0 + 1305)["id"] == 2
    # time runs out before the next read (still listed open): the result too
    ps = pollstrip.PollStrip(None)
    one = {"open": [poll(hours=1)], "closed": []}
    strip_at(ps, one, T0 + 3500)
    assert strip_at(ps, one, T0 + 3605)["kind"] == "result"
    # started after it closed, or long after: nothing
    ps = pollstrip.PollStrip(None)
    assert (strip_at(ps, closed, T0 + 710) or {}).get("kind") != "result"  # poll 2 may be in its window
    # stale data: nothing at all
    ps = pollstrip.PollStrip(None)
    ps.data, ps.path = dict(data, fetched=T0 - 1000), None
    assert ps.step(T0) is None


def file_read():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "polls.json")
        ps = pollstrip.PollStrip(path)
        assert ps.step(T0) is None  # no file
        json.dump({"fetched": T0, "open": [poll()], "closed": []}, open(path, "w"))
        out = ps.step(T0 + 2)
        assert out["strip"]["kind"] == "open" and out["open"][0]["counts"] == [3, 1, 2] and "intro" not in out["open"][0], out


def hosts():
    s = {"poll": {"open": [{"id": 1, "question": "Should the AI team use blueprints made by people?", "options": ["No", "Yes"],
                            "counts": [5, 2], "viewer_counts": [4, 2], "agent_counts": [1, 0], "total": 7, "closes": T0 + 7200}]}}
    f = pollstrip.host_facts(s, 0, T0)
    assert f["question"].startswith("Should the AI team") and f["options"]["No"] == {"votes": 5, "from_viewers": 4, "from_agents": 1}, f
    assert f["closes_in_minutes"] == 120 and f["where_viewers_vote"] == "factorio.nickwinter.net"
    assert pollstrip.host_facts(s, T0 - 19 * 60, T0) is None and pollstrip.host_facts(s, T0 - 21 * 60, T0)
    assert pollstrip.host_facts({"poll": None}, 0, T0) is None and pollstrip.host_facts({}, 0, T0) is None
    assert pollstrip.mentioned(["Viewers, the poll is open"]) and pollstrip.mentioned(["Seven votes so far."])
    assert not pollstrip.mentioned(["Luna polled the furnaces"]) and not pollstrip.mentioned(["Iron is flowing again."])
    # the caster offers it on a beat and stops for 20 minutes once a line mentions it
    src = open(os.path.join(HERE, "caster.py")).read()
    assert 'facts["site_poll"] = poll' in src and "self.poll_said = time.time()" in src


OVERLAY_JS = r"""
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const body = src.slice(src.indexOf('  let pollKey = ""'), src.indexOf('  // Widgets under the cards'));
function node(tag) { return { tag, className: '', textContent: '', hidden: false, kids: [],
  append(...k) { this.kids.push(...k); }, replaceChildren() { this.kids = []; } }; }
const box = node('div'); box.hidden = true;
const $ = (id) => (id === 'poll-strip' ? box : null);
function el(tag, cls, text) { const e = node(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
const f = new Function('$', 'el', body + '; return renderPollStrip;')($, el);
const flat = (n) => [n.textContent].concat(...n.kids.map(flat)).filter(Boolean);
const out = {};
f({ poll: { strip: { kind: 'open', id: 1, question: 'Blueprints <b>by</b> people?', rows: [{ label: 'No', n: 3, viewers: 2, agents: 1 }],
  total: 3, viewer_total: 2, agent_total: 1, url: 'factorio.nickwinter.net' } } });
out.open = { hidden: box.hidden, cls: box.className, text: flat(box) };
f({ poll: { strip: { kind: 'result', id: 1, question: 'Q?', rows: [{ label: 'No', n: 4, viewers: 3, agents: 1 }], total: 4, viewer_total: 3, agent_total: 1, url: 'factorio.nickwinter.net' } } });
out.result = { cls: box.className, text: flat(box) };
f({ poll: null });
out.none = box.hidden;
process.stdout.write(JSON.stringify(out));
"""


def overlay():
    for page in ("index.html", "portrait.html"):
        html = open(os.path.join(HERE, "static", page)).read()
        assert re.search(r'<div id="chat-list"></div>\s*<div id="poll-strip" hidden></div>', html), page
    if not shutil.which("node"):
        print("poll strip: overlay part skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "strip.cjs")
        open(js, "w").write(OVERLAY_JS)
        r = subprocess.run(["node", js, os.path.join(HERE, "static", "overlay.js")], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    assert o["open"]["hidden"] is False and o["open"]["cls"] == "poll-strip ps-open", o
    assert o["open"]["text"] == ["POLL", "Blueprints <b>by</b> people?", "No", "3", "viewers 2 · agents 1", "Vote at factorio.nickwinter.net"], o
    assert o["result"]["cls"] == "poll-strip ps-result" and "POLL RESULT" in o["result"]["text"], o
    assert "4 votes · viewers 3 · agents 1" in o["result"]["text"] and " · factorio.nickwinter.net/polls" in o["result"]["text"], o
    assert o["none"] is True


def main():
    timing()
    file_read()
    hosts()
    overlay()
    print("poll strip: ok (30 s every 10 min while open, polls take turns, the result for 60 s once, nothing stale; "
          "the hosts' fact at most once in 20 minutes; the overlay draws it as text)")


if __name__ == "__main__":
    main()
