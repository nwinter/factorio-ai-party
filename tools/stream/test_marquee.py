#!/usr/bin/env python3
"""Clipped lines on the stream overlay (batch115 BX1, Nick d22 22:13): python3 tools/stream/test_marquee.py

- static/marquee.js timing under node: a line that fits never moves; one that overflows pans to its end (past the
  edge fade), holds there and pans back, then rests at its start at least 12 s and as long as it was away; the pan
  speed follows the font size; numbers alone changing keep a line's turn, new words reset it;
- the turns: ten overflowing lines over 15 minutes never have more than two away at once, start 4 s apart or more,
  each pans within 5 minutes and shows its start more than half the time;
- the DOM half under node with a minimal fake document and clock: only an overflowing line gets the edge fade and a
  pan, in turn; new text cancels a pan and rests again, a countdown does not, a line that grows to fit stops;
- the pages load marquee.js before overlay.js, and overlay.js puts the cards' job, action, wait and location lines,
  the camera labels' doing and the research card in marquees; text we control is shortened (pacing labels, spark
  item names, the subtitle's wordings), and the research card's levels share its one line under the bar.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
MQ = os.path.join(STATIC, "marquee.js")


def node(js):
    r = subprocess.run(["node", "-e", js, MQ], capture_output=True, text=True, timeout=20)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def timing():
    out = node(r"""
const m = require(process.argv[1]);
const fits = m.timeline(1, 14), zero = m.timeline(0, 14), nan = m.timeline(NaN, 14);
const short = m.timeline(60, 14), long = m.timeline(1300, 14), big = m.timeline(60, 24);
const at = (tl, t) => m.offsetAt(tl, t);
console.log(JSON.stringify({fits, zero, nan, short, long, big,
  path: [at(short, 0), at(short, short.pan / 2), at(short, short.pan + 1), at(short, short.away - 0.0001), at(short, short.away + 1)],
  keys: [m.resetKey("waiting: sleep, up to 38 s (idle 0 s)"),
         m.resetKey("GPT-6 · plan line, set 6 min ago: AQ brine"), m.resetKey("GPT-6 · plan line, set 7 min ago: AQ brine"),
         m.resetKey("GPT-6 · plan line, set 7 min ago: Gleba eggs"), m.resetKey("242 done · Levels: Mining productivity 16"),
         m.resetKey("243 done · Levels: Mining productivity 17"), m.resetKey("at 229h35, 1.5k PU")],
  hold: m.HOLD_START_S}));
""")
    assert out["fits"] is None and out["zero"] is None and out["nan"] is None  # what fits never moves
    s, l, b = out["short"], out["long"], out["big"]
    # past the clipped edge by the fade (1.5 em), so the last letters end clear of it
    assert s["dist"] == 60 + 21 and b["dist"] == 60 + 36, (s, b)
    assert abs(s["pan"] - 81 / 49) < 1e-9 and abs(b["pan"] - 96 / 84) < 1e-9  # 3.5 font sizes a second
    assert s["holdEnd"] == 2.5 and 1 <= s["back"] <= 3 and l["back"] == 3  # the way back is quicker, capped
    assert abs(s["away"] - (s["pan"] + 2.5 + s["back"])) < 1e-9
    # rest at the start between pans: 12 s at least, and as long as the pan takes for a long line (1300 px: 30 s)
    assert s["rest"] == out["hold"] == 12 and l["rest"] == l["away"] > 30, l
    assert [f["x"] for f in s["frames"]] == [0, -81, -81, 0] and s["frames"][-1]["offset"] == 1
    p = out["path"]
    assert p[0] == 0 and -81 < p[1] < 0 and p[2] == -81 and abs(p[3]) < 0.1 and p[4] == 0, p
    k = out["keys"]
    assert k[0] == "waiting: sleep, up to # s (idle # s)"
    assert k[1] == k[2] and k[2] != k[3], k  # an age ticking keeps the turn; a new job resets
    assert k[4] == k[5] and k[6] == "at #h#, #k PU", k


def turns():
    """Ten overflowing lines and two that fit, 15 minutes of pick() at 0.25 s: who moves when."""
    out = node(r"""
