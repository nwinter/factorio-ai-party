#!/usr/bin/env python3
"""The narrated tour (tour.py, Nick d23 10:28). Offline: python3 tools/stream/test_tour.py

1. The script: stops check (a look, a ship, bad targets and repeated ids are skipped with why), --from resumes.
2. Timing: a stop lasts max(seconds, clip + 2 s); the timeline estimates clips not prepared yet.
3. prepare: one voice for every clip, kept clips are not rendered again, a failure hands the tour to the next voice.
4. run (a fake service and clock): the camera goes to each target, the look is renewed before its 60 s, a platform stop
   clears the tour's look, a refused stop is skipped, the narration posts as an urgent narrator clip and the stop is
   timed from its start; the hosts are hushed all the while and unhushed after; stop ends it and clears the holds;
   the log says what aired when.
5. caster.py: the hush file keeps the hosts quiet (no lines, no reactions, the gap starts again after it).
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tour  # noqa: E402
import caster  # noqa: E402

LOOK = {"id": "a", "target": {"surface": "nauvis", "x": 10, "y": -5, "zoom": 0.5}, "seconds": 20, "caption": "Start",
        "narration": "Where it began.", "facts": ["x"]}
SHIP = {"id": "b", "target": {"platform": "Spindle"}, "seconds": 10, "caption": "A ship", "narration": "A ship."}
LONG = {"id": "c", "target": {"surface": "vulcanus", "x": 0, "y": 0}, "seconds": 95, "caption": "Long",
        "narration": "Slow."}


def script_checks():
    rows = tour.checked([LOOK, SHIP, {"id": "a", "target": {"platform": "X"}}, {"id": "d", "target": {"surface": "nauvis",
                         "x": "far", "y": 0}}, {"target": {"platform": "Y"}}, {"id": "e"}, "junk", LONG])
    ok = [s["id"] for _, s, _ in rows if s]
    assert ok == ["a", "b", "c"], ok
    why = [w for _, s, w in rows if not s]
    assert why[0] == "id 'a' repeated" and "not a finite number" in why[1] and why[2] == "no id" and \
        why[3] == "no target" and why[4] == "not an object", why
    assert rows[0][1]["target"] == {"surface": "nauvis", "x": 10.0, "y": -5.0, "zoom": 0.5}
    assert rows[1][1]["target"] == {"platform": "Spindle"}
    assert [s["id"] for _, s, _ in tour.from_index(rows, "b") if s] == ["b", "c"]
    try:
        tour.from_index(rows, "zz")
        raise AssertionError("an unknown --from id")
    except SystemExit as x:
        assert "no stop with id 'zz'" in str(x)


def timing():
    s = tour.check_stop(LOOK)[0]
    assert tour.stop_length(s, 30.0) == 32.0 and tour.stop_length(s, 5.0) == 20.0 and tour.stop_length(s, None) == 20
    rows = tour.checked([LOOK, SHIP])
    plan, bad = tour.timeline(rows, None, "/nowhere")
    assert not bad and [p[3] for p in plan] == [True, True]  # estimated
    assert plan[0][2] == 3 / tour.WORDS_PER_S


class FakeTTS:
    def __init__(self, fail_on=None):
        self.said, self.fail_on = [], fail_on

    def __call__(self, text):
        if self.fail_on and self.fail_on in text:
            raise RuntimeError("402 quota_exceeded")
        self.said.append(text)
        return b"ID3fake" + text.encode(), "audio/mpeg", len(text.split()) * 0.5, "eleven"


def prepare_clips():
    with tempfile.TemporaryDirectory() as d:
        rows = tour.checked([LOOK, SHIP])
        fake = FakeTTS()
        clips, err = tour.render_all(rows, d, "el-brian", None, None, speak=fake)
        assert err is None and set(clips) == {"a", "b"} and len(fake.said) == 2
        m = {"voice": "el-brian", "clips": clips}
        assert tour.clip_for(m, d, rows[0][1])["duration"] == 1.5
        # unchanged: nothing rendered again; one narration edited: that clip alone
        fake2 = FakeTTS()
        edited = tour.checked([LOOK, dict(SHIP, narration="A ship, edited.")])
        clips2, err = tour.render_all(edited, d, "el-brian", None, m, speak=fake2)
        assert err is None and fake2.said == ["A ship, edited."], fake2.said
        assert tour.clip_for(m, d, edited[1][1]) is None  # the old manifest's clip is stale for the new text
        # another voice renders everything again (one voice for the whole tour)
        fake3 = FakeTTS()
        tour.render_all(rows, d, "oa-fable", None, {"voice": "el-brian", "clips": clips2}, speak=fake3)
        assert len(fake3.said) == 2
        # a failure stops the render with the stop and the provider's reply
        clips, err = tour.render_all(tour.checked([LOOK, dict(SHIP, narration="A new ship.")]), d, "el-brian", None,
                                     m, speak=FakeTTS(fail_on="new"))
        assert err and err.startswith("b: RuntimeError: 402"), err


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += max(s, 0.01)


class FakeService:
    """serve.py's endpoints as the tour uses them: /look (max 60 s, refuses uncharted), /platform, /audio, state."""
    def __init__(self, clock, refuse=(), platforms=("Spindle",)):
        self.clock, self.refuse, self.platforms = clock, set(refuse), platforms
        self.calls, self.look_hold, self.plat_hold, self.clips, self.seq = [], None, None, [], 0

    def call(self, method, path, body=None, timeout=10):
        self.calls.append((round(self.clock() - 1000, 1), method, path, body))
        now = self.clock()
        if (method, path) == ("POST", "/look"):
            if (body["surface"], body["x"], body["y"]) in self.refuse:
                return 409, {"error": "not charted"}
            self.look_hold = {"by": body["by"], "until": now + min(60, body["seconds"]), "label": body["label"]}
            return 200, {}
        if (method, path) == ("POST", "/platform"):
            if body["name"] not in self.platforms:
                return 400, {"error": f"unknown platform {body['name']!r}"}
            self.plat_hold = {"name": body["name"], "by": body["by"], "until": now + body["seconds"]}
            return 200, {}
        if method == "DELETE":
            if path == "/look":
                self.look_hold = None
            else:
                self.plat_hold = None
            return 200, {}
        if (method, path) == ("POST", "/audio"):
            self.seq += 1
            self.clips.append(dict(body, id=f"c{self.seq}", posted=now))
            return 200, {"id": f"c{self.seq}"}
        raise AssertionError((method, path))

    def state(self):
        now = self.clock()
        look = self.look_hold if self.look_hold and self.look_hold["until"] > now else None
        plat = self.plat_hold if self.plat_hold and self.plat_hold["until"] > now else None
        return {"look": look, "platform_hold": plat,
                "onair": {"look": {"label": look["label"]} if look else None,
                          "platform": {"name": plat["name"]} if plat and not look else None}}

    def audio_status(self):
        # each clip starts 1 s after it is posted (the page fetches and decodes it)
        now = self.clock()
        return {"listeners": 1, "playing": [{"id": c["id"]} for c in self.clips
                                            if c["posted"] + 1 <= now < c["posted"] + 1 + c["duration"]]}


