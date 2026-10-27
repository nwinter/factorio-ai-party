#!/usr/bin/env python3
"""/videos/ (site/videos_page.py) on made-up shifts: python3 site/test_videos_page.py

- R2: a shift is listed only when its receipt is for the whole shift and its master playlist answers 200 (a 404 or
  no answer leaves it out); the player URL is the r2.dev player with the shift's playlist, data and captions;
- the page: the three public videos first (shift 1, shift 63, the latest), every shift in order with its title,
  date, length (the video's, else R2's, else the shift's), YouTube in the playlist, the archive player only where
  R2 has the shift, a shift with neither says the video comes later; chapters link into the video; a chapter or
  title naming the stream owner never reaches the page; moments to watch link a minute before the moment;
- thumbnails: a shift-N.jpg only when the shift has one, else a text label.
"""
import html
import json
import re
import sys
import tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import videos_page as vp  # noqa: E402

OWNER = re.compile(r"(?i)\bnick(?:\s*winter)?\b")


def shift(n, started, ended):
    return {"n": n, "id": f"shift{n:02d}", "started": started, "ended": ended, "game0": f"{n}h00m", "game1": f"{n + 4}h00m"}


def video(n, chapters=(), timeline=None):
    return {"id": f"VID{n:02d}xxxxx", "shift": n, "title": f"Factorio AI Party · Shift {n}: Headline {n}",
            "playlist": "PLtest", "chapters": list(chapters),
            "timeline": timeline or [["2026-10-12T14:00:00-07:00", "2026-10-12T18:00:00-07:00"]]}


def helpers():
    import datetime

    def pt(t):
        return datetime.datetime.fromisoformat(t).strftime("%b %-d, %H:%M")

    def hours(a, b):
        return (datetime.datetime.fromisoformat(b) - datetime.datetime.fromisoformat(a)).total_seconds() / 3600
    return {"esc": lambda s, quote=True: html.escape(str(s), quote), "clean": lambda s: s,
            "keep_line": lambda s: not OWNER.search(s or ""), "pt": pt, "hours": hours,
            "shift_href": lambda s: f"/runs/long/shift-{s['n']}/",
            "video_offset": lambda v, t: 600.0 if t else None, "game_time": lambda tick: f"{tick // 216000}h",
            "live_banner": lambda: ""}


