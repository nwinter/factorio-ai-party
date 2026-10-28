#!/usr/bin/env python3
"""The long run's charts: python3 site/test_longcharts.py

batch314 B (viewer Aurora 11:37: larger plots, shift labels that do not collide in a strip of their own, one range for
every chart, clickable pack legends, exact values and tables, the data's cutoff, missing periods made clear, the
10-game-minute samples apart from any smoothing). A made-up run of 30 shifts, rows every 2 game minutes:
- longrun.load: a hole of an hour with no score rows is listed (gaps) and no 10-minute window spans it; a shift whose log
  reads game time already read (back 30 minutes, then on to where the last one ended) has those rows left out of the
  totals, charts and firsts (replays), so its packs are not counted twice; the cutoff is the last row read;
- the page: one chart a row, the range bar (full run, the last 10 shifts, each shift with its game-time range), the
  notes (cutoff, the hole, the replay, what a point is and what the average is), each chart's data with its shift
  marks, the hole and whether it offers the average; the SVG without the script labels every k-th shift start in a
  strip under the axis with no two labels closer than a label's width, shades the hole and breaks the line there; the
  tables give exact values; the shift page names its replay;
- site.js under node: the helpers the drawing uses (the label step, the 1-game-hour mean, which starts again after a
  hole, the range ticks).
"""
import json, re, shutil, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import longrun  # noqa: E402

MIN = 3600  # ticks a game minute


def row(t, minute, red, used, research=("automation",), rockets=0):
    return json.dumps({"t": t, "world": "n", "score": {
        "tick": minute * MIN, "research_done": list(research), "rockets": rockets, "planets": ["nauvis"], "platforms": [],
        "produced": {"automation-science-pack": red}, "consumed": {"automation-science-pack": used}}})


def make(root):
    """30 shifts of 240 game minutes, a row every 2 (red packs made: 10 a minute; the labs use 6 a minute). Shift 5 has
    no rows for its game minutes 1000-1060. Shift 9 begins 30 minutes behind where shift 8 ended (its counters back
    with it), reads 20 minutes, then jumps to where shift 8 ended and goes on."""
    import datetime
    t0 = datetime.datetime(2026, 10, 1, 0, 0)
    minute, name_prev = 0, None
    for k in range(1, 31):
        name = f"lr{k:02d}"
        d = root / name
        d.mkdir(parents=True)
        if name_prev:
            (d / "resumed-from").write_text(name_prev + "\n")
        lines, start = [], minute
        if k == 9:
            for m in range(start - 30, start - 10, 2):
                lines.append(row((t0 + datetime.timedelta(minutes=len(lines) * 2 + k * 300)).isoformat(), m, 10 * m, 6 * m))
        for m in range(start, start + 240 + 1, 2):
            if k == 5 and 1000 < m < 1060:
                continue
            lines.append(row((t0 + datetime.timedelta(minutes=len(lines) * 2 + k * 300)).isoformat(), m, 10 * m, 6 * m))
        (d / "scores.jsonl").write_text("\n".join(lines) + "\n")
        (d / "start.log").write_text("00:00:00 start\n")
        minute, name_prev = start + 240, name
    return minute


def check(name, cond, info=""):
    assert cond, f"{name}: {info}"