const m = require(process.argv[1]);
const overs = [561, 855, 1036, 743, 1028, 1027, 967, 54, 905, 570, 0, 1];   // the live cards' job lines, a wait label
const lines = overs.map((o) => ({ tl: m.timeline(o, 14), restSince: 0, moving: false, until: 0 }));
const starts = [], away = overs.map(() => 0), first = overs.map(() => null);
let last = -Infinity, maxMoving = 0;
for (let t = 0; t <= 900; t += 0.25) {
  for (const l of lines) if (l.moving && t >= l.until) { l.moving = false; l.restSince = t; }
  for (const i of m.pick(lines, t, last)) {
    const l = lines[i]; l.moving = true; l.until = t + l.tl.away; last = t; starts.push([t, i]);
    if (first[i] == null) first[i] = t;
  }
  lines.forEach((l, i) => { if (l.moving) away[i] += 0.25; });
  maxMoving = Math.max(maxMoving, lines.filter((l) => l.moving).length);
}
console.log(JSON.stringify({ starts, away, first, maxMoving, gap: m.GAP_S, max: m.MAX_MOVING }));
""")
    starts = out["starts"]
    assert out["maxMoving"] == out["max"] == 2, out["maxMoving"]  # never more than two lines away at once
    gaps = [b[0] - a[0] for a, b in zip(starts, starts[1:])]
    assert min(gaps) >= out["gap"] == 4, min(gaps)  # pans start at least 4 s apart
    assert all(i not in (10, 11) for _, i in starts)  # a line that fits never moves
    assert starts[0][0] >= 12 and all(f is not None and f < 300 for f in out["first"][:10]), out["first"]
    for i, a in enumerate(out["away"][:10]):
        assert a / 900 < 0.5, (i, a)  # every line shows its start more than half the time
    assert sorted(starts[:10], key=lambda x: x[1]) and len({i for _, i in starts[:10]}) == 10  # each in turn


def dom():
    out = node(r"""
const m = require(process.argv[1]);
let T = 0;
Object.defineProperty(globalThis, "performance", { value: { now: () => T * 1000 }, configurable: true, writable: true });
// a fake document: offsetWidth of a text span is 7 px a character, the box's clientWidth is set by the test
const anims = [];
class Classes { constructor() { this.s = new Set(); } add(c) { this.s.add(c); } remove(c) { this.s.delete(c); }
  toggle(c, on) { on ? this.s.add(c) : this.s.delete(c); } contains(c) { return this.s.has(c); } }
function node(tag) {
  return { tag, children: [], parentNode: null, isConnected: true, clientWidth: 0, classList: new Classes(),
    set className(v) { for (const c of v.split(" ")) if (c) this.classList.add(c); },
    get textContent() { return this._text || ""; }, set textContent(t) { this._text = t; },
    get offsetWidth() { return this.textContent.length * 7; },
    appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
    animate(frames, opts) { const a = { frames, opts, box: this._mqOuter, cancelled: false, cancel() { this.cancelled = true; } }; anims.push(a); return a; } };
}
global.document = { createElement: node };
global.getComputedStyle = () => ({ fontSize: "14px" });
const LONG = "a line that is much longer than its box, by far";      // 47 chars, 329 px in 140
const a = m.make("div", "model"), b = m.make("div", "model"), c = m.make("div", "model");
for (const x of [a, b, c]) x.clientWidth = 140;
const B = "a line that is much longer than its box, by 90 px";     // 49 chars, 343 px
m.set(a, "short line"); m.set(b, B); m.set(c, LONG + " too");
const r = { fits: [...a.classList.s], over: b.classList.contains("mq-over") && c.classList.contains("mq-over") };
T = 5; m.tick(); r.at5 = anims.length;                               // resting
T = 12; m.tick(); r.at12 = anims.map((x) => x.box === b);           // b's turn (rested as long, made first)
r.pan = { dist: -parseFloat(anims[0].frames[1].transform.slice(11)), iters: anims[0].opts.iterations,
  ease: anims[0].frames.map((f) => f.easing), dur: anims[0].opts.duration };
