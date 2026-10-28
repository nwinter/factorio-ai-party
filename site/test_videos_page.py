#!/usr/bin/env python3
"""/videos/ (site/videos_page.py) on made-up shifts: python3 site/test_videos_page.py

- R2: a shift is listed only when its receipt is for the whole shift and its master playlist answers 200 (a 404 or
  no answer leaves it out); the player URL is the r2.dev player with the shift's playlist, data and captions;
- the page: the three public videos first (shift 1, shift 63, the latest), every shift in order with its title,
  date, length (the video's, else R2's, else the shift's), YouTube in the playlist, the archive player only where
  R2 has the shift, a shift with neither says the video comes later; chapters link into the video; a chapter or
  title naming an account or tool (build.py keep_line) never reaches the page, the owner's name may; moments to watch
  link a minute before the moment;
- thumbnails: a shift-N.jpg only when the shift has one, else a text label;
- build.py reads the video data only when named: a build given none has no /videos/ and no Videos link even when
  site/content/r2.json, videos.json and site/og/thumbs exist in the checkout (the gate tests in the live checkout,
  where site-refresh writes them; d27 08:12); a build given R2 data and no videos has /videos/ with no "Start here"
  and passes check.py.
"""
import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import videos_page as vp  # noqa: E402

BLOCKED = re.compile(r"(?i)codex-b")  # build.py keep_line: an account or tool name


def shift(n, started, ended):
    return {"n": n, "id": f"shift{n:02d}", "started": started, "ended": ended, "game0": f"{n}h00m", "game1": f"{n + 4}h00m"}


def video(n, chapters=(), timeline=None):
    return {"id": f"VID{n:02d}xxxxx", "shift": n, "title": f"Factorio AI Party · Shift {n}: Headline {n}",
            "playlist": "PLtest", "chapters": list(chapters),
            "timeline": timeline or [["2026-10-12T14:00:00-07:00", "2026-10-12T18:00:00-07:00"]]}


