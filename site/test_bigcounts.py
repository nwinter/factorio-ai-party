#!/usr/bin/env python3
"""Value tiles at billions and trillions: python3 site/test_bigcounts.py

batch314 A (viewer Aurora 11:36: the shared statistic cards keep full grouped values as every counter grows; no
clipping, ellipses or rounding such as 9.43M). A made-up run whose counters reach trillions, built with build.py:
- every total and duration on the long run page, a shift page and the homepage's run summary is shown in full, grouped
  (1,234,567,890,123; 1,234h05m), never shortened to k, M, B or T and never rounded to the hour;
- each value can wrap at its group commas and after a duration's hours (<wbr>), so no tile has to clip it;
- the icon sits beside the label, apart from the number;
- the tiles' CSS sizes them to their values (flex, wrapping rows) and lets the label and sub lines wrap inside them;
- check.py passes.
The layout itself (no clipping, no horizontal scroll at desktop and phone widths, light and dark, enlarged text) was
checked in a browser for the batch314 report; this test keeps the markup and the CSS rules that layout rests on.
"""
import json, re, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))

HOUR = 216000  # ticks
T = 10 ** 12


def score(t, tick, packs, rockets, used):
    return json.dumps({"t": t, "world": "n", "score": {
        "tick": tick, "research_done": ["automation", "electronics"], "rockets": rockets, "planets": ["nauvis"],
        "produced": {"automation-science-pack": packs, "logistic-science-pack": packs // 2, "iron-plate": 7 * packs},
        "consumed": {"automation-science-pack": used, "logistic-science-pack": used}, "platforms": []}})


def make(root):
    """Two shifts, the second ending at 1,234h05m of game time with 1.2 trillion red packs made and 3.4 billion
    rockets."""
    root.mkdir(parents=True, exist_ok=True)
    for name, frm, rows in [
        ("big1", None, [score("2026-10-11T02:00:00", 100 * HOUR, 10 ** 9, 10 ** 6, 10 ** 8),
                        score("2026-10-11T06:00:00", 104 * HOUR, 2 * 10 ** 9, 2 * 10 ** 6, 2 * 10 ** 8)]),
        ("big2", "big1", [score("2026-10-11T08:00:00", 104 * HOUR, 2 * 10 ** 9, 2 * 10 ** 6, 2 * 10 ** 8),
                          score("2026-10-11T12:00:00", 1234 * HOUR + 5 * 3600, 1_234_567_890_123, 3_456_789_012, 987_654_321_098)])]:
        d = root / name
        d.mkdir()
        if frm:
            (d / "resumed-from").write_text(frm + "\n")
        (d / "scores.jsonl").write_text("\n".join(rows) + "\n")
        (d / "start.log").write_text("02:00:00 start\n")


def values(page, cls):
    return re.findall(rf'<(?:div|span) class="{cls}">(.*?)</(?:div|span)>', page)


def main():
    with tempfile.TemporaryDirectory() as d:
        root, out = Path(d) / "runs", Path(d) / "dist"
        make(root)
        content = json.loads((SITE / "content" / "site.json").read_text())
        content.update(run_start="big1", archive=False)
        (Path(d) / "site.json").write_text(json.dumps(content))
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(root),
                        "--content", str(Path(d) / "site.json"), "--stats-cache", str(Path(d) / "cache")], check=True, capture_output=True)
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout
        long_page = (out / "runs" / "long" / "index.html").read_text()
        shift = (out / "runs" / "long" / "shift-2" / "index.html").read_text()
        home = (out / "index.html").read_text()
        about = (out / "about" / "index.html").read_text()
        packs = 1_234_567_890_123 + 1_234_567_890_123 // 2  # every colour, from 0
        full = f"{packs:,}".replace(",", ",<wbr>")
        lv = values(long_page, "stat-value")
        assert full in lv, lv  # science packs, in full
        assert "3,<wbr>456,<wbr>789,<wbr>012" in lv, lv  # rockets
        assert "1,<wbr>234h<wbr>05m" in lv, lv  # game time: grouped hours, a break after them
        assert "8h<wbr>00m" in lv, lv  # on stream: hours and minutes, not "8 h"
        av = values(about, "stat-value")
        assert "3,<wbr>456,<wbr>789,<wbr>012" in av and "8h<wbr>00m" in av, av  # the About page's run totals too
        for page, name in [(long_page, "long"), (shift, "shift"), (home, "home"), (about, "about")]:
            for cls in ("stat-value", "r-val", "k-val", "bar-val"):
                for v in values(page, cls):
                    assert not re.search(r"\d(\.\d+)?\s*[kMBT]\b", v), (name, cls, v)  # never 9.43M or 12k
                    assert "…" not in v and "..." not in v, (name, cls, v)
        sv = values(shift, "stat-value")
        own = (1_234_567_890_123 - 2 * 10 ** 9) + (1_234_567_890_123 // 2 - 10 ** 9)  # the shift's packs made, red and green
        assert f"{own:,}".replace(",", ",<wbr>") in sv, sv
        # SPM and the rates in full: the shift's research units a minute, 987,454,321,098 red over its game minutes
        mins = (1234 * HOUR + 5 * 3600 - 104 * HOUR) / 3600
        spm = round((987_654_321_098 - 2 * 10 ** 8) / mins, 1)
        spm = int(spm) if spm.is_integer() else spm  # a whole rate shows no ".0"
        assert f"{spm:,}".replace(",", ",<wbr>") in sv, (spm, sv)
        assert "1,<wbr>234,<wbr>567,<wbr>890,<wbr>123" in values(long_page, "bar-val"), values(long_page, "bar-val")
        assert full in values(home, "stat-value"), values(home, "stat-value")
        # the icon beside the label, not inside the number
        m = re.search(r'<div class="stat stat-icon"><div class="stat-value">([^<]*(?:<wbr>[^<]*)*)</div><div class="stat-label"><img', long_page)
        assert m, "icon beside the label"
        assert "<img" not in "".join(lv)
        css = (SITE / "static" / "style.css").read_text()
        assert re.search(r"\.stats, \.records, \.keytimes \{ display: flex; flex-wrap: wrap;", css)
        assert re.search(r"\.stat, \.record, \.keytime \{ flex: 1 1 auto; min-width: min\(100%, 9rem\);", css)
        assert ".stat-label, .stat-sub, .r-label, .r-shift, .k-label, .k-sub { width: 0; min-width: 100%;" in css
        assert not re.search(r"\.stats[^{]*\{[^}]*grid-template-columns", css), "no fixed tile columns"
        assert ".bars li { display: flex; flex-wrap: wrap;" in css
    print("test_bigcounts: ok (tiles in full at billions and trillions, break points, icons apart, CSS rules)")


if __name__ == "__main__":
    main()