def tour_with(d, stops, clip_s, **kw):
    rows = tour.checked(stops)
    clips = {}
    for _, s, _ in rows:
        if s:
            h = tour.clip_hash("el-brian", s["narration"])
            open(os.path.join(d, f"{s['id']}.mp3"), "wb").write(b"ID3")
            clips[s["id"]] = {"file": f"{s['id']}.mp3", "hash": h, "duration": clip_s}
    m = {"voice": "el-brian", "clips": clips}
    clock = Clock()
    svc = FakeService(clock, **kw)
    t = tour.Tour(svc, rows, m, d, os.path.join(d, "tour.jsonl"), hush_file=os.path.join(d, "hush.json"),
                  stop_file=os.path.join(d, "stop"), clock=clock, sleep=clock.sleep)
    return t, svc, clock, rows


def run_tour():
    with tempfile.TemporaryDirectory() as d:
        t, svc, clock, rows = tour_with(d, [LOOK, SHIP, LONG], clip_s=12.0)
        hushes = []
        real_hush = t.hush
        t.hush = lambda secs: (real_hush(secs), hushes.append(json.load(open(t.hush_file))))
        aired, skipped = t.run(rows)
        assert (aired, skipped) == (3, 0)
        assert hushes and all(h["by"] == "tour" and h["until"] > 1000 for h in hushes)
        assert not os.path.exists(t.hush_file), "the hosts are unhushed after the tour"
        assert svc.look_hold is None and svc.plat_hold is None, "the tour's holds are cleared"
        # narration: one urgent narrator clip per stop, the caption as its line
        assert [c["tour"] for c in svc.clips] == ["a", "b", "c"]
        assert all(c["channel"] == "narrator" and c["rank"] == "urgent" and c["speaker"] == "Narrator" for c in svc.clips)
        assert svc.clips[0]["text"] == "Start" and svc.clips[0]["expires_in"] >= 120
        rows_log = [json.loads(x) for x in open(t.log_path)]
        ev = [r["event"] for r in rows_log]
        assert ev == ["start", "aired", "aired", "aired", "end"], ev
        a, b, c = rows_log[1:4]
        # stop a: 20 s on screen, clip 12 s from its start + 2 s: 20 s wins; ship b: 10 s but clip 12 + 2 = 14 s
        assert 19.5 <= a["seconds"] <= 22, a
        assert b["narration_start"] and b["ended"] - b["narration_start"] >= 14.0 - 0.05, b
        assert b["ended"] - b["narration_start"] < 15, b
        # the long look (95 s) was renewed before its 60 s ran out, and no request asked for more than 60 s
        looks = [x for x in svc.calls if x[1:3] == ("POST", "/look")]
        c_looks = [x for x in looks if x[3]["surface"] == "vulcanus"]
        assert len(c_looks) == 2 and all(x[3]["seconds"] <= 60 for x in looks), c_looks
        assert len([x for x in looks if x[3]["surface"] == "nauvis"]) == 1, "a short stop's look is asked for once"
        assert c["seconds"] >= 95, c
        # the ship stop cleared the tour's look (a look outranks a platform hold); the look after cleared the ship
        order = [(x[1], x[2]) for x in svc.calls if x[1] in ("POST", "DELETE") and x[2] in ("/look", "/platform")]
        i = order.index(("POST", "/platform"))
        assert order[i + 1] == ("DELETE", "/look"), order
        assert ("DELETE", "/platform") in order[i + 2:], order


