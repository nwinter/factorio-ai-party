#!/usr/bin/env python3
"""tools/archive/r2_shifts.py (whole shifts as HLS on R2) on a made-up shift with two recordings, no network, no
ffmpeg, no clock: python3 tools/test_r2_shifts.py

- parts: a recording overlapping the shift by under a minute is left out; one running over 10 minutes past the end is
  cut a minute past it; the parts play back to back;
- the stitched rung playlist: each part's init map and segments under its folder, a discontinuity between parts;
- captions on the joined video: the second recording's cues start after the first's length;
- shift.json: the parts with names only (no local paths), the gaps, the stats row before the start;
- the upload: segments first, playlists then master.m3u8 last; the jobs controller rises under 80% of the cap, takes
  one off over it and never rises again; a stream health drop pauses new puts until two clean reads; at most 30
  puts in any 10 s (the Cloudflare API's limit is about 4 a second), and a 429 holds new puts for a minute;
- a whole shift with a fake runner (archive.py and ffmpeg) and a fake r2_put and HEAD: one object lost on the first
  pass is put again; the receipt in R2 and in the receipts folder; the local folder removed, the master untouched;
  the status row reads complete; a second run skips the shift.
"""
import argparse
import datetime
import json
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "archive"))
import r2_put  # noqa: E402
import r2_shifts as rs  # noqa: E402

PDT = rs.hls.PACIFIC
START = datetime.datetime(2026, 10, 12, 14, 0, 0, tzinfo=PDT).timestamp()
END = START + 4 * 3600


def made_index(rec_dir):
    """Two recordings cover the shift (a 30 s gap between them), a third starts 20 s before the end."""
    def media(name, t0, dur):
        return {"file": str(rec_dir / name), "name": name, "named_t0": t0 - 8, "offset": 8, "t0": t0,
                "duration": dur, "t1": t0 + dur, "calibrated": True}
    m1 = media("2026-10-12_13-58-00.mkv", START - 120, 7320)  # to START + 7200
    m2 = media("2026-10-12_16-00-30.mkv", START + 7230, 9000)  # to START + 16230: 1830 s past the end
    m3 = media("2026-10-12_17-59-40.mkv", END - 20, 600)
    lines = [{"t": START + 100, "dur": 4.0, "who": "Rook", "text": "First recording speaks."},
             {"t": START + 7300, "dur": 3.0, "who": "Wren", "text": "Second <recording> speaks."}]
    return {"version": 1, "shift": {"run": "shift01", "number": 1, "start": START, "end": END},
            "media": [m1, m2, m3], "gaps": [[START + 7200, START + 7230]], "clock": [], "onair": [], "layout": [],
            "events": [{"t": START + 500, "kind": "replay", "title": "r", "replay_file": str(rec_dir / "Replay_x.mkv"),
                        "replay_name": "Replay_x.mkv"}],
            "milestones": [], "lines": lines, "chat": [], "stats_cols": ["t", "rockets"],
            "stats": [[START - 60, 1], [START + 60, 2]]}


class FakeRunner:
    """archive.py writes the index; each ffmpeg writes an init, three segments and its playlist."""

    def __init__(self, index):
        self.index = index
        self.cmds = []

    def __call__(self, cmd, **kw):
        self.cmds.append(cmd)
        if cmd[1].endswith("archive.py"):
            out = Path(cmd[cmd.index("--out") + 1])
            (out / f"{cmd[2]}-index.json").write_text(json.dumps(self.index))
            assert (out / "calibration.json").exists(), "the run's offsets were not copied in"
        else:
            assert cmd[:3] == ["nice", "-n", "19"] and "ffmpeg" in cmd, cmd
            playlist = Path(cmd[-1])
            d = playlist.parent
            (d / "init.mp4").write_bytes(b"i" * 10)
            body = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:4", "#EXT-X-MEDIA-SEQUENCE:0",
                    "#EXT-X-PLAYLIST-TYPE:VOD", '#EXT-X-MAP:URI="init.mp4"']
            for i in range(3):
                (d / f"seg{i:04d}.m4s").write_bytes(b"s" * (100 + i))
                body += ["#EXTINF:4.000000,", f"seg{i:04d}.m4s"]
            playlist.write_text("\n".join(body + ["#EXT-X-ENDLIST"]) + "\n")

        class R:
            returncode = 0
            stderr = ""
        return R()


