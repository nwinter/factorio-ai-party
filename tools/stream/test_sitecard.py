#!/usr/bin/env python3
"""The site's address on some segment cards (Nick, YouTube chat Oct 14 22:02; d17 C1): python3 tools/stream/test_sitecard.py

- segments.py: every site_every-th accepted segment that is not a replay carries "site" (default every 2nd); replays
  neither carry it nor count; site_every=0 turns it off; it is outside "facts" (the casters read facts) and in the
  public snapshot only for the segment that has it;
- overlay.js in a stub DOM (needs node): a card with "site" gets one small line "More on the run: ADDRESS" between the
  body and the time bar; a card without it has none.
"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from segments import SITE, Segments  # noqa: E402

SNAP = {"agents": [{"name": "astra", "alive": True, "position": {"x": 0, "y": 0}},
                   {"name": "sol", "alive": True, "position": {"x": 40, "y": 30}}]}


class FakeReplays:
    clip = {"kind": "loss", "label": "3 lost near (5, 5): 3 gun turret (by big spitters)"}

    def why(self, now):
        return None

    def facts(self, now):
        return {"event": self.clip["label"], "kind": "loss"}, dict(self.clip)


def accept(seg, kind, now):
    code, rep = seg.request({"type": kind}, now, ignore_spacing=kind == "attack_replay")
    assert code == 200, (kind, rep)
    out = seg.queue
    seg.queue = None  # as if it ran and ended
    return out


def segments_part():
    seg = Segments(spacing=0, lull_after=1e9, urgent_quiet=0)
    seg.snap = SNAP
    seg.replays = FakeReplays()
    t = 1792200000.0
    kinds = ["overview", "spotlight", "attack_replay", "overview", "spotlight", "overview"]
    got = []
    for i, k in enumerate(kinds):
        s = accept(seg, k, t + i * 200)
        got.append((k, s.get("site")))
        assert "site" not in s["facts"] and SITE not in json.dumps(s["facts"]), s["facts"]
    # the 2nd and 4th non-replay segments: the replay neither has it nor moves the count
    assert got == [("overview", None), ("spotlight", SITE), ("attack_replay", None), ("overview", None),
                   ("spotlight", SITE), ("overview", None)], got
    # public(): "site" only when the current segment has it
    seg.cur = dict(accept(seg, "spotlight", t + 5000), state="live", started=t, ends=t + 30)
    assert seg.public()["site"] == SITE
    seg.cur = None
    seg.cur = dict(accept(seg, "overview", t + 5200), state="live", started=t, ends=t + 30)
    assert "site" not in seg.public()
    off = Segments(spacing=0, lull_after=1e9, urgent_quiet=0, site_every=0)
    off.snap = SNAP
    assert all(accept(off, "overview", t + i * 200).get("site") is None for i in range(4))
    assert SITE == "factorio.nickwinter.net"


OVERLAY_STUB = r"""
// overlay.js's renderSegment in a stub DOM: argv[2] overlay.js. Prints the card's lines for two segments.
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const start = src.indexOf('  function renderSegment(s) {');
const end = src.indexOf('  function segTick() {');
function mk(tag, cls, text) {
  const e = { tag, className: cls || '', textContent: text || '', kids: [], hidden: true, dataset: {}, style: {},
    classList: { add() {}, remove() {}, contains: () => false, toggle() {} },
    append(...k) { this.kids.push(...k); }, prepend(...k) { this.kids.unshift(...k); } };
  Object.defineProperty(e, 'firstChild', { get() { return this.kids[0] || { style: {} }; } });
  return e;
}
const box = mk('div', '');
global.document = { body: mk('body') };
global.window = {};
const $ = () => box;
const el = (tag, cls, text) => mk(tag, cls, text);
const FULL = {};
const isFull = (seg) => !!FULL[seg.type];
const segmentBody = () => mk('div', 'sbody', 'body');
const applyPalette = () => {}, avatar = () => mk('img');
const hideSegment = () => {};
let ticks = 0;
const segTick = () => { ticks++; };
eval(src.slice(start, end));
const lines = (b) => b.kids[b.kids.length - 1].kids.map((k) => [k.className, k.textContent]);
const out = {};
const base = { type: 'overview', state: 'live', title: 'Base overview', facts: {}, started: 100, ends: 120 };
renderSegment({ now: 105, segment: Object.assign({ id: 'seg-1', site: 'factorio.nickwinter.net' }, base), agents: [] });
out.with = lines(box);
renderSegment({ now: 205, segment: Object.assign({ id: 'seg-2' }, base, { started: 200, ends: 220 }), agents: [] });
out.without = lines(box);
process.stdout.write(JSON.stringify(out));
"""


def overlay_part():
    if not shutil.which("node"):
        print("sitecard: overlay part skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "card.cjs")
        open(js, "w").write(OVERLAY_STUB)
        r = subprocess.run(["node", js, os.path.join(HERE, "static", "overlay.js")], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    o = json.loads(r.stdout)
    assert [c for c, _ in o["with"]] == ["stitle", "sbody", "ssite", "stime"], o["with"]
    assert o["with"][2][1] == "More on the run: factorio.nickwinter.net", o["with"]
    assert [c for c, _ in o["without"]] == ["stitle", "sbody", "stime"], o["without"]
    css = open(os.path.join(HERE, "static", "overlay.css")).read()
    assert re.search(r"#segment \.ssite \{ font-size: 15px;", css) and re.search(r"#segment\.full \.ssite \{ font-size: 20px;", css)


def main():
    segments_part()
    overlay_part()
    print("sitecard: ok (every 2nd non-replay segment card carries the site's address, outside the casters' facts; "
          "the card shows it as one small line above the time bar)")


if __name__ == "__main__":
    main()
