#!/usr/bin/env python3
"""/videos/ links with an empty run in the middle: python3 site/test_videos_gap.py

d29 12:10 (batch350): runs shift96 and shift97 failed at their starts (no scores: empty rows the site does not number),
so run shift99 is the site's Shift 97. The long page's chip found run shift99's video by its run id and linked
/videos/shift-97/, while videos_page.Shelf keyed the video by its own shift field (99): no /videos/shift-97/ page was
written and check.py failed the hourly refresh. Now Shelf keys every video and R2 row by its run id's shift row.

Since d29 12:30 (Nick) the site numbers shifts by run: run shiftN is Shift N, and a run that did not play keeps its
number as an empty row marked not played, with a short page.

Made-up runs: shift01, shift02 (played), shift03 and shift04 (failed starts: no scores), shift05 and shift06 (played);
YouTube videos for shift05 and shift06 and an R2 row for shift06, each with its run's shift number, and a video for
shift03, which did not play (left out). The long page shows Shift 3 and 4 as not played, each with a short page; every
/videos/shift-N/ link on the long page, the shift pages, /videos/ and the homepage has its page; the player pages are
Shift 5 and 6, each with its own run's video; check.py passes.
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import videos_page as vp  # noqa: E402
from test_archive import score  # noqa: E402


def video(n):
    return {"id": f"VID{n:02d}xxxxx", "shift": n, "title": f"Factorio AI Party · Shift {n}: Headline {n}",
            "playlist": "PLtest", "chapters": [],
            "timeline": [["2026-10-12T14:00:00-07:00", "2026-10-12T18:00:00-07:00"]]}


def main():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        runs = d / "runs"
        runs.mkdir()

        def run(name, frm, lines):
            r = runs / name
            r.mkdir()
            if frm:
                (r / "resumed-from").write_text(frm + "\n")
            if lines:
                (r / "scores.jsonl").write_text("\n".join(lines) + "\n")
        techs = ["automation", "oil-processing"]
        run("shift01", None, [score("2026-10-12T06:00:00", 3600 * 3, techs, 20, rockets=0)])
        run("shift02", "shift01", [score("2026-10-12T10:00:00", 3600 * 63, techs, 620, rockets=1),
                                   score("2026-10-12T11:00:00", 3600 * 123, techs, 1220, rockets=2)])
        run("shift03", "shift02", [])
        run("shift04", "shift03", [])
        run("shift05", "shift04", [score("2026-10-12T14:00:00", 3600 * 124, techs, 1230, rockets=2),
                                   score("2026-10-12T15:00:00", 3600 * 184, techs, 2430, rockets=3)])
        run("shift06", "shift05", [score("2026-10-12T18:00:00", 3600 * 185, techs, 2440, rockets=3),
                                   score("2026-10-12T19:00:00", 3600 * 245, techs, 3640, rockets=4)])
        content = dict(json.loads((SITE / "content" / "site.json").read_text()), archive=False, run_start="shift01")
        (d / "site.json").write_text(json.dumps(content))
        # each video carries its run's own shift number, as the follower writes them
        (d / "videos.json").write_text(json.dumps({"shift05": video(5), "shift06": video(6), "shift03": video(3)}))
        (d / "r2.json").write_text(json.dumps({"shift06": {"shift": 6, "player": vp.player_url("shift06"), "duration_s": 3600.0}}))
        out = d / "dist"
        r = subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                            "--content", str(d / "site.json"), "--videos", str(d / "videos.json"),
                            "--r2", str(d / "r2.json")], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr[-2000:]
        long_page = (out / "runs" / "long" / "index.html").read_text()
        shift_pages = sorted(int(p.parent.name.split("-")[1]) for p in (out / "runs" / "long").glob("shift-*/index.html"))
        assert shift_pages == [1, 2, 3, 4, 5, 6], shift_pages
        for n in (3, 4):  # a short page each, linked from the long page's row
            assert f'<th scope="row"><a href="/runs/long/shift-{n}/">Shift {n}</a> <span class="muted small">not played</span>' in long_page, n
            assert f"/videos/shift-{n}/" not in long_page
            short = (out / "runs" / "long" / f"shift-{n}" / "index.html").read_text()
            assert "This shift did not play" in short and 'href="/runs/long/shift-5/">Shift 5 →' in short, short[-1500:]
            assert 'href="/runs/long/shift-2/">← Shift 2' in short and "/videos/" not in short.split("<main")[-1]
        written = sorted(int(p.parent.name.split("-")[1]) for p in (out / "videos").glob("shift-*/index.html"))
        assert written == [5, 6], written
        pages = {"long": long_page, "videos": (out / "videos" / "index.html").read_text(),
                 "home": (out / "index.html").read_text()}
        for n in shift_pages:
            pages[f"shift {n}"] = (out / "runs" / "long" / f"shift-{n}" / "index.html").read_text()
        for n in written:
            pages[f"watch {n}"] = (out / "videos" / f"shift-{n}" / "index.html").read_text()
        for name, text in pages.items():
            for n in re.findall(r'href="/videos/shift-(\d+)/', text):
                assert int(n) in written, f"{name} links /videos/shift-{n}/ with no page"
        for n in (5, 6):
            assert f'href="/videos/shift-{n}/"' in pages["long"], f"the long page's chip for Shift {n}"
            assert f'href="/videos/shift-{n}/"' in pages["home"] and f'href="/videos/shift-{n}/"' in pages["videos"]
        assert "shift06/full/master.m3u8" in pages["watch 6"], "Shift 6 plays run shift06's R2 video"
        assert "VID05xxxxx" in pages["watch 5"] and "VID03xxxxx" not in "".join(pages.values()), \
            "Shift 5 is run shift05's video; shift03's (not played) is left out"
        assert 'rel="next" href="/videos/shift-6/"' in pages["watch 5"]
        assert 'href="/runs/long/shift-5/"' in pages["shift 2"], "the shift pages' next goes past the runs that did not play"
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout[-2000:]
    print("test_videos_gap: ok")


if __name__ == "__main__":
    main()