def main():
    with tempfile.TemporaryDirectory() as d:
        root, out = Path(d) / "runs", Path(d) / "dist"
        end = make(root)
        lr = longrun.load(root, start="lr01")
        check("gaps", [(g["x0"], g["x1"], g["shift"]) for g in lr["gaps"]] == [(1000.0, 1060.0, 5)], lr["gaps"])
        check("replays", [(r["shift"], r["rows"], r["game0"], r["behind"]) for r in lr["replays"]] == [(9, 10, "31h30m", "0h30m")], lr["replays"])
        check("made once", sum(lr["made"].values()) == 10 * end, (sum(lr["made"].values()), 10 * end))
        check("cutoff", lr["cutoff"]["x"] == end and lr["cutoff"]["shift"] == 30, lr["cutoff"])
        # no window spans the hole: none ends inside it, the first after it ends 10+ minutes after it
        xs = [x for x, _ in lr["spm"]]
        check("no window over the hole", not any(1000 < x < 1070 for x in xs), [x for x in xs if 990 < x < 1090])
        check("spm", all(abs(v - 6.0) < 0.01 for _, v in lr["spm"]), set(v for _, v in lr["spm"]))
        s9 = next(s for s in lr["shifts"] if s["n"] == 9)
        check("shift 9 game time", (s9["game0"], s9["made_total"]) == (longrun.game_time(8 * 240 * MIN), 2400), (s9["game0"], s9["made_total"]))

        content = json.loads((SITE / "content" / "site.json").read_text())
        content.update(run_start="lr01", archive=False)
        (Path(d) / "site.json").write_text(json.dumps(content))
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(root),
                        "--content", str(Path(d) / "site.json"), "--stats-cache", str(Path(d) / "cache")], check=True, capture_output=True)
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        check("check.py", r.returncode == 0, r.stdout)
        page = (out / "runs" / "long" / "index.html").read_text()
        check("one chart a row", 'class="chart-grid chart-grid-wide"' in page)
        bar = re.search(r'<div class="chart-range".*?</div>', page, re.S).group(0)
        check("range buttons", 'data-range="full" aria-pressed="true">Full run' in bar and 'data-range="recent" data-lo="4800.0' in bar, bar[:300])
        opts = re.findall(r'<option value="(\d+)" data-lo="([\d.]+)" data-hi="([\d.]+)">Shift', bar)
        check("a range per shift", len(opts) == 30 and opts[8] == ("9", "1920.0", "2160.0") and opts[-1][2] == str(float(end)), opts[8:10] + opts[-1:])
        check("average box", 'data-smooth' in bar)
        notes = re.search(r'<ul class="chart-notes[^>]*>(.*?)</ul>', page, re.S).group(1)
        check("cutoff note", f"Data to game time {longrun.game_time(end * MIN)}: the last score row read" in notes and "shift 30" in notes, notes)
        check("hole note", "No score rows from game time 16h40m to 17h40m" in notes and "shift 5): shaded, the lines broken there" in notes, notes)
        check("replay note", "Shift 9 read game time 31h30m to 31h48m again (10 score rows" in notes
              and "the game time went back 0h30m" in notes and "no game time counts twice" in notes, notes)
        check("samples apart from the average", "The 1-game-hour average, when shown, is a separate line" in notes, notes)
        figs = re.findall(r'<figure class="chart" id="c\d+">.*?</figure>', page, re.S)
        check("five charts", len(figs) == 5, len(figs))
        spm = figs[0]
        data = json.loads(re.search(r'<script type="application/json" class="chart-data">(.*?)</script>', spm, re.S).group(1))
        check("chart data", len(data["marks"]) == 30 and data["gaps"] == [[1000.0, 1060.0]] and data["smooth"] is True and data["hours"] is True,
              (len(data["marks"]), data["gaps"], data["smooth"]))
        tech = json.loads(re.search(r'class="chart-data">(.*?)</script>', figs[3], re.S).group(1))
        check("no average on a count", tech["smooth"] is None and tech["step"] is True)
        # the static SVG: labels thinned in the strip, none closer than a label's width; a tick per shift start
        labels = [float(x) for x in re.findall(r'<text class="mark-label" x="([\d.]+)"', spm)]
        ticks = re.findall(r'<line class="mark-tick"', spm)
        check("a tick a shift", len(ticks) == 30, len(ticks))
        check("labels thinned", 2 <= len(labels) < 30 and all(b - a >= 7.2 * 3 + 8 for a, b in zip(labels, labels[1:])), labels)
        check("labels under the axis", 'S2</text>' in spm and 'S30</text>' in spm and 'S3</text>' not in spm)
        check("hole shaded", '<rect class="gap"' in spm and "No score rows 16h40m to 17h40m" in spm)
        path = re.search(r'<path class="line"[^>]* d="([^"]+)"', spm).group(1)
        check("line broken at the hole", path.count("M") == 2, path.count("M"))
        rows = re.findall(r"<tr><td>[^<]+</td><td>([^<]*)</td></tr>", figs[4])
        check("table exact", rows and all(re.fullmatch(r"[\d,]+(\.\d+)?", v) for v in rows if v), rows[:5])
        shift9 = (out / "runs" / "long" / "shift-9" / "index.html").read_text()
        check("shift page replay note", "The score log read game time 31h30m to 31h48m again in this shift (10 rows" in shift9)

        if shutil.which("node"):
            js = Path(d) / "t.js"
            js.write_text("""
global.window = { addEventListener() {}, matchMedia() { return { matches: false }; } };
const none = () => null, empty = () => [];
global.document = { documentElement: { dataset: {} }, querySelector: none, querySelectorAll: () => ({ forEach() {} }),
  getElementById: none, addEventListener() {}, createElementNS() { return {}; } };
global.sessionStorage = { getItem: none, setItem() {} }; global.localStorage = global.sessionStorage;
require(process.argv[2]);
const C = window.PogCharts, ok = (n, c, i) => { if (!c) { console.error(n, JSON.stringify(i)); process.exit(1); } };
// a label step: 30 starts 20 px apart, labels 30 px wide: every 2nd; 92 starts 10 px apart: every 5th
const xs = Array.from({ length: 30 }, (_, i) => i * 20), nums = xs.map((_, i) => i + 1);
ok('step 2', C.markStep(xs, nums, 30) === 2, C.markStep(xs, nums, 30));
const xs2 = Array.from({ length: 92 }, (_, i) => i * 10), n2 = xs2.map((_, i) => i + 1);
ok('step 5', C.markStep(xs2, n2, 45) === 5, C.markStep(xs2, n2, 45));
// the hour mean: windows 10 minutes apart; a hole starts it again
const pts = [[10, 6], [20, 12], [30, 6], [40, 12], [50, 6], [60, 12], [70, 6], [80, 12], [200, 30], [210, 10]];
const m = C.hourMean(pts, [[85, 190]]);
ok('mean of the hour', m[6][1] === 9 && m[6][2] === 6, m[6]);  // the windows ending 20..70: the hour 10..70
ok('window drops out', m[7][2] === 6 && m[7][1] === 9, m[7]);  // 30..80
ok('after a hole', m[8][1] === 30 && m[8][2] === 1 && m[9][1] === 20 && m[9][2] === 2, m.slice(8));
ok('crosses', C.crosses([[85, 190]], 80, 200) && !C.crosses([[85, 190]], 70, 80), 0);
const t = C.rangeTicks(0, 21500, 8);
ok('range ticks', t[0] === 0 && t[1] - t[0] === 3000 && t.length <= 9, t);
ok('nice ticks', JSON.stringify(C.niceTicks(169.5, 5)) === '[0,50,100,150,200]', C.niceTicks(169.5, 5));
console.log('ok');
""")
            r = subprocess.run(["node", str(js), str(SITE / "static" / "site.js")], capture_output=True, text=True, timeout=30)
            check("site.js helpers", r.returncode == 0 and r.stdout.strip() == "ok", r.stderr[-800:] + r.stdout[-200:])
        else:
            print("site.js helpers: skipped (no node)")
    print("test_longcharts: ok (holes, replays, cutoff, range bar, notes, shift strip, exact tables, site.js helpers)")


if __name__ == "__main__":
    main()
