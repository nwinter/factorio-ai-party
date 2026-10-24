#!/usr/bin/env python3
"""tools/archive_upload.py (every shift's recording to YouTube, private) on made-up shifts: python3 tools/test_archive_upload.py

- the box listing (size line, then ffprobe's duration or N/A): a file still being written and empty files are left out;
- the catalogue: one row per name, the SSD's copy before the box's;
- names by the box's clock (PST) become Pacific times;
- plans: one file as it is, one box file copied, several joined, a shift still on; minutes covered and
  gaps (one at the start, one between files); a file of the next shift at the edge is left out;
- skipping: a video id in the manifest or in runs/RUN/video/upload.json;
- a run (ffmpeg, scp, shift_video and yt_upload stood in for): the join's list with in/out points, the upload's
  arguments (private, no playlist, 200 Mbit/s, the private manifest), what it made in tmp removed once the id is in,
  the masters untouched; a join of files whose streams differ is refused; tmp may not be a folder of masters;
- the dry run's table and totals.
"""
import contextlib
import datetime
import io
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import archive_upload as au  # noqa: E402

PDT = au.sv.PACIFIC


def shift(runs, name, start, minutes, running=False):
    d = runs / name
    d.mkdir(parents=True)
    t0 = start.timestamp()
    (d / "stream.json").write_text(json.dumps({"shift": {"start": t0, "end": t0 + minutes * 60}}))
    if running:
        now = datetime.datetime.now(PDT).replace(tzinfo=None)
        rows = [{"t": (now - datetime.timedelta(minutes=2)).isoformat(timespec="seconds"), "score": {"tick": 1}}]
    else:
        rows = [{"t": (start + datetime.timedelta(minutes=m)).replace(tzinfo=None).isoformat(timespec="seconds"),
                 "score": {"tick": 1 + m * 3600}} for m in range(0, minutes + 1, 2)]
    (d / "scores.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))


def box_name(t):
    """The box's file name for a Pacific time (its clock is PST, UTC-8)."""
    return (t.astimezone(datetime.timezone(datetime.timedelta(hours=-8)))).strftime("%Y-%m-%d_%H-%M-%S") + ".mkv"


def main():
    # the box's listing
    text = ("F,1000,D:\\pog\\recordings\\2026-10-23_02-46-07.mkv\r\n14686.833\r\n"
            "F,0,D:\\pog\\recordings\\2026-10-23_06-00-00.mkv\r\nN/A\r\n"
            "F,500,D:\\pog\\recordings\\2026-10-24_12-45-48.mkv\r\nN/A\r\n"
            "F,7,D:\\pog\\recordings\\Replay_2026-10-24_12-00-00.mkv\r\n3.0\r\n")
    box = au.parse_box(text)
    assert [(f["name"], f["size"], f["duration"]) for f in box] == [("2026-10-23_02-46-07.mkv", 1000, 14686.833),
                                                                    ("2026-10-24_12-45-48.mkv", 500, None)], box
    # PST names -> Pacific: 02:46:07 PST is 03:46:07 PDT
    assert au.file_time("2026-10-23_02-46-07.mkv") == datetime.datetime(2026, 10, 23, 3, 46, 7, tzinfo=PDT)
    assert au.shifts_arg("2,4,10-12") == [2, 4, 10, 11, 12]

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        runs, ssd, tmp = root / "runs", root / "ssd" / "public-run", root / "tmp"
        ssd.mkdir(parents=True)
        day = datetime.datetime(2026, 10, 20, 0, 0, tzinfo=PDT)
        s1, s2, s3, s4 = (day + datetime.timedelta(hours=4 * k) for k in range(4))
        shift(runs, "shift01", s1, 240)            # one SSD file, starts 3 min late
        shift(runs, "shift02", s2, 240)            # two SSD files, a 10-minute gap between
        shift(runs, "shift03", s3, 240)            # one file, on the box only
        shift(runs, "shift04", s4, 240)            # only a short file from 30 s before it
        shift(runs, "shift05", s4 + datetime.timedelta(hours=4), 240, running=True)

        def master(t, seconds, size):
            p = ssd / box_name(t)
            p.write_bytes(b"x" * size)
            return {"name": p.name, "path": str(p), "size": size, "duration": seconds, "where": "public-run"}

        m1 = master(s1 + datetime.timedelta(minutes=3), 237 * 60, 300)
        m2a = master(s2 + datetime.timedelta(minutes=2), 100 * 60, 200)
        m2b = master(s2 + datetime.timedelta(minutes=112), 128 * 60, 100)
        edge = master(s4 - datetime.timedelta(seconds=30), 600, 10)   # 30 s of shift03's end, 9.5 min of shift04
        b3 = {"name": box_name(s3 + datetime.timedelta(minutes=1)), "path": "D:\\pog\\recordings\\" + box_name(
            s3 + datetime.timedelta(minutes=1)), "size": 400, "duration": 238 * 60, "where": "box"}
        dup = dict(m1, path="D:\\pog\\recordings\\" + m1["name"], where="box")
        files = au.catalogue([m1, m2a, m2b, edge], [dup, b3, {"name": "2026-10-24_12-45-48.mkv", "duration": None}])
        assert [f["where"] for f in files] == ["public-run", "public-run", "public-run", "box", "public-run"], files
        assert next(f for f in files if f["name"] == m1["name"])["path"] == m1["path"], "the SSD's copy first"

        plans = {r: au.plan(r, runs, files, tmp) for r in ("shift01", "shift02", "shift03", "shift04", "shift05")}
        p1, p2, p3, p4, p5 = (plans[f"shift0{k}"] for k in range(1, 6))
        assert p1["action"] == "as is" and p1["file"] == m1["path"] and p1["size"] == 300, p1
        assert round(p1["covered"] / 60) == 237 and [(a.strftime("%H:%M"), b.strftime("%H:%M")) for a, b in p1["gaps"]] == [("00:00", "00:03")]
        assert p2["action"] == "join" and [s["name"] for s in p2["segments"]] == [m2a["name"], m2b["name"]], p2
        assert [(a.strftime("%H:%M"), b.strftime("%H:%M")) for a, b in p2["gaps"]] == [("04:00", "04:02"), ("05:42", "05:52")], p2["gaps"]
        assert p2["file"] == str(tmp / "shift02.mkv") and p2["size"] == 300
        assert p3["action"] == "copy" and p3["file"] == str(tmp / b3["name"]) and p3["box_bytes"] == 400, p3
        assert [s["name"] for s in p3["segments"]] == [b3["name"]], "the next shift's file at the edge is left out"
        assert p4["action"] == "as is" and p4["segments"][0]["name"] == edge["name"], p4  # 30 s before shift04: its own
        assert p5["running"] and p5["action"] == "none", p5
        assert round(au.plan_time(p3, 200)) == round(400 / 100e6 + 400 * 8 / 200e6)

        # skipping what is up
        manifest = root / "videos-private.json"
        manifest.write_text(json.dumps({"shift02": {"id": "VID2"}}))
        (runs / "shift01" / "video").mkdir()
        (runs / "shift01" / "video" / "upload.json").write_text(json.dumps({"video_id": "VID1"}))
        assert au.uploaded("shift01", runs, au.load(manifest)) == "VID1"
        assert au.uploaded("shift02", runs, au.load(manifest)) == "VID2"
        assert au.uploaded("shift03", runs, au.load(manifest)) is None

        # a run, with ffmpeg, scp, shift_video and yt_upload stood in for
        calls = []

        class Done:
            returncode = 0

        def fake(cmd, **kw):
            calls.append([str(c) for c in cmd])
            if cmd[0] == "scp":
                Path(cmd[-1]).write_bytes(b"y" * 400)
                Path(cmd[-1]).with_name("._" + Path(cmd[-1]).name).write_bytes(b"sidecar")  # exFAT's AppleDouble
            elif "ffmpeg" in cmd:
                Path(cmd[-1]).write_bytes(b"joined")
            elif str(cmd[1]).endswith("shift_video.py"):
                run = cmd[2]
                rec = Path(cmd[cmd.index("--recordings") + 1]).read_text()
                lst = [ln.rsplit(",", 1)[0] for ln in rec.splitlines()]
                p = plans[run]
                assert all(s["file"] in lst for s in p["segments"])
                (runs / run / "video").mkdir(exist_ok=True)
                (runs / run / "video" / "video.json").write_text(json.dumps({"segments": [{"file": s["file"]} for s in p["segments"]]}))
            elif str(cmd[1]).endswith("yt_upload.py"):
                run = cmd[2]
                m = au.load(manifest)
                m[run] = {"id": "NEW_" + run}
                manifest.write_text(json.dumps(m))
            return Done()

        keep = au.run_cmd, au.probe
        au.run_cmd = fake
        au.probe = lambda path: 228.0 * 60 if str(path).endswith("shift02.mkv") else None

        class A:
            pass
        a = A()
        a.tmp, a.box, a.runs_dir, a.manifest, a.privacy, a.max_mbps, a.source = str(tmp), "pogwin", str(runs), str(manifest), "private", 200.0, [str(ssd)]
        try:
            # a join of SSD files
            manifest.write_text("{}")
            vid = au.do_shift(p2, a, files)
            assert vid == "NEW_shift02"
            ff = next(c for c in calls if "ffmpeg" in c)
            assert ff[-1] == str(tmp / "shift02.mkv") and ff[ff.index("-c") + 1] == "copy" and ff[:3] == ["nice", "-n", "19"], ff
            up = next(c for c in calls if c[1].endswith("yt_upload.py") and c[2] == "shift02")
            assert up[up.index("--file") + 1] == str(tmp / "shift02.mkv") and up[up.index("--privacy") + 1] == "private"
            assert "--no-playlist" in up and up[up.index("--max-mbps") + 1] == "200.0" and up[up.index("--videos-json") + 1] == str(manifest)
            assert sorted(os.listdir(tmp)) == [], f"tmp keeps nothing once the id is in: {os.listdir(tmp)}"
            assert all(Path(m["path"]).read_bytes() == b"x" * m["size"] for m in (m2a, m2b)), "the masters untouched"
            # a box file: copied (size checked), uploaded from tmp, then removed
            calls.clear()
            vid = au.do_shift(p3, a, files)
            scp = next(c for c in calls if c[0] == "scp")
            assert scp[-2] == "pogwin:D:/pog/recordings/" + b3["name"] and scp[-1] == str(tmp / b3["name"]), scp
            up = next(c for c in calls if c[1].endswith("yt_upload.py"))
            assert up[up.index("--file") + 1] == str(tmp / b3["name"]) and not any("ffmpeg" in c for c in calls)
            assert sorted(os.listdir(tmp)) == []
            # one SSD file as it is: nothing copied or joined
            calls.clear()
            (runs / "shift01" / "video" / "upload.json").unlink()
            au.do_shift(p1, a, files)
            up = next(c for c in calls if c[1].endswith("yt_upload.py"))
            assert up[up.index("--file") + 1] == m1["path"] and not any(c[0] == "scp" or "ffmpeg" in c for c in calls)
            # an upload that does not finish keeps tmp for the next run
            def failing(cmd, **kw):
                r = fake(cmd, **kw)
                if str(cmd[1]).endswith("yt_upload.py"):
                    m = au.load(manifest)
                    m.pop(cmd[2], None)
                    manifest.write_text(json.dumps(m))
                return r
            au.run_cmd = failing
            m = au.load(manifest)
            m.pop("shift02", None)
            manifest.write_text(json.dumps(m))
            try:
                au.do_shift(p2, a, files)
                raise AssertionError("no id: it should stop")
            except SystemExit as e:
                assert "run again to resume" in str(e), e
            assert "shift02.mkv" in os.listdir(tmp)
            for f in tmp.iterdir():
                f.unlink()
            au.run_cmd = fake
            # streams that differ: no join
            try:
                au.join(p2, tmp, {s["file"]: Path(s["file"]) for s in p2["segments"]}, streams_of=lambda p: str(p))
                raise AssertionError("different streams should be refused")
            except SystemExit as e:
                assert "cannot be joined without re-encoding" in str(e), e
            # tmp may not be a folder of masters
            a.tmp = str(ssd)
            try:
                au.do_shift(p1, a, files)
                raise AssertionError("tmp in the masters should be refused")
            except SystemExit as e:
                assert "folder of masters" in str(e), e
        finally:
            au.run_cmd, au.probe = keep

        # the dry run's table: no box, the SSD folder above, durations cached
        manifest.write_text(json.dumps({"shift02": {"id": "VID2"}}))
        keep_probe = au.probe
        au.probe = lambda path: {m1["path"]: m1["duration"], m2a["path"]: m2a["duration"], m2b["path"]: m2b["duration"],
                                 edge["path"]: edge["duration"]}.get(str(path))
        out = io.StringIO()
        argv = sys.argv
        sys.argv = ["archive_upload.py", "--dry-run", "--box", "", "--runs-dir", str(runs), "--source", str(ssd),
                    "--manifest", str(manifest), "--durations", str(root / "durations.json"), "--tmp", str(tmp)]
        try:
            with contextlib.redirect_stdout(out):
                au.main()
        finally:
            sys.argv, au.probe = argv, keep_probe
        text = out.getvalue()
        assert "| shift02 |" in text and "uploaded VID2" in text, text
        assert "| shift01 |" in text and "uploaded VID1" not in text  # its upload.json was removed above
        assert "| shift05 (on) |" in text and "skip (on)" in text
        assert "| shift03 |" in text and "skip (no recording)" in text, "no box: shift03 has no recording"
        assert "quota:" in text and "of the 100 uploads a day" in text
        assert json.loads((root / "durations.json").read_text())[m1["path"]][2] == m1["duration"]
    print("test_archive_upload: ok")


if __name__ == "__main__":
    main()