class FakeR2:
    def __init__(self, lose=()):
        self.objects, self.order, self.lose = {}, [], set(lose)
        self.lock = threading.Lock()

    def put(self, item):
        p, key = item[0], item[1]
        with self.lock:
            self.order.append(key)
            if key in self.lose:
                self.lose.discard(key)  # lost once: the check finds it missing
            else:
                self.objects[key] = p.read_bytes()
        return key, 0, []

    def head(self, url):
        key = url.split(rs.PUBLIC + "/", 1)[1]
        got = self.objects.get(key)
        return None if got is None else len(got)


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0

    def __call__(self):
        self.t += 1.0
        return self.t


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        rec = tmp / "masters"
        rec.mkdir()
        idx = made_index(rec)
        for m in idx["media"]:
            Path(m["file"]).write_bytes(b"master")
        # parts
        ps = rs.parts(idx)
        assert [p["name"] for p in ps] == ["2026-10-12_13-58-00.mkv", "2026-10-12_16-00-30.mkv"], ps
        assert ps[0]["s_in"] == 0 and ps[0]["seconds"] == 7320 and ps[0]["video_at"] == 0, ps[0]
        assert ps[1]["s_in"] == 0 and ps[1]["seconds"] == END + 60 - (START + 7230), ps[1]  # cut a minute past
        assert ps[1]["video_at"] == 7320 and ps[1]["folder"] == "masters", ps[1]
        # captions on the joined video
        vtt = rs.parts_vtt(idx["lines"], ps)
        assert "00:03:40.000 --> 00:03:44.000" in vtt, vtt  # START + 100 is 220 s into the first recording
        assert "02:03:10.000 --> 02:03:13.000" in vtt and "&lt;recording&gt;" in vtt, vtt  # 7320 + 70
        # shift.json
        d = rs.shift_data(idx, ps)
        assert d["t0"] == START - 120 and d["parts"][1][:3] == [7320, START + 7230, ps[1]["seconds"]], d["parts"]
        assert str(rec) not in json.dumps(d) and d["gaps"] == idx["gaps"], d
        assert d["stats"][0][0] == START - 60 or d["stats"][0][0] == START + 60, d["stats"]
        # the jobs controller
        assert rs.next_jobs(4, 40, 150, 16, False) == (6, False)
        assert rs.next_jobs(15, 40, 150, 16, False) == (16, False)
        assert rs.next_jobs(10, 130, 150, 16, False) == (10, True)  # near the cap: no more raising
        assert rs.next_jobs(10, 160, 150, 16, False) == (9, True)
        assert rs.next_jobs(9, 40, 150, 16, True) == (9, True)  # once capped, never raised again
        assert rs.next_jobs(1, 400, 150, 16, True) == (1, True)
        # health: skipped frames rising or congestion pauses; an unreadable status does not
        reads = iter(["active=True reconnecting=False time=1 skipped=0/100 congestion=0.00",
                      "active=True reconnecting=False time=2 skipped=5/200 congestion=0.00",
                      "active=True reconnecting=False time=3 skipped=5/300 congestion=0.20",
                      "active=True reconnecting=False time=4 skipped=5/400 congestion=0.00",
                      "", "active=False reconnecting=False time=0 skipped=9/0 congestion=0.50"])
        h = rs.Health(lambda: next(reads))
        got = [h.check()[0] for _ in range(6)]
        assert got == [True, False, False, True, True, True], got
        # the upload: order, and a pause holds puts until two clean reads
        up_dir = tmp / "up"
        for name in ("master.m3u8", "1080/index.m3u8", "1080/p00/init.mp4", "1080/p00/seg0000.m4s",
                     "540/index.m3u8", "540/p00/seg0000.m4s"):
            (up_dir / name).parent.mkdir(parents=True, exist_ok=True)
            (up_dir / name).write_bytes(b"x" * 50)
        items = r2_put.plan(up_dir, "shift01/full")
        r2 = FakeR2()
        states = iter([False, False, True, True] + [True] * 50)
        calls = []

        def health():
            ok = next(states)
            calls.append((ok, len(r2.order)))
            return ok, "test"
        res = rs.upload(items, r2.put, health=health, clock=Clock(), sleep=lambda s: None, window=2.0, log=lambda *x: 0)
        assert r2.order[-1] == "shift01/full/master.m3u8", r2.order
        assert r2.order.index("shift01/full/540/index.m3u8") > r2.order.index("shift01/full/540/p00/seg0000.m4s")
        assert all(n == 0 for ok, n in calls[:4]), calls  # nothing went up while paused
        assert len(res["pauses"]) == 1 and res["objects"] == 6 and not res["failed"], res
        # the API's request limit: at most 30 puts in any 10 s, and a 429 holds new puts for a minute
        class Fixed:
            t = 100.0

            def __call__(self):
                return self.t
        fixed = Fixed()
        pacer = rs.Pacer(3.0, fixed)
        for _ in range(30):
            assert pacer.room()
            pacer.sent()
        assert not pacer.room()
        fixed.t = 109.9
        assert not pacer.room()
        fixed.t = 110.0
        assert pacer.room()
        pacer.hold(60)
        fixed.t = 169.9
        assert not pacer.room()
        fixed.t = 170.0
        assert pacer.room()
        many = tmp / "many"
        for i in range(8):
            (many / "1080").mkdir(parents=True, exist_ok=True)
            (many / "1080" / f"seg{i:04d}.m4s").write_bytes(b"x")
        clock, stamps = Clock(), []

        def stamped(item):
            stamps.append((clock.t, item[1]))
            if item[1].endswith("seg0003.m4s"):
                return item[1], 1, ["Failed to fetch ... - 429: Too Many Requests;"]
            return item[1], 0, []
        res = rs.upload(r2_put.plan(many, "s/full"), stamped, jobs=1, jobs_max=1, clock=clock,
                        sleep=lambda s: None, log=lambda *x: 0)
        t429 = next(t for t, k in stamps if k.endswith("seg0003.m4s"))
        later = [t for t, k in stamps if t > t429]
        assert len(later) == 4 and min(later) >= t429 + 60, (t429, later)
        assert res["too_many_requests"] == 1 and res["failed"] == ["s/full/1080/seg0003.m4s"], res
        # a whole shift
        hls_root = tmp / "pog-hls"
        hls_root.mkdir()
        status = tmp / "r2-status.md"
        status.write_text("| shift | R2 renditions | R2 clips |\n|---|---|---|\n| shift01 | none | s01-death-006 |\n"
                          "| shift02 | none | none |\n")
        cal = tmp / "calibration.json"
        cal.write_text("{}")
        a = argparse.Namespace(hls_root=str(hls_root), sources=[str(rec)], runs_dir=str(tmp), logs_dir=str(tmp),
                               calibration=str(cal), receipts=str(tmp / "receipts"), status=str(status),
                               max_mbps=150.0, jobs=4, jobs_max=16, window=30.0, max_obj_s=3.0, max_local_gb=25.0,
                               margin_gb=0.0,
                               dry_run=False)
        runner = FakeRunner(idx)
        r2 = FakeR2(lose={"shift01/full/540/p01/seg0002.m4s"})
        logs = []
        rec_out = rs.do_shift("shift01", a, r2.put, r2.head, None, runner=runner, clock=Clock(), log=logs.append,
                             free=lambda path: 100.0)
        ff = [c for c in runner.cmds if "ffmpeg" in c]
        assert len(ff) == 4, ff  # two rungs x two parts
        keys = set(r2.objects)
        assert "shift01/full/1080/index.m3u8" in keys and "shift01/full/540/p01/seg0002.m4s" in keys, sorted(keys)
        assert r2.order.count("shift01/full/540/p01/seg0002.m4s") == 2, "the lost object was not put again"
        pl = r2.objects["shift01/full/1080/index.m3u8"].decode()
        assert pl.count("#EXT-X-DISCONTINUITY") == 1 and 'URI="p01/init.mp4"' in pl and "p00/seg0002.m4s" in pl, pl
        assert pl.count("#EXTINF") == 6 and pl.rstrip().endswith("#EXT-X-ENDLIST"), pl
        receipt = json.loads(r2.objects["shift01/full/receipt.json"])
        assert receipt == json.loads((tmp / "receipts" / "shift01.json").read_text()) == json.loads(json.dumps(rec_out))
        assert receipt["objects"] == len(keys) - 1 and receipt["verified"]["ok"], receipt
        assert [m["name"] for m in receipt["masters"]] == [p["name"] for p in ps], receipt["masters"]
        assert receipt["duration_s"] == round(sum(p["seconds"] for p in ps), 1), receipt
        assert receipt["by_folder"]["1080"]["objects"] == 11 and "playback" in receipt, receipt["by_folder"]
        for key in ("shift01/full/shift.json", "shift01/full/receipt.json", "shift01/full/encode.json"):
            assert str(tmp) not in r2.objects[key].decode(), key  # published: no local paths
        assert not any(k.endswith((".mkv", "index.json")) or "/work/" in k for k in keys), sorted(keys)
        assert not (hls_root / "shift01").exists() and all(Path(m["file"]).read_bytes() == b"master"
                                                            for m in idx["media"])
        assert "| shift01 | complete (r2-receipts/shift01.json) | s01-death-006 |" in status.read_text()
        assert "| shift02 | none | none |" in status.read_text()
        n = len(runner.cmds)
        rs.do_shift("shift01", a, r2.put, r2.head, None, runner=runner, clock=Clock(), log=logs.append)
        assert len(runner.cmds) == n and "skipped" in logs[-1], logs[-1]
        # the cleanup refuses a folder outside the root or holding a recording
        bad = hls_root / "shift09"
        bad.mkdir()
        (bad / "x.mkv").write_bytes(b"m")
        for folder in (bad, tmp / "masters"):
            try:
                rs.remove_local(folder, hls_root)
                raise AssertionError(f"{folder} was removed")
            except SystemExit:
                pass
        assert (bad / "x.mkv").exists() and (rec / idx["media"][0]["name"]).exists()
        assert rs.shifts_arg("2-4,9") == ["shift02", "shift03", "shift04", "shift09"]
    print("r2 shifts: ok (parts, stitched playlists, joined captions, shift.json, jobs controller, stream health "
          "pause, upload order, the API request cap and 429 hold, a whole shift with a lost object, receipt, cleanup, status row, skip on rerun)")


if __name__ == "__main__":
    main()