T = 13; m.tick(); r.at13 = anims.length;                             // 4 s between starts
T = 16; m.tick(); r.at16 = anims.length && anims[1].box === c;
m.set(c, LONG + " now");                                              // new words while panning: back to the start
r.reset = anims[1].cancelled;
T = 20; m.tick(); r.at20 = anims.length;                              // c rests 12 s again; a fits; b still away
m.set(b, B.replace("90", "123"));                                     // numbers only: b keeps going
r.keep = !anims[0].cancelled;
anims[0].onfinish(); T = 21;                                          // b back at its start
T = 28; m.tick(); r.at28 = anims.length;                             // c has rested 12 s since 16: its turn
r.at28c = anims[2] && anims[2].box === c;
c.clientWidth = 400; m.measure(c);                                    // its box grew: it fits, stops, no fade
r.grown = { cancelled: anims[2].cancelled, over: c.classList.contains("mq-over") };
const plain = { textContent: "" }; m.set(plain, "x"); r.plain = plain.textContent;  // no span: plain text
console.log(JSON.stringify(r));
""")
    assert out["fits"] == ["model", "mq"] and out["over"], out
    assert out["at5"] == 0 and out["at12"] == [True], out
    assert out["pan"]["dist"] == 343 - 140 + 21 and "iters" not in out["pan"], out["pan"]  # one pan, then rest
    e = out["pan"]["ease"]
    assert e[0] != "linear" and e[2] != "linear" and e[1] == e[3] == "linear", e  # eased moves, still holds
    assert out["at13"] == 1 and out["at16"] is True and out["reset"] is True and out["at20"] == 2, out
    assert out["keep"] is True and out["at28"] == 3 and out["at28c"] is True, out
    assert out["grown"] == {"cancelled": True, "over": False} and out["plain"] == "x", out


def pages():
    for page in ("index.html", "portrait.html"):
        html = open(os.path.join(STATIC, page)).read()
        assert html.index("/static/marquee.js") < html.index("/static/overlay.js"), page
    js = open(os.path.join(STATIC, "overlay.js")).read()
    for line in ('c.model = mqEl("div", "model")', 'c.txt = mqEl("span", "txt")', 'c.waitLabel = mqEl("span", "wait-label")',
                 'c.where = mqEl("span", "where")', 'label._doing = mqEl("span", "doing")', 'researchCard.tech = mqEl("div", "tech")',
                 'researchCard.recent = mqEl("div", "recent")', "if (MQ) MQ.refresh(c.model);", 'if (levels) rb.append(',
                 '"low-density-structure": "Low density"', "fitText($(\"subtitle\")"):
        assert line in js, line
    assert "researchCard.levels" not in js
    css = open(os.path.join(STATIC, "overlay.css")).read()
    assert ".mq { overflow: hidden; white-space: nowrap; text-overflow: clip !important;" in css
    assert "-webkit-mask-image" in css and ".research .levels" not in css
    assert ".card.squeezed .tok { display: none; }" in open(os.path.join(STATIC, "portrait.css")).read()
    subprocess.run(["node", "--check", MQ], check=True)
    subprocess.run(["node", "--check", os.path.join(STATIC, "overlay.js")], check=True)
    sys.path.insert(0, HERE)
    import pacing
    t = 1792732165  # a 1080p card's line holds about 34 characters: a rest today, a quota rest days away
    for row, now in (({"until": t, "reason": "pace"}, t), ({"until": t, "reason": "quota"}, t - 3 * 86400)):
        assert len(pacing.label(row, now)) <= 34, pacing.label(row, now)


def main():
    if not shutil.which("node"):
        print("marquee: skip (node unavailable)")
        return
    timing()
    turns()
    dom()
    pages()
    print("marquee: ok (fits stay still, overflow rests at the start and pans, two lines at a time, numbers keep the turn; "
          "short labels)")


if __name__ == "__main__":
    main()
