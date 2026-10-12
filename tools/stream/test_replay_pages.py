#!/usr/bin/env python3
"""The replay on the overlay pages, under node: python3 tools/stream/test_replay_pages.py

1. The stream page's replay card (static/segview.js, used by overlay.js renderSegment) shows only while the replay
   segment is "starting" (the 2.5 s before the program cuts to the replay scene), not while it is live or after.
"""
import json, os, re, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")


def node(script):
    r = subprocess.run(["node", "-e", script], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def card_tests():
    cases = [(None, False),
             ({"type": "attack_replay", "state": "starting"}, True),
             ({"type": "attack_replay", "state": "live"}, False),   # the replay scene is on air: no card under it
             ({"type": "attack_replay", "state": "ended"}, False),
             ({"type": "production", "state": "starting"}, True),
             ({"type": "production", "state": "live"}, True),
             ({"type": "spotlight", "state": "ended"}, False)]
    got = node(f"const s = require({json.dumps(os.path.join(STATIC, 'segview.js'))});"
               f"console.log(JSON.stringify({json.dumps([c for c, _ in cases])}.map(s.cardVisible)))")
    assert got == [want for _, want in cases], list(zip(cases, got))
    for page in ("index.html", "portrait.html"):
        html = open(os.path.join(STATIC, page)).read()
        srcs = re.findall(r'<script src="/static/([^"]+)"', html)
        assert "segview.js" in srcs and srcs.index("segview.js") < srcs.index("overlay.js"), (page, srcs)
    assert "pogSeg.cardVisible(seg)" in open(os.path.join(STATIC, "overlay.js")).read()


BANNER_HARNESS = r"""
// replay.html's script with a stand-in DOM, clock, timers and event stream
const html = require("fs").readFileSync(process.argv[1], "utf8");
const code = html.match(/<script>([\s\S]*?)<\/script>/)[1];
let now = 1e12;
const els = {};
const el = () => ({ textContent: "", style: {}, firstChild: { style: {} } });
for (const id of ["frame", "bar", "what", "ago", "time"]) els[id] = el();
const classes = new Set();
const document = { getElementById: (id) => els[id],
  body: { classList: { toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)), contains: (c) => classes.has(c) } } };
const timers = [];
let es = null;
class EventSource { constructor(u) { es = this; this.url = u; } }
const Date_ = { now: () => now };
new Function("document", "EventSource", "setInterval", "fetch", "Date", "console", code)(
  document, EventSource, (f, ms) => timers.push(f), () => Promise.reject(new Error("offline")), Date_, console);
const send = (s) => es.onmessage({ data: JSON.stringify(s) });
const run = (ms) => { now += ms; timers.forEach((f) => f()); };
const width = () => parseFloat(els.time.firstChild.style.width || "0");
const out = {};
const seg = { id: "seg-9", type: "attack_replay", started: 1000, ends: 1017.5, title: "Replay: Luna died",
  facts: { event: "Luna died", ago_s: 30 } };
send({ now: 1001, segment: Object.assign({}, seg, { state: "starting" }) });
run(200);
out.starting_on = classes.has("on");                     // the stream page has the card then; the banner waits
send({ now: 1002.5, segment: Object.assign({}, seg, { state: "live" }) });
run(0);
out.live_start = [classes.has("on"), width(), els.what.textContent];
run(3000);                                                // no snapshot for 3 s: the bar keeps moving
out.after_3s = width();
send({ now: 1005.5, segment: Object.assign({}, seg, { state: "live" }) });  // a late snapshot does not reset it
run(0);
out.after_3s_snapshot = width();
run(9000);
out.after_12s = [width(), els.ago.textContent];
run(4000);                                                // past the end with no snapshot: the banner goes
out.after_end_on = classes.has("on");
console.log(JSON.stringify(out));
"""


def banner_tests():
    r = subprocess.run(["node", "-e", BANNER_HARNESS, os.path.join(STATIC, "replay.html")], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["starting_on"] is False, out
    on, w0, what = out["live_start"]
    assert on and w0 == 0 and what == "Luna died", out
    assert abs(out["after_3s"] - 20.0) < 0.2, out  # 3 s of a 15 s replay
    assert abs(out["after_3s_snapshot"] - 20.0) < 0.2, out
    w12, ago = out["after_12s"]
    assert abs(w12 - 80.0) < 0.2 and ago == "45 s ago", out  # 30 s ago when queued + 2.5 starting + 12 = 44.5
    assert out["after_end_on"] is False, out


def main():
    card_tests()
    banner_tests()
    print("replay pages: ok (card only while starting; banner bar on its own clock, moving between snapshots, "
          "gone at the end)")


if __name__ == "__main__":
    main()
