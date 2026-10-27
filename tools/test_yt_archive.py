#!/usr/bin/env python3
"""tools/yt_archive.py (the YouTube archive: privacy, playlist, rotation, quota) with no network:
python3 tools/test_yt_archive.py

- which three are public: shift 1, shift 63 and the latest with a video; fewer when one of them is the latest or
  missing;
- the plan from nothing: the playlist, the public ones first, then the rest unlisted in shift order, then playlist
  inserts in shift order; a rerun after part of it plans only the rest; nothing left after all of it;
- the rotation: a newer shift's video makes the previous latest unlisted (not shift 63 or 1); a new upload's privacy;
  the upload order (the newest finished first, then the backlog oldest first);
- playlist positions in shift order when a backlog shift goes in after newer ones;
- quota: what fits today stops at the first change that does not; an upload's units with its follow-ups; the
  backlog's days under the uploads bucket and under 1,600 units an upload;
- apply against a stand-in client: the status sent keeps the video's other status fields, a playlist insert waits for
  its video to be unlisted, the state is written after each change (a rerun does nothing), a quotaExceeded reply
  stops it and marks the day, and site/content/videos.json gets only the videos YouTube shows.
"""
import argparse
import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import yt_archive as ya  # noqa: E402


def vids(*shifts):
    return {f"shift{n:02d}": {"id": f"VID{n:02d}xxxxx", "shift": n, "title": f"Shift {n}", "description": "d",
                              "chapters": [{"at": 0, "time": "0:00", "title": "start"}], "timeline": []} for n in shifts}


def state_of(videos, privacy="private", items=False, playlist="PL1"):
    return {"refreshed": "x", "playlist": {"id": playlist, "privacy": "public"} if playlist else {},
            "videos": {r: dict({"id": v["id"], "privacy": privacy,
                                "status": {"privacyStatus": privacy, "embeddable": True, "license": "youtube",
                                           "publicStatsViewable": True, "madeForKids": False,
                                           "selfDeclaredMadeForKids": False, "uploadStatus": "processed"}},
                               **({"item": f"IT{v['shift']}"} if items else {})) for r, v in videos.items()}}


class FakeClient:
    """Stands in for yt_archive.Client: records calls, answers ids, raises QuotaExceeded after `limit` calls."""
    calls = []
    limit = None

    def __init__(self, ledger, dry=False):
        self.ledger, self.dry = ledger, dry

    def call(self, name, method, url, body=None):
        if FakeClient.limit is not None and len(FakeClient.calls) >= FakeClient.limit:
            self.ledger.exhaust()
            raise ya.QuotaExceeded("quotaExceeded")
        FakeClient.calls.append((name, body))
        self.ledger.spend(name, None, ya.COST[name])
        return {"id": f"NEW{len(FakeClient.calls)}"}


def run_apply(tmp, state, videos, **kw):
    man = tmp / "manifest.json"
    man.write_text(json.dumps(videos))
    st = tmp / "state.json"
    st.write_text(json.dumps(state))
    a = argparse.Namespace(manifest=str(man), extra=str(tmp / "none.json"), state=str(st), ledger=str(tmp / "q.json"),
                           site_videos=str(tmp / "videos.json"), refresh=False, daily=kw.get("daily", ya.DAILY),
                           margin=kw.get("margin", ya.MARGIN))
    with contextlib.redirect_stdout(io.StringIO()) as out:
        ya.apply(a)
    return json.loads(st.read_text()), out.getvalue()


