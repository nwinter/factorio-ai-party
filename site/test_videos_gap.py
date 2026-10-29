#!/usr/bin/env python3
"""/videos/ links with an empty run in the middle: python3 site/test_videos_gap.py

d29 12:10 (batch350): runs shift96 and shift97 failed at their starts (no scores: empty rows the site does not number),
so run shift99 is the site's Shift 97. The long page's chip found run shift99's video by its run id and linked
/videos/shift-97/, while videos_page.Shelf keyed the video by its own shift field (99): no /videos/shift-97/ page was
written and check.py failed the hourly refresh. Now Shelf keys every video and R2 row by its run id's shift row.

Made-up runs: pub1 (Shift 1), gap1 and gap2 (failed starts), pub2 (Shift 2), pub3 (Shift 3); a YouTube video and an R2
row for the runs after the gap, each with its run's own shift number (4 and 5), and a video for a run that is no
played shift (gap1: left out). Every /videos/shift-N/ link on the long page, the shift pages, /videos/ and the
homepage has its page, the pages are Shift 2 and 3, and check.py passes.
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
        run("pub1", None, [score("2026-10-12T10:00:00", 3600 * 63, techs, 620, rockets=1),
                           score("2026-10-12T11:00:00", 3600 * 123, techs, 1220, rockets=2)])
        run("gap1", "pub1", [])
        run("gap2", "gap1", [])
        run("pub2", "gap2", [score("2026-10-12T14:00:00", 3600 * 124, techs, 1230, rockets=2),
                             score("2026-10-12T15:00:00", 3600 * 184, techs, 2430, rockets=3)])
        run("pub3", "pub2", [score("2026-10-12T18:00:00", 3600 * 185, techs, 2440, rockets=3),
                             score("2026-10-12T19:00:00", 3600 * 245, techs, 3640, rockets=4)])
        content = dict(json.loads((SITE / "content" / "site.json").read_text()), archive=False, run_start="pub1")
        (d / "site.json").write_text(json.dumps(content))
        # each video carries its run's own shift number (run shift99's is 99), as the follower writes them
        (d / "videos.json").write_text(json.dumps({"pub2": video(4), "pub3": video(5), "gap1": video(2)}))
        (d / "r2.json").write_text(json.dumps({"pub3": {"shift": 5, "player": vp.player_url("pub3"), "duration_s": 3600.0}}))
        out = d / "dist"
        r = subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                            "--content", str(d / "site.json"), "--videos", str(d / "videos.json"),
                            "--r2", str(d / "r2.json")], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr[-2000:]
        long_page = (out / "runs" / "long" / "index.html").read_text()
        assert "/runs/long/shift-3/" in long_page and not (out / "runs" / "long" / "shift-4").exists(), \
            "the numbering is unchanged: the empty runs are not numbered"
        written = sorted(int(p.parent.name.split("-")[1]) for p in (out / "videos").glob("shift-*/index.html"))
        assert written == [2, 3], written
        pages = {"long": long_page, "videos": (out / "videos" / "index.html").read_text(),
                 "home": (out / "index.html").read_text()}
        for n in (1, 2, 3):
            pages[f"shift {n}"] = (out / "runs" / "long" / f"shift-{n}" / "index.html").read_text()
        for n in written:
            pages[f"watch {n}"] = (out / "videos" / f"shift-{n}" / "index.html").read_text()
        for name, text in pages.items():
            for n in re.findall(r'href="/videos/shift-(\d+)/', text):
                assert int(n) in written, f"{name} links /videos/shift-{n}/ with no page"
        for n in (2, 3):
            assert f'href="/videos/shift-{n}/"' in pages["long"], f"the long page's chip for Shift {n}"
            assert f'href="/videos/shift-{n}/"' in pages["home"] and f'href="/videos/shift-{n}/"' in pages["videos"]
        assert "VID05xxxxx" in pages["watch 3"] or 'id="pl-data"' in pages["watch 3"], "Shift 3's player: run pub3's video"
        assert "pub3/full/master.m3u8" in pages["watch 3"], "Shift 3 plays run pub3's R2 video"
        assert "VID04xxxxx" in pages["watch 2"] and "VID02xxxxx" not in "".join(pages.values()), \
            "Shift 2 is run pub2's video; gap1's video is left out"
        assert 'rel="next" href="/videos/shift-3/"' in pages["watch 2"]
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout[-2000:]
    print("test_videos_gap: ok")


if __name__ == "__main__":
    main()
