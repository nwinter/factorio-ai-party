#!/usr/bin/env python3
"""tools/shift_video.py and tools/yt_upload.py --dry-run on a made-up pair of shifts: python3 tools/test_shift_video.py

- the box's file names are PST (UTC-8): a recording named 21-00-05 starts 22:00:05 PDT; Replay_ clips are left out;
  the other shift's recording at either edge is left out; a shift split over two files is one video, its times added up;
- a log over midnight dates its lines on the next day;
- chapters: the first at 0:00, at least three, at least 10 s apart, at most 24; rockets, a platform, research
  milestones, a death, a big fight (from where it got big), a host segment, a viewer's question an agent answered;
- the description: under 5,000 bytes, no angle brackets, no operator lines, no chat from the shift before;
- the box plan: concat list in order, Quick Sync HEVC at about 1 GB an hour, low priority;
- yt_upload --dry-run: every request printed, no sign-in, nothing written; a real run refuses a shift still on.
"""
import datetime, json, os, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import shift_video as sv  # noqa: E402

PDT = sv.PACIFIC


def score(t, tick, done, rockets=0, platforms=()):
    return json.dumps({"t": t, "world": "n", "score": {"tick": tick, "research_done": list(done), "rockets": rockets,
                       "produced": {"automation-science-pack": tick // 100}, "planets": ["nauvis"],
                       "platforms": [dict(p) for p in platforms]}})


def make(root):
    a = root / "sa"
    a.mkdir()
    (a / "stream.json").write_text(json.dumps({"shift": {"start": datetime.datetime(2026, 10, 12, 18, 0, tzinfo=PDT).timestamp()}}))
    (a / "start.log").write_text("17:58:00 quota x\n18:00:10 helper stream-service pid 1 up: x\n")
    (a / "scores.jsonl").write_text("\n".join([score("2026-10-12T18:01:00", 1000, ["automation"]),
                                               score("2026-10-12T21:55:00", 900000, ["automation", "oil-processing"])]) + "\n")
    (a / "caster.log").write_text("21:56:00 [Rook] (open, x, 1s) Bye.\n")
    (a / "chat.jsonl").write_text(json.dumps({"seq": 1, "tick": 899000, "from": "viewer Old", "viewer": True,
                                              "text": "is this the old shift?", "logged_at": "2026-10-12T21:50:00"}) + "\n"
                                  + json.dumps({"seq": 2, "tick": 899100, "from": "opus", "text": "@Old yes it is",
                                                "logged_at": "2026-10-12T21:50:30"}) + "\n")
    b = root / "sb"
    b.mkdir()
    (b / "resumed-from").write_text("sa\n")
    t0 = datetime.datetime(2026, 10, 12, 22, 0, tzinfo=PDT)
    (b / "stream.json").write_text(json.dumps({"shift": {"start": t0.timestamp(), "end": t0.timestamp() + 4 * 3600},
                                               "agents": {"opus": {"model": "Claude Opus 5.5", "harness": "Claude Code"},
                                                          "sol": {"model": "GPT-6.1 Sol", "harness": "Codex"}}}))
    (b / "start.log").write_text("21:58:30 world n: resuming\n22:00:05 helper stream-service pid 2 up: x\n")
    plat = {"name": "Starling", "at": "nauvis", "hub": True}
    rows = [("2026-10-12T22:01:00", 900500, ["automation", "oil-processing"], 0, ()),
            ("2026-10-12T22:30:00", 950000, ["automation", "oil-processing", "rocket-silo"], 0, ()),
            ("2026-10-12T23:40:00", 1100000, ["automation", "oil-processing", "rocket-silo"], 1, ()),
            ("2026-10-13T00:20:40", 1200000, ["automation", "oil-processing", "rocket-silo"], 2, (plat,)),
            ("2026-10-13T01:50:00", 1400000, ["automation", "oil-processing", "rocket-silo", "space-science-pack"], 2,
             (dict(plat, at=None),))]
    (b / "scores.jsonl").write_text("\n".join(score(*r) for r in rows) + "\n")
    (b / "stream-service.log").write_text(
        "[director] 22:40:58 cam2:  zoom 1.1  <- death: Sol died\n"
        "[director] 22:41:00 ON AIR cam2: @attack  <- death: Sol died\n"
        "[director] 22:42:30 ON AIR cam2: @attack  <- loss: 1 lost near (5, 6): 1 character (by small worm turrets)\n"
        "[director] 23:10:00 ON AIR main: @attack  <- loss: 1 lost near (60, -110): 1 gun turret (by small biters)\n"
        "[director] 23:16:00 ON AIR main: @attack  <- loss: 30 lost near (40, -150): 20 stone wall, 10 gun turret (by small biters)\n"
        "[director] 23:19:00 ON AIR main: @attack  <- loss: 64 lost near (35, -160): 40 stone wall, 24 transport belt (by small biters)\n"
        "[director] 01:58:00 main: haiku zoom 0.5  <- zoom 0.5 (move_to)\n")
    (b / "caster.log").write_text(
        '23:50:00 [segment] asked for spotlight (lull): {"id": "seg-1", "title": "Spotlight: Opus", "facts": {}}\n'
        '23:55:00 [segment] asked for research (research): {"id": "seg-2", "title": "Research: Space science 3%"}\n'
        "01:59:00 [Vale] (plan, x, 1s) Last line.\n")
    chat = [{"tick": 899000, "from": "viewer Old", "viewer": True, "text": "is this the old shift?", "logged_at": "2026-10-12T22:00:05"},
            {"tick": 899100, "from": "opus", "text": "@Old yes it is", "logged_at": "2026-10-12T22:00:05"},
            {"tick": 960000, "from": "viewer Craig", "viewer": True, "text": "@opus when is the first rocket?",
             "logged_at": "2026-10-12T22:50:00"},
            {"tick": 960100, "from": "opus", "text": "@Craig soon: the silo is half built.", "logged_at": "2026-10-12T22:51:00"},
            {"tick": 960200, "from": "server", "text": "Operator here. A harness fix is live.", "logged_at": "2026-10-12T22:52:00"},
            {"tick": 960300, "from": "viewer NickWinter", "viewer": True, "text": "how is it going?", "logged_at": "2026-10-12T22:53:00"},
            {"tick": 960400, "from": "sol", "text": "@NickWinter fine", "logged_at": "2026-10-12T22:53:30"}]
    (b / "chat.jsonl").write_text("\n".join(json.dumps(c) for c in chat) + "\n")
    listing = root / "recordings.txt"
    listing.write_text("D:\\pog\\recordings\\2026-10-12 17-00-10.mkv,14100.0\n"   # shift sa: 18:00:10 to 21:55:10 PDT
                       "D:\\pog\\recordings\\Replay_2026-10-12_22-10-00.mkv,40.0\n"
                       "D:\\pog\\recordings\\2026-10-12 21-00-05.mkv,7200.0\n"    # sb: 22:00:05 to 00:00:05
                       "C:\\pog\\recordings\\2026-10-12 23-00-35.mkv,N/A\n")      # sb after the split: 00:00:35 on
    return listing


def main():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d) / "runs"
        root.mkdir()
        listing = make(root)

        # times over midnight
        lines = sv.stamped(root / "sb" / "caster.log", datetime.datetime(2026, 10, 12, 22, 0, tzinfo=PDT))
        assert lines[-1][0] == datetime.datetime(2026, 10, 13, 1, 59, tzinfo=PDT), lines[-1]

        files = sv.read_listing(listing, -8)
        assert [f[1].strftime("%H:%M:%S") for f in files] == ["18:00:10", "22:00:05", "00:00:35"], files  # no Replay_

        v = sv.build("sb", root, listing)
        assert [s["file"].split("\\")[-1] for s in v["segments"]] == ["2026-10-12 21-00-05.mkv", "2026-10-12 23-00-35.mkv"], v["segments"]
        assert v["shift"] == 2 and not v["estimated"]
        ch = v["chapters"]
        assert ch[0]["at"] == 0 and len(ch) >= 3 and len(ch) <= sv.MAX_CHAPTERS, ch
        assert all(b["at"] - a["at"] >= 10 for a, b in zip(ch, ch[1:])), ch
        titles = {c["title"]: c["at"] for c in ch}
        assert titles.get("First rocket launched") == (datetime.datetime(2026, 10, 12, 23, 5) - datetime.datetime(2026, 10, 12, 22, 0, 5)).seconds, ch
        # after the split: 7200 s of the first file, then from 00:00:35 (the platform: midway 23:40-00:20 is in the gap)
        assert titles.get("Space platform Starling built") == 7200, ch
        assert titles.get("Starling leaves Nauvis") == 7200 + (datetime.datetime(2026, 10, 13, 1, 5, 20) - datetime.datetime(2026, 10, 13, 0, 0, 35)).seconds, ch
        assert "Sol dies (small worm turrets)" in titles and "Spotlight: Opus" in titles, ch
        fight = [t for t in titles if t.startswith("Biters break in: 64 lost")]
        assert fight and titles[fight[0]] == (datetime.datetime(2026, 10, 12, 23, 16) - datetime.datetime(2026, 10, 12, 22, 0, 5)).seconds, ch
        assert "Craig asks: when is the first rocket?" in titles, ch
        assert not any("Research:" in t for t in titles), ch  # research cards repeat the research chapters

        assert v["title"].startswith("Factorio AI Party · Shift 2: ") and len(v["title"]) <= 100, v["title"]
        assert "Starling leaves Nauvis" in v["title"], v["title"]
        desc = v["description"]
        assert len(desc.encode()) < 5000 and "<" not in desc and ">" not in desc
        assert "Craig asked" in desc and "Opus answered" in desc and "the silo is half built" in desc
        assert "Operator" not in desc and "harness" not in desc and "old shift" not in desc and "NickWinter" not in desc
        assert "Streamed live Oct 12, 2026, 10:00 p.m. to" in desc, desc
        assert "\nChapters\n0:00 " in desc and all(f"{c['time']} {c['title']}" in desc for c in ch)
        assert "Deaths: 1;" in desc and "64 buildings" in desc, desc

        concat = v["box"]["concat"].splitlines()
        assert concat[1] == "file 'D:/pog/recordings/2026-10-12 21-00-05.mkv'" and concat[2].startswith("file 'C:/"), concat
        cmd = v["box"]["encode_cmd"]
        assert "hevc_qsv" in cmd and "-b:v 2000k" in cmd and 'start "" /low' in cmd and "\r\n" in cmd
        assert 0.9 < v["size_gb"] / (v["duration"] / 3600) < 1.0, v

        # the earlier shift: its own file only; without a list, an estimate from start.log
        va = sv.build("sa", root, listing)
        assert len(va["segments"]) == 1 and va["segments"][0]["file"].endswith("17-00-10.mkv"), va["segments"]
        assert va["title"].startswith("Factorio AI Party · Shift 1: ") and "Nine AIs" in va["chapters"][0]["title"]
        ve = sv.build("sb", root)
        assert ve["estimated"] and ve["segments"][0]["file"].endswith("2026-10-12 21-00-05.mkv"), ve["segments"]

        # files written, then the uploader's dry run reads them
        out = Path(d) / "video"
        v["_runs_dir"] = str(root)
        sv.write(v, out, thumb=False)
        assert json.loads((out / "video.json").read_text())["title"] == v["title"]
        conf = Path(d) / "conf"
        env = dict(os.environ, POG_YT_CONF=str(conf))
        r = subprocess.run([sys.executable, str(HERE / "yt_upload.py"), "sb", "--video-dir", str(out), "--dry-run",
                            "--videos-json", str(Path(d) / "videos.json")], capture_output=True, text=True, env=env)
        assert r.returncode == 0, r.stderr
        for want in ("uploadType=resumable", "thumbnails" if (out / "thumb.png").exists() else "playlists?part=snippet",
                     "playlistItems", '"privacyStatus": "public"', "1 upload of the 100 a day"):
            assert want in r.stdout, (want, r.stdout[-2000:])
        assert not conf.exists() and not (Path(d) / "videos.json").exists() and not (out / "upload.json").exists()
        r = subprocess.run([sys.executable, str(HERE / "yt_upload.py"), "sb", "--video-dir", str(out), "--file", __file__],
                           capture_output=True, text=True, env=env)
        assert r.returncode != 0 and "while the shift was on" in r.stderr, r.stderr  # the planned end is ahead
    print("shift videos: ok (box clock, split files, edges, midnight, chapter rules and picks, description, box plan, "
          "upload dry run)")


if __name__ == "__main__":
    main()