def skip_and_stop():
    with tempfile.TemporaryDirectory() as d:
        bad_ship = dict(SHIP, id="gone", target={"platform": "Nowhere"})
        t, svc, clock, rows = tour_with(d, [dict(LOOK, id="uncharted"), bad_ship, LONG], clip_s=5.0,
                                        refuse=[("nauvis", 10.0, -5.0)])
        aired, skipped = t.run(rows)
        assert (aired, skipped) == (1, 2)
        log = [json.loads(x) for x in open(t.log_path)]
        sk = [r for r in log if r["event"] == "skipped"]
        assert [r["id"] for r in sk] == ["uncharted", "gone"] and sk[0]["reason"] == "not charted", sk
        assert "unknown platform" in sk[1]["reason"]
        assert [c["tour"] for c in svc.clips] == ["c"], "a skipped stop's narration does not air"
    with tempfile.TemporaryDirectory() as d:
        t, svc, clock, rows = tour_with(d, [LONG, LOOK], clip_s=5.0)
        real = clock.sleep

        def sleep(s):  # the operator runs `tour.py stop` 30 s in
            real(s)
            if clock.t >= 1030 and not os.path.exists(t.stop_file):
                open(t.stop_file, "w").close()
        t.sleep = sleep
        aired, _ = t.run(rows)
        assert aired == 1 and t.stopped
        log = [json.loads(x) for x in open(t.log_path)]
        assert log[1]["event"] == "aired" and log[1]["cut_short"] and log[1]["seconds"] < 35, log[1]
        assert log[-1] == dict(log[-1], event="end", stopped=True)
        assert svc.look_hold is None and not os.path.exists(t.hush_file)


def operator_hold_kept():
    """An operator's own look posted mid-tour is not cleared at the end."""
    with tempfile.TemporaryDirectory() as d:
        t, svc, clock, rows = tour_with(d, [LOOK], clip_s=3.0)
        t.run(rows)
        svc.look_hold = {"by": "operator", "until": clock() + 30, "label": "x"}
        t.finish()
        assert svc.look_hold and svc.look_hold["by"] == "operator"


class Args:
    pass


def caster_hush():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "hush.json")
        assert caster.hushed(path, 100) is None and caster.hushed(None) is None
        json.dump({"until": 200, "by": "tour", "reason": "r"}, open(path, "w"))
        assert caster.hushed(path, 100)["by"] == "tour" and caster.hushed(path, 300) is None
        open(path, "w").write("{bad")
        assert caster.hushed(path, 100) is None
        c = caster.Caster.__new__(caster.Caster)
        c.a = Args()
        c.a.hush_file = path
        recs = []
        c.record = lambda **kw: recs.append(kw)
        c.caster_free, c.yielding, c.pending_news = 0.0, {"until": 999}, ("x",)
        json.dump({"until": 200, "by": "tour"}, open(path, "w"))
        assert c.hush_tick(150) is True and c.caster_free == 150 and c.yielding is None and c.pending_news is None
        assert c.hush_tick(160) is True and len(recs) == 1 and recs[0]["on"]
        assert c.caster_free == 160
        # caster_tick says nothing while hushed (it returns before reading the snapshot)
        c.snap = None
        assert c.caster_tick(170, {"listeners": 1}) is None and c.caster_free == 170
        os.remove(path)
        assert c.hush_tick(180) is False and recs[-1] == {"type": "hush", "on": False}
        assert c.hush_tick(181) is False and len(recs) == 2
        # the flag is on by default at logs/hosts-hush.json, the path tour.py writes
        assert caster.parser().parse_args([]).hush_file == tour.HUSH_FILE == caster.HUSH_FILE


def cli_dry_run():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "s.json")
        json.dump({"stops": [LOOK, SHIP, {"id": "x"}]}, open(p, "w"))
        import io, contextlib
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            assert tour.main(["dry-run", p, "--feed", "http://127.0.0.1:9"]) == 0
        text = out.getvalue()
        assert "a / nauvis (10, -5) zoom 0.5 / Start" in text and "ship Spindle" in text and "skip  stop 3: no target" in text
        assert "total 0:30 (2 stops, 1 invalid; 2 clip lengths estimated" in text, text
        assert not os.path.exists(os.path.join(d, "tour-clips")), "dry-run writes nothing"


if __name__ == "__main__":
    for f in (script_checks, timing, prepare_clips, run_tour, skip_and_stop, operator_hold_kept, caster_hush,
              cli_dry_run):
        f()
        print("ok", f.__name__)
    print("test_tour: all ok")