def main():
    # ---- R2: only a whole-shift receipt whose master playlist answers 200
    with tempfile.TemporaryDirectory() as d:
        rec = Path(d)
        for run, prefix in (("shift01", "shift01/full/"), ("shift02", "shift02/full/"), ("shift03", "shift03/full/"),
                            ("shift48", "shift48/sample-1820/")):
            (rec / f"{run}.json").write_text(json.dumps({"run": run, "prefix": prefix, "duration_s": 14596.0}))
        (rec / "shift04.json").write_text("{not json")
        asked = []

        def check(url):
            asked.append(url)
            return {"shift01": 200, "shift02": 404}.get(url.split("/")[-3])
        rows, bad = vp.r2_rows(rec, check=check)
        assert list(rows) == ["shift01"], rows
        assert bad == {"shift02": 404, "shift03": None}, bad
        assert sorted(asked) == [vp.master_url(r) for r in ("shift01", "shift02", "shift03")], "the sample is not a shift"
        assert rows["shift01"]["player"] == (vp.PUBLIC + "/player/index.html?src=../shift01/full/master.m3u8"
                                             "&data=../shift01/full/shift.json&vtt=../shift01/full/captions.vtt")
        assert rows["shift01"]["duration_s"] == 14596.0

    # ---- the page
    shifts = [shift(1, "2026-10-12T14:31:00", "2026-10-12T18:34:00"), shift(2, "2026-10-12T18:37:00", "2026-10-12T22:40:00"),
              shift(63, "2026-10-23T07:57:00", "2026-10-23T12:13:00"), shift(69, "2026-10-24T09:40:00", "2026-10-24T13:43:00"),
              shift(70, "2026-10-24T13:44:00", "2026-10-24T17:49:00"), {"n": None, "empty": True}]
    lr = {"shifts": shifts, "firsts": [
        {"key": "planet:vulcanus", "label": "Vulcanus reached", "kind": "space", "tick": 216000 * 8, "t": "2026-10-12T15:00:00", "shift": 1},
        {"key": "tech:x", "label": "Some research", "kind": "research", "tick": 1, "t": "2026-10-12T15:00:00", "shift": 1},
        {"key": "edge", "label": "Solar system edge reached", "kind": "space", "tick": 2, "t": "2026-10-23T10:00:00", "shift": 63},
        {"key": "pack:x", "label": "First Z pack", "kind": "science", "tick": 3, "t": "2026-10-24T15:00:00", "shift": 70}]}
    videos = {"shift01": video(1, [{"at": 0, "time": "0:00", "title": "Nine AIs, one empty map"},
                                   {"at": 9243, "time": "2:34:03", "title": "NickWinter (host) asks: Sol"}]),
              "shift02": video(2), "shift63": video(63), "shift69": video(69)}
    videos["shift02"]["title"] = "Factorio AI Party · Shift 2: Asked by Nick Winter"  # an owner-named title: none shown
    r2 = {"shift01": {"shift": 1, "player": vp.player_url("shift01"), "duration_s": 1000.0},
          "shift70": {"shift": 70, "player": vp.player_url("shift70"), "duration_s": 3 * 3600 + 60}}
    body = vp.build_page(lr, videos, r2, {1: "shift-1.jpg"}, helpers())
    assert not OWNER.search(body.replace("nickwinter.net", "")), "the owner's name on the page"
    start = body.split('id="start"')[1].split('id="moments"')[0]
    assert re.findall(r"<h3><a [^>]*>Shift (\d+)</a>", start) == ["1", "63", "69"]
    assert "The first shift" in start and "The Space Age victory" in start and "The latest shift" in start
    rows = re.findall(r'<li class="v-row" id="shift-(\d+)"', body)
    assert rows == ["1", "2", "63", "69", "70"], rows
    row = {n: body.split(f'id="shift-{n}"')[1].split('<li class="v-row"')[0] for n in rows}
    assert "Headline 1" in row["1"] and "Oct 12, 14:31 Pacific" in row["1"] and "4h00" in row["1"], "video length"
    assert "3h01" in row["70"], "R2's length when there is no YouTube video"
    assert "https://www.youtube.com/watch?v=VID01xxxxx&amp;list=PLtest" in row["1"]
    assert "Archive player" in row["1"] and "Archive player" not in row["2"] and "Archive player" in row["70"]
    assert "YouTube</a>" not in row["70"] and "First Z pack" in row["70"], "no video: the shift's own firsts"
    assert "Asked by" not in row["2"], "a title naming the owner is not shown"
    assert "1 chapters" in row["1"] and "t=9243s" not in row["1"], "the owner's chapter left out"
    assert row["1"].count('src="/static/thumbs/shift-1.jpg"') == 1 and "thumb-text" in row["2"]
    assert "public</span>" in row["1"] and "public</span>" not in row["2"]
    moments = body.split('id="moments"')[1].split('id="all"')[0]
    assert "Vulcanus reached" in moments and "Some research" not in moments and "First Z pack" not in moments, \
        "moments: space and science firsts with a video only"
    assert "t=540s" in moments, "a minute before the moment"
    assert "https://www.youtube.com/playlist?list=PLtest" in body
    # the rule: 1, 63 and the latest
    assert vp.public_shifts(videos) == [1, 63, 69]
    assert vp.public_shifts({}) == []
    assert vp.headline("Factorio AI Party · Shift 12: A: b", 12) == "A: b" and vp.headline("x", 1) == ""
    assert vp.hm(3 * 3600 + 59 * 60 + 40) == "4h00" and vp.hm(None) == "–"
    print("test_videos_page: ok")


if __name__ == "__main__":
    main()