def helpers():
    import datetime

    def pt(t, day=True):
        return datetime.datetime.fromisoformat(t).strftime("%b %-d, %H:%M" if day else "%H:%M")

    def hours(a, b):
        return (datetime.datetime.fromisoformat(b) - datetime.datetime.fromisoformat(a)).total_seconds() / 3600
    return {"esc": lambda s, quote=True: html.escape(str(s), quote), "clean": lambda s: s,
            "keep_line": lambda s: not BLOCKED.search(s or ""), "pt": pt, "hours": hours,
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
                                   {"at": 9243, "time": "2:34:03", "title": "NickWinter (host) asks: Sol"},
                                   {"at": 9300, "time": "2:35:00", "title": "codex-b notes"}]),
              "shift02": video(2), "shift63": video(63), "shift69": video(69)}
    videos["shift02"]["title"] = "Factorio AI Party · Shift 2: Asked by Nick Winter"  # the owner's name may appear
    r2 = {"shift01": {"shift": 1, "player": vp.player_url("shift01"), "master": vp.master_url("shift01"), "duration_s": 1000.0},
          "shift70": {"shift": 70, "player": vp.player_url("shift70"), "master": vp.master_url("shift70"),
                      "duration_s": 3 * 3600 + 60}}
    lr["shifts"][0].update(research_new=5, rockets_new=12, spm=33.4, platforms_built=["Starling"], deaths=2)
    body = vp.build_page(lr, videos, r2, {1: "shift-1.jpg"}, helpers())
    assert not BLOCKED.search(body), "an account name on the page"
    start = body.split('id="start"')[1].split('id="moments"')[0]
    assert re.findall(r"<h3><a [^>]*>Shift (\d+)</a>", start) == ["1", "63", "69"]
    assert "The first shift" in start and "The Space Age victory" in start and "The latest shift" in start
    rows = re.findall(r'<li class="v-card" id="shift-(\d+)"', body)
    assert rows == ["70", "69", "63", "2", "1"], rows  # newest day first, newest shift first in a day
    days = re.findall(r'<section class="v-day" data-day="([\d-]+)"', body)
    assert days == ["2026-10-24", "2026-10-23", "2026-10-12"], days
    row = {n: body.split(f'id="shift-{n}"')[1].split('<li class="v-card"')[0].split('<section class="v-day"')[0] for n in rows}
    assert "Headline 1" in row["1"] and "14:31 Pacific" in row["1"] and "4h00" in row["1"], "video length"
    assert "3h01" in row["70"], "R2's length when there is no YouTube video"
    assert "https://www.youtube.com/watch?v=VID01xxxxx&amp;list=PLtest" in row["1"]
    # the play button and Watch go to the shift's player page here; a shift with no video has neither
    for n in ("1", "2", "63", "69", "70"):
        assert f'href="/videos/shift-{n}/" aria-label="Play shift {n}"' in row[n] and "▶ Watch" in row[n], n
    assert "YouTube</a>" not in row["70"] and "First Z pack" in row["70"], "no YouTube video: the shift's own firsts"
    assert "Asked by Nick Winter" in row["2"], "a title naming the owner is shown (Nick d27 10:10)"
    # chapters: into this site's player at the moment's wall time where R2 has the shift, else YouTube at its second
    assert "2 chapters" in row["1"] and "codex-b" not in row["1"], "only the account's chapter left out"
    t0 = vp.epoch("2026-10-12T14:00:00-07:00")
    assert f'href="/videos/shift-1/?at={int(t0 + 9243)}"' in row["1"], row["1"]
    assert row["1"].count('src="/static/thumbs/shift-1.jpg"') == 1 and "thumb-text" in row["2"]
    assert "public</span>" in row["1"] and "public</span>" not in row["2"]
    # the numbers with the game's icons, the firsts as chips with theirs
    assert "+5</b> tech" in row["1"] and "+12</b> rockets" in row["1"] and "33</b> SPM" in row["1"] and "Starling built" in row["1"]
    assert "2 deaths" in row["1"] and "/static/game/item/rocket-part.webp" in row["1"]
    assert '/static/game/place/vulcanus.webp' in row["1"] and "Vulcanus reached" in row["1"]
    moments = body.split('id="moments"')[1].split('id="all"')[0]
    assert "Vulcanus reached" in moments and "Some research" not in moments, "moments: space and science firsts"
    assert f'href="/videos/shift-70/?at={int(vp.epoch("2026-10-24T15:00:00") - 60)}"' in moments, "R2 only: this site's player"
    at = int(vp.epoch("2026-10-12T15:00:00") - 60)
    assert f'href="/videos/shift-1/?at={at}"' in moments, "a minute before the moment, in this site's player (R2)"
    assert "https://www.youtube.com/watch?v=VID63xxxxx&amp;list=PLtest&amp;t=" in moments, "no R2: YouTube at the second"
    assert "https://www.youtube.com/playlist?list=PLtest" in body
    # the player pages: R2 with the timeline, prev/next among the shifts with a video, captions off at first
    h = helpers()
    timeline = [(216000 * 7, "research", "Steel axe", 4, None), (216000 * 8, "death", "Opus died", 5, "opus")]
    page1, head1 = vp.build_watch(1, lr, videos, r2, {1: "shift-1.jpg"}, h, timeline, lambda v: f"EMBED {v['id']}")
    cfg = json.loads(page1.split('<script type="application/json" id="pl-data">')[1].split("</script>")[0])
    assert cfg["src"] == vp.master_url("shift01") and cfg["data"].endswith("/shift01/full/shift.json") \
        and cfg["vtt"].endswith("/shift01/full/captions.vtt"), cfg
    assert cfg["timeline"] == [[216000 * 7, "research", "Steel axe", 4, None], [216000 * 8, "death", "Opus died", 5, "opus"]]
    assert cfg["planets"] == [["nauvis", 0], ["vulcanus", 216000 * 8]]
    assert 'href="/videos/#shift-1">← All videos' in page1 and 'rel="next" href="/videos/shift-2/"' in page1 and 'rel="prev"' not in page1
    assert 'id="pl-big"' in page1 and "Play shift 1" in page1 and 'poster="/static/thumbs/shift-1.jpg"' in page1
    assert 'id="pl-cc" aria-pressed="false"' in page1 and "<track" not in page1, "captions: off until CC"
    assert "hls.js/1.5.13/hls.min.js" in head1 and "/static/player.js" in head1
    page63, _ = vp.build_watch(63, lr, videos, r2, {}, h, [], lambda v: f"EMBED {v['id']}")
    assert "EMBED VID63xxxxx" in page63 and 'rel="prev" href="/videos/shift-2/"' in page63 and 'rel="next" href="/videos/shift-69/"' in page63
    assert "pl-data" not in page63, "YouTube only: no R2 player"
    # the homepage's way in: the latest four shifts with a video, newest first
    strip = vp.home_strip(lr, videos, r2, {1: "shift-1.jpg"}, h)
    assert re.findall(r'href="/videos/shift-(\d+)/" aria-label', strip) == ["70", "69", "63", "2"] and 'href="/videos/"' in strip
    assert vp.home_strip({"shifts": [], "firsts": []}, {}, {}, {}, h) == ""
    # player.js's event jump (node): a second "next" goes on to the next event; the playhead counting found the same
    # one again (Nick d27: "next event" went to the same event when clicked twice)
    if shutil.which("node"):
        js = (f"const P = require({json.dumps(str(SITE / 'static' / 'player.js'))});"
              "const ev = [{t: 100}, {t: 200}, {t: 200}, {t: 300}];"
              "let now = 0, cur = null, out = [];"
              "for (let i = 0; i < 4; i++) { const s = P.step(ev, now, cur, 1); if (!s) { out.push(null); break; } out.push(s.t); now = s.seek; cur = s.cursor; }"
              "const back = []; for (let i = 0; i < 3; i++) { const s = P.step(ev, now, cur, -1); if (!s) { back.push(null); break; } back.push(s.t); now = s.seek; cur = s.cursor; }"
              "const old = (t) => ev.filter((e) => e.t > t + 1)[0].t;"  # the R2 prototype's next, from the playhead
              "const play = P.step(ev, 150, null, 1).t, prevPlaying = P.step(ev, 201, null, -1).t;"
              "console.log(JSON.stringify({out, back, oldTwice: [old(0), old(old(0) - 3)], play, prevPlaying}));")
        r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=20)
        got = json.loads(r.stdout)
        assert got["out"] == [100, 200, 300, None], got
        assert got["back"] == [200, 100, None], got
        assert got["oldTwice"] == [100, 100], "the old rule found the same event twice"
        assert got["play"] == 200 and got["prevPlaying"] == 200, got
        src = (SITE / "static" / "player.js").read_text()
        assert "default = true" not in src and "mode = v ? 'showing' : 'hidden'" in src
    else:
        print("node not found: player.js's jump not run")
    # the rule: 1, 63 and the latest
    assert vp.public_shifts(videos) == [1, 63, 69]
    assert vp.public_shifts({}) == []
    assert vp.headline("Factorio AI Party · Shift 12: A: b", 12) == "A: b" and vp.headline("x", 1) == ""
    assert vp.hm(3 * 3600 + 59 * 60 + 40) == "4h00" and vp.hm(None) == "–"
    # ---- build.py: the video data only when named
    sys.path.insert(0, str(SITE))
    from test_archive import make  # noqa: E402  (a made-up runs folder: pub1 -> pub2)
    content = dict(json.loads((SITE / "content" / "site.json").read_text()), archive=False, run_start="pub1")
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        runs = d / "runs"
        runs.mkdir()
        make(runs)
        (d / "site.json").write_text(json.dumps(content))
        (d / "r2.json").write_text(json.dumps({"pub1": {"shift": 1, "player": vp.player_url("shift01"), "duration_s": 3600.0}}))

        def build(*extra):
            out = d / f"dist{len(extra)}"
            r = subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                                "--content", str(d / "site.json"), *extra], capture_output=True, text=True)
            assert r.returncode == 0, r.stderr[-2000:]
            r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
            assert r.returncode == 0, r.stdout[-2000:]
            return out
        out = build()
        assert not (out / "videos").exists() and 'href="/videos/"' not in (out / "index.html").read_text(), \
            "no video data named: no page, no link"
        out = build("--r2", str(d / "r2.json"))
        page = (out / "videos" / "index.html").read_text()
        assert "▶ Watch" in page and 'href="#start"' not in page and 'href="/videos/"' in (out / "index.html").read_text()
        watch = (out / "videos" / "shift-1" / "index.html").read_text()  # its player page, with the site's header
        assert '<body class="watch">' in watch and 'class="site-nav"' in watch and 'id="pl-data"' in watch
        home = (out / "index.html").read_text()
        assert 'class="home-videos"' in home and 'href="/videos/shift-1/" aria-label="Play shift 1"' in home
    print("test_videos_page: ok")


if __name__ == "__main__":
    main()