def main():
    # ---- which three are public
    assert ya.public_shifts(range(1, 70)) == {1, 63, 69}
    assert ya.public_shifts(range(1, 64)) == {1, 63}, "63 is the latest: two public"
    assert ya.public_shifts([2, 3, 70]) == {70}, "no shift 1 or 63 video: only the latest"
    assert ya.public_shifts([]) == set()
    v = vids(*range(1, 70))
    want = ya.desired(v)
    assert [r for r, p in want.items() if p == "public"] == ["shift01", "shift63", "shift69"]
    assert sum(p == "unlisted" for p in want.values()) == 66

    # ---- the plan from nothing
    ops = ya.plan_ops(v, {"videos": {}})
    kinds = [o["op"] for o in ops]
    assert kinds[0] == "playlists.insert"
    assert [o["run"] for o in ops[1:4]] == ["shift01", "shift63", "shift69"] and all(o["privacy"] == "public" for o in ops[1:4])
    unl = [o["run"] for o in ops if o["op"] == "videos.update" and o["privacy"] == "unlisted"]
    assert unl == [f"shift{n:02d}" for n in range(2, 69) if n != 63], unl[:5]
    ins = [o["run"] for o in ops if o["op"] == "playlistItems.insert"]
    assert ins == [f"shift{n:02d}" for n in range(1, 70)], "inserts in shift order"
    assert kinds.index("playlistItems.insert") > max(i for i, k in enumerate(kinds) if k == "videos.update")
    assert sum(o["units"] for o in ops) == 50 + 69 * 50 + 69 * 50 == 6950
    # a private playlist found by title is made public
    assert ya.plan_ops(v, dict(state_of(v, "unlisted", True), playlist={"id": "PL", "privacy": "private"}))[0]["op"] == "playlists.update"

    # rerun after part of it: only the rest
    st = state_of(v)
    for r in ("shift01", "shift63", "shift69"):
        st["videos"][r]["privacy"] = "public"
    st["videos"]["shift02"]["privacy"] = "unlisted"
    ops = ya.plan_ops(v, st)
    assert [o["op"] for o in ops].count("videos.update") == 65 and ops[0]["run"] == "shift03"
    # all done: nothing
    done = state_of(v, "unlisted", items=True)
    for r in ("shift01", "shift63", "shift69"):
        done["videos"][r]["privacy"] = "public"
    assert ya.plan_ops(v, done) == []

    # ---- the rotation: shift70's video makes 69 unlisted, 1 and 63 stay
    v70 = dict(v, **vids(70))
    ops = ya.plan_ops(v70, done)
    assert [(o["op"], o["run"], o.get("privacy")) for o in ops] == [
        ("videos.update", "shift70", "public"), ("videos.update", "shift69", "unlisted"),
        ("playlistItems.insert", "shift70", None)], ops
    # uploaded public already (rotate's insert privacy): only the demotion and the insert
    done70 = json.loads(json.dumps(done))
    done70["videos"]["shift70"] = {"id": "VID70xxxxx", "privacy": "public"}
    assert [(o["op"], o["run"]) for o in ya.plan_ops(v70, done70)] == [("videos.update", "shift69"),
                                                                      ("playlistItems.insert", "shift70")]
    # a new upload's privacy: public when it is the newest (or fixed), unlisted for the backlog under a newer one
    assert ya.upload_privacy(70, set(range(1, 70))) == "public"
    assert ya.upload_privacy(71, set(range(1, 70)) | {86}) == "unlisted"
    assert ya.upload_privacy(63, {1, 2, 70}) == "public"
    assert ya.upload_privacy(5, set()) == "public"
    # upload order: the newest finished first, then the backlog oldest first
    have = set(range(1, 70))
    assert ya.upload_order(range(70, 86), have) == [85] + list(range(70, 85))
    assert ya.upload_order([70, 71, 86], have | {86}) == [70, 71], "the newest is up: the backlog oldest first"
    assert ya.upload_order(range(1, 70), have) == []

    # ---- playlist positions: a backlog shift goes before newer ones
    assert ya.position(70, list(range(1, 70)) + [85, 86]) == 69
    assert ya.position(1, [2, 3]) == 0
    assert ya.position(90, [1, 2]) == 2

    # ---- quota: what fits today
    ops = [{"op": "x", "units": 50}] * 10
    now, later = ya.within(ops, spent=9500, daily=10_000, margin=200)
    assert len(now) == 6 and len(later) == 4
    now, later = ya.within([{"units": 50}, {"units": 1600}, {"units": 50}], spent=8200, daily=10_000, margin=200)
    assert len(now) == 1 and len(later) == 2, "stops at the first that does not fit (order matters)"
    # an upload with its follow-ups
    assert ya.upload_units(85, set(range(1, 70)), 0) == 200, "thumbnail, its privacy, playlist insert, 69's demotion"
    assert ya.upload_units(70, set(range(1, 70)) | {85}, 0) == 150, "backlog under a newer latest: no demotion"
    assert ya.upload_units(64, set(range(1, 64)), 1600) == 1750, "63 is fixed public: no demotion"
    assert ya.upload_units(85, set(range(1, 70)), 1600) == 1800
    # the backlog after today's privacy run (7,009 units), today's 5 shift ends first: uploads bucket (0 units an
    # upload): 70-80 today, 81-84 tomorrow
    days, plan = ya.backlog_days(range(70, 85), range(1, 70), 0, spent_today=7009, new_today=5)
    assert days == 2 and plan == [[1, list(range(70, 81))], [2, list(range(81, 85))]], plan
    # 1,600 units an upload: 6 new shifts a day (6 x 1,800 = 10,800) do not fit, so the backlog never moves
    days, plan = ya.backlog_days(range(70, 85), range(1, 70), 1600, spent_today=7009, new_today=5)
    assert days is None, plan
    # 1,600 units with a quota of 30,000: the rotation fits and the backlog takes two days
    days, plan = ya.backlog_days(range(70, 85), range(1, 70), 1600, spent_today=7009, new_today=5, daily=30_000)
    assert days == 2 and plan == [[1, list(range(70, 77))], [2, list(range(77, 85))]], plan
    # the reserve for today's later shift ends: 200 units each, one per 4 hours left before midnight Pacific
    import datetime
    pdt = datetime.timezone(datetime.timedelta(hours=-7))
    assert ya.reserve_units(datetime.datetime(2026, 10, 27, 7, 30, tzinfo=pdt)) == 5 * 200
    assert ya.reserve_units(datetime.datetime(2026, 10, 27, 22, 0, tzinfo=pdt)) == 1 * 200
    # 100 uploads a day caps it
    days, plan = ya.backlog_days(range(1, 300), [], 0, daily=10**9, new_per_day=0)
    assert days == 3 and len(plan[0][1]) == 100

    # ---- apply with a stand-in client
    real = ya.Client
    ya.Client = FakeClient
    try:
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            small = vids(1, 2, 3, 63, 64)
            FakeClient.calls = []
            st, out = run_apply(tmp, state_of(small, playlist=None), small)
            names = [c[0] for c in FakeClient.calls]
            assert names == ["playlists.insert"] + ["videos.update"] * 5 + ["playlistItems.insert"] * 5, names
            up = [c[1] for c in FakeClient.calls if c[0] == "videos.update"]
            assert [u["id"] for u in up[:3]] == ["VID01xxxxx", "VID63xxxxx", "VID64xxxxx"]
            assert up[0]["status"] == {"privacyStatus": "public", "embeddable": True, "license": "youtube",
                                       "publicStatsViewable": True, "selfDeclaredMadeForKids": False}, up[0]
            pos = [c[1]["snippet"]["position"] for c in FakeClient.calls if c[0] == "playlistItems.insert"]
            assert pos == [0, 1, 2, 3, 4], pos
            assert {r: x["privacy"] for r, x in st["videos"].items()} == {
                "shift01": "public", "shift02": "unlisted", "shift03": "unlisted", "shift63": "public", "shift64": "public"}
            site = json.loads((tmp / "videos.json").read_text())
            assert list(site) == ["shift01", "shift02", "shift03", "shift63", "shift64"]
            assert site["shift02"]["playlist"] == "NEW1" and site["shift02"]["privacy"] == "unlisted"
            ledger = json.loads((tmp / "q.json").read_text())
            assert sum(day["units"] for day in ledger.values()) == 550
            # a rerun: nothing to do
            FakeClient.calls = []
            st2, _ = run_apply(tmp, st, small)
            assert FakeClient.calls == [] and st2["videos"] == st["videos"]
            # a new latest: 64 goes back to unlisted, 65 into the playlist after 64
            more = dict(small, **vids(65))
            st2["videos"]["shift65"] = {"id": "VID65xxxxx", "privacy": "public"}
            FakeClient.calls = []
            st3, _ = run_apply(tmp, st2, more)
            assert [(c[0], c[1].get("id") or c[1]["snippet"]["position"]) for c in FakeClient.calls] == [
                ("videos.update", "VID64xxxxx"), ("playlistItems.insert", 5)], FakeClient.calls
            assert st3["videos"]["shift64"]["privacy"] == "unlisted"

        # quota exceeded midway: stops, the day is marked, the state keeps what was done; private ones stay off the site
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            small = vids(1, 2, 3)
            FakeClient.calls, FakeClient.limit = [], 2
            st, out = run_apply(tmp, state_of(small), small)
            FakeClient.limit = None
            assert "quota exceeded" in out, out
            assert {r: x["privacy"] for r, x in st["videos"].items()} == {"shift01": "public", "shift02": "private",
                                                                         "shift03": "public"}, st
            assert list(json.loads((tmp / "videos.json").read_text())) == ["shift01", "shift03"]
            assert any(day["exhausted"] for day in json.loads((tmp / "q.json").read_text()).values())
        # the budget: with 200 units of room only the public ones go now
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            small = vids(1, 2, 3, 4, 5)
            FakeClient.calls = []
            st, out = run_apply(tmp, state_of(small), small, daily=400, margin=200)
            assert len(FakeClient.calls) == 4 and "wait for later days" in out, (FakeClient.calls, out)
    finally:
        ya.Client = real
        FakeClient.limit = None

    # ---- the ledger keys by Pacific day
    with tempfile.TemporaryDirectory() as d:
        led = ya.Ledger(Path(d) / "q.json", day="2026-10-27")
        led.spend("videos.update", "shift01", 50)
        led.spend("videos.insert", "shift85", 0, upload=True)
        again = ya.Ledger(Path(d) / "q.json", day="2026-10-27")
        assert again.today["units"] == 50 and again.today["uploads"] == 1
        assert ya.Ledger(Path(d) / "q.json", day="2026-10-28").today["units"] == 0
    import datetime
    utc = datetime.timezone.utc
    assert ya.pacific_day(datetime.datetime(2026, 10, 28, 6, 59, tzinfo=utc)) == "2026-10-27"
    assert ya.pacific_day(datetime.datetime(2026, 10, 28, 7, 1, tzinfo=utc)) == "2026-10-28"

    # ---- the owner's name may appear (Nick d27 10:10): a description naming him is uploaded and published as it is
    desc = ("Shift 29 of the run.\n\nFrom chat\n\u2022 NickWinter (host) asked: \"Sol: why?\" Sol answered: \"x\"\n"
            "Charts: https://factorio.nickwinter.net/runs/long/shift-29/")
    v29 = vids(28, 29)
    v29["shift29"]["description"] = desc
    v29["shift29"]["chapters"] = [{"at": 0, "time": "0:00", "title": "start"},
                                  {"at": 9243, "time": "2:34:03", "title": "NickWinter (host) asks: Sol"}]
    ops = ya.plan_ops(v29, state_of(v29, items=True))
    assert {o["op"] for o in ops} == {"videos.update"}, ops
    done29 = state_of(v29, "public", items=True)
    done29["videos"]["shift28"]["privacy"] = "unlisted"
    assert ya.plan_ops(v29, done29) == []
    with tempfile.TemporaryDirectory() as d:
        site = ya.site_videos(v29, done29, Path(d) / "videos.json")
        assert "NickWinter (host) asked" in site["shift29"]["description"] and len(site["shift29"]["chapters"]) == 2
    # tools/shift_video.py: the host's own chat account is not a viewer moment; a viewer's question naming him is
    import shift_video as sv
    with tempfile.TemporaryDirectory() as d:
        rows = [{"from": "viewer NickWinter (host)", "viewer": True, "text": "Sol: is it gone?", "tick": 10,
                 "logged_at": "2026-10-16T10:00:00-07:00"},
                {"from": "sol", "text": "NickWinter (host), yes.", "tick": 20, "logged_at": "2026-10-16T10:00:30-07:00"},
                {"from": "viewer Caleb", "viewer": True, "text": "Sol: did Nick see it?", "tick": 30, "logged_at": "2026-10-16T10:01:00-07:00"},
                {"from": "sol", "text": "Caleb, Nick saw the rail.", "tick": 40, "logged_at": "2026-10-16T10:01:30-07:00"}]
        (Path(d) / "chat.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        got = sv.viewer_moments(Path(d), 0, {"sol": "Sol"})
        assert [m["viewer"] for m in got] == ["Caleb"], got

    # ---- one rotate at a time: a live holder blocks, a gone one is taken over
    import os
    import subprocess
    with tempfile.TemporaryDirectory() as d:
        lock = Path(d) / "yt-rotate.lock"
        assert ya.rotate_lock(lock) is None and lock.read_text() == str(os.getpid())
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            lock.write_text(str(child.pid))
            assert ya.rotate_lock(lock) == child.pid
        finally:
            child.kill()
            child.wait()
        assert ya.rotate_lock(lock) is None, "the holder is gone"

    # ---- follow: the autopilot's "shiftN up" lines
    assert ya.UP_LINE.match("10-27 07:09:26 shift86 up ()").group(2) == "86"
    assert not ya.UP_LINE.match("10-27 07:09:26 watchdog shift86 pid 1")
    print("test_yt_archive: ok")


if __name__ == "__main__":
    main()
