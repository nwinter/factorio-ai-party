#!/usr/bin/env python3
"""The narrated tour (tour.py, Nick d23 10:28; v2 d23 17:30). Offline: python3 tools/stream/test_tour.py

1. The script: stops check (a look, a ship, bad targets and repeated ids are skipped with why), --from resumes.
2. Timing (CK1): a narrated stop lasts lead + clip + tail (+ hold_s, at least min_seconds; its seconds unused), a silent
   one its seconds; the timeline estimates clips not prepared yet.
3. prepare: one voice for every clip, kept clips are not rendered again, a failure hands the tour to the next voice.
4. run (a fake service and clock): one timeline: each stop sent PREROLL_S ahead with cut_at and its narration with at
   = cut + lead; the next cut at the stop's end; the measured drift (aired - cut asked) asked sooner next time; the
   look extended (no new chart read) on a long stop; a ship by platform; an agent line waiting holds a stop its length;
   a refused stop is skipped and the next takes its cut; stop takes back a narration not played and clears the look;
   the hosts are hushed all the while; the log says what aired when.
5. (CK3, CK4) the overlay: marks with the view the look gave; captions timed from the narration's moment (the
   narrator's own caption box left out then), off by stop or by run.
6. (CK2) moves: to, zoom, path and lists become camera moves over the stop (times from the cut, "end" and negative
   counted from the end, holds share the time); a whole ship pans on its own and refuses a move with no spot to start
   from; a bad move makes the stop invalid; the look carries it (dry-run prints it).
6. caster.py: the hush file keeps the hosts quiet (no lines, no reactions, the gap starts again after it).
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
    L, T = tour.LEAD_S, tour.TAIL_S
    assert tour.stop_length(s, 30.0) == L + 30 + T, "the clip sets a narrated stop's length; its seconds are not used"
    assert tour.stop_length(s, 5.0) == L + 5 + T and tour.stop_length(s, None) == 20
    assert tour.stop_length(tour.check_stop(dict(LOOK, min_seconds=40))[0], 30.0) == 40
    assert tour.stop_length(tour.check_stop(dict(LOOK, hold_s=3))[0], 30.0) == L + 30 + T + 3
    assert tour.stop_length(tour.check_stop(dict(LOOK, seconds=None))[0], None) == tour.SILENT_S
    assert tour.stop_length(tour.check_stop(dict(LOOK, seconds=1))[0], None) == tour.MIN_STOP_S
    assert tour.stop_length(s, 10.0, lead=0.5, tail=1.0) == 11.5
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
        assert clips["a"]["subs_v"] == tour.SUBS_V and clips["a"]["subs"][0]["text"] == "Where it began."  # (CK4)
        # a kept clip made before captions gets them, with nothing rendered
        old = {k: {kk: vv for kk, vv in v.items() if kk not in ("subs", "subs_v")} for k, v in clips.items()}
        fake0 = FakeTTS()
        again, _ = tour.render_all(rows, d, "el-brian", None, {"voice": "el-brian", "clips": old}, speak=fake0)
        assert not fake0.said and again["b"]["subs"][0]["text"] == "A ship."
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
    """serve.py's endpoints as the tour uses them: /look (cut_at, aired DELAY after it; max 60 s; refuses uncharted and
    unknown ships), /look/extend, /audio (at: playing from it), /audio/status (playing, queued), /audio/cancel."""
    DELAY = 0.2  # the program cuts this long after cut_at

    def __init__(self, clock, refuse=(), platforms=("Spindle",), queued=()):
        self.clock, self.refuse, self.platforms, self.queued = clock, set(refuse), platforms, list(queued)
        self.calls, self.look_hold, self.clips, self.seq, self.cancelled = [], None, [], 0, []
        self.overlays = []

    def call(self, method, path, body=None, timeout=10):
        self.calls.append((round(self.clock() - 1000, 2), method, path, body))
        now = self.clock()
        if (method, path) == ("POST", "/look"):
            if "platform" in body:
                if body["platform"] not in self.platforms:
                    return 409, {"error": f"no camera view for a platform named {body['platform']!r}"}
            elif (body["surface"], body["x"], body["y"]) in self.refuse:
                return 409, {"error": "not charted"}
            assert body["seconds"] <= 60 and now - 1 <= body["cut_at"] <= now + 30, body
            until = max(now, body["cut_at"]) + body["seconds"]
            self.look_hold = {"by": body["by"], "until": until, "label": body["label"], "id": body["id"],
                              "cut_at": body["cut_at"]}
            if "platform" in body:  # the director's frame of the ship
                return 200, {"until": until, "surface": "platform-1", "position": {"x": 0, "y": -3}, "zoom": 0.6}
            return 200, {"until": until, "surface": body["surface"], "position": {"x": body["x"], "y": body["y"]},
                         "zoom": body.get("zoom", 0.75), **({"move": body["move"]} if isinstance(body.get("move"), dict) else {})}
        if (method, path) == ("POST", "/look/extend"):
            if not self.look_hold or self.look_hold["id"] != body["id"]:
                return 409, {"error": "no look on"}
            self.look_hold["until"] = now + min(60, body["seconds"])
            return 200, {"until": self.look_hold["until"]}
        if (method, path) == ("DELETE", "/look"):
            self.look_hold = None
            return 200, {}
        if (method, path) == ("DELETE", "/platform"):
            return 200, {}
        if (method, path) == ("POST", "/tour/overlay"):
            self.overlays.append(body)
            return 200, {"id": body["id"]}
        if (method, path) == ("DELETE", "/tour/overlay"):
            self.overlays.append(None)
            return 200, {}
        if (method, path) == ("POST", "/audio"):
            self.seq += 1
            self.clips.append(dict(body, id=f"c{self.seq}", posted=now))
            return 200, {"id": f"c{self.seq}"}
        if (method, path) == ("POST", "/audio/cancel"):
            self.cancelled.append(body["id"])
            return 200, {"cancelled": True}
        raise AssertionError((method, path))

    def state(self):
        now = self.clock()
        lk = self.look_hold if self.look_hold and self.look_hold["until"] > now else None
        if lk and now >= lk["cut_at"] + self.DELAY:
            lk = dict(lk, aired=lk["cut_at"] + self.DELAY)
        return {"look": lk}

    def audio_status(self):
        now = self.clock()
        playing = [{"id": c["id"], "started": c["at"] + 0.01} for c in self.clips
                   if c["id"] not in self.cancelled and c["at"] <= now < c["at"] + c["duration"]]
        queued = [dict(q, expires_in=q["expires"] - now) for q in self.queued if q["expires"] > now]
        return {"listeners": 1, "playing": playing, "queued": queued}


def tour_with(d, stops, clip_s, agent_gaps=True, **kw):
    rows = tour.checked(stops)
    clips = {}
    for _, s, _ in rows:
        if s and s["narration"]:
            h = tour.clip_hash("el-brian", s["narration"])
            open(os.path.join(d, f"{s['id']}.mp3"), "wb").write(b"ID3")
            clips[s["id"]] = {"file": f"{s['id']}.mp3", "hash": h, "duration": clip_s}
    m = {"voice": "el-brian", "clips": clips}
    clock = Clock()
    svc = FakeService(clock, **kw)
    t = tour.Tour(svc, rows, m, d, os.path.join(d, "tour.jsonl"), hush_file=os.path.join(d, "hush.json"),
                  stop_file=os.path.join(d, "stop"), clock=clock, sleep=clock.sleep, agent_gaps=agent_gaps)
    return t, svc, clock, rows


def run_tour():
    with tempfile.TemporaryDirectory() as d:
        long = dict(LONG, min_seconds=95)
        t, svc, clock, rows = tour_with(d, [LOOK, SHIP, long], clip_s=12.0)
        hushes = []
        real_hush = t.hush
        t.hush = lambda secs: (real_hush(secs), hushes.append(json.load(open(t.hush_file))))
        aired, skipped = t.run(rows)
        assert (aired, skipped) == (3, 0)
        assert hushes and all(h["by"] == "tour" and h["until"] > 1000 for h in hushes)
        assert not os.path.exists(t.hush_file), "the hosts are unhushed after the tour"
        assert svc.look_hold is None, "the tour's look is cleared"
        log = [json.loads(x) for x in open(t.log_path)]
        assert [r["event"] for r in log] == ["start", "aired", "aired", "aired", "end"], log
        a, b, c = log[1:4]
        L, T = tour.LEAD_S, tour.TAIL_S
        # one timeline: each cut at the last stop's end (lead + clip + tail; the long stop's min_seconds)
        assert abs(b["cut"] - (a["cut"] + L + 12 + T)) < 1e-6 and abs(c["cut"] - (b["cut"] + L + 12 + T)) < 1e-6
        assert abs(log[-1]["t"] - (c["cut"] + 95)) < 0.6, (log[-1]["t"], c["cut"])
        assert all(abs(r["narration_at"] - (r["cut"] + L)) < 1e-6 for r in (a, b, c))
        assert all(abs(r["ended"] - n["cut"]) < 1e-6 for r, n in ((a, b), (b, c)))
        # narration: one urgent narrator clip per stop, at its moment, the caption as its line
        assert [x["tour"] for x in svc.clips] == ["a", "b", "c"]
        assert all(x["channel"] == "narrator" and x["rank"] == "urgent" and x["speaker"] == "Narrator" for x in svc.clips)
        assert [x["at"] for x in svc.clips] == [r["narration_at"] for r in (a, b, c)] and svc.clips[0]["text"] == "Start"
        assert all(r["cut"] - x["posted"] >= tour.PREROLL_S - 0.6 for r, x in zip((a, b, c), svc.clips)), \
            "each narration goes to the page ahead of its moment"
        # the looks: sent ahead with cut_at; the drift (aired - asked, 0.2 s here) asked sooner from the second stop
        looks = [x for x in svc.calls if x[1:3] == ("POST", "/look")]
        assert [x[3]["id"] for x in looks] == ["a", "b", "c"] and looks[1][3]["platform"] == "Spindle"
        assert looks[0][3]["cut_at"] == a["cut"] and abs(a["on_air"] - a["cut"] - 0.2) < 1e-6
        assert abs(looks[1][3]["cut_at"] - (b["cut"] - 0.1)) < 1e-6 and abs(looks[2][3]["cut_at"] - (c["cut"] - 0.15)) < 1e-6
        assert abs(log[-1]["drift_s"] - 0.175) < 1e-6
        assert all(1000 + x[0] <= r["cut"] - tour.MIN_PREROLL_S for x, r in zip(looks, (a, b, c)))
        # the long stop: extended before its 60 s ran out, no second chart-read look
        ext = [x for x in svc.calls if x[2] == "/look/extend"]
        assert ext and all(x[3]["id"] == "c" for x in ext), ext
        assert c["narration_start"] and abs(c["narration_start"] - c["narration_at"]) < 0.05
        assert not any(x[2] == "/platform" and x[1] == "POST" for x in svc.calls)


def agent_gaps():
    """An agent's line waiting in the queue near a stop's end holds that stop for its length (not the last stop)."""
    with tempfile.TemporaryDirectory() as d:
        line = {"id": "q1", "channel": "agent", "speaker": "Sol", "duration": 6.0, "at": None, "expires": 1060.0}
        t, svc, clock, rows = tour_with(d, [LOOK, SHIP], clip_s=12.0, queued=[line])
        t.run(rows)
        log = [json.loads(x) for x in open(t.log_path)]
        a, b = log[1:3]
        assert a["agent_gap_s"] == 6.0 and a["agent_gap_for"] == "Sol", a
        assert abs(b["cut"] - (a["cut"] + tour.LEAD_S + 12 + tour.TAIL_S + 6)) < 1e-6
        assert b["agent_gap_s"] is None, "the last stop is not held"
    with tempfile.TemporaryDirectory() as d:  # expiring before the narration ends, or gaps off: no hold
        line = {"id": "q1", "channel": "agent", "speaker": "Sol", "duration": 6.0, "at": None, "expires": 1010.0}
        t, svc, clock, rows = tour_with(d, [LOOK, SHIP], clip_s=12.0, queued=[line])
        t.run(rows)
        assert json.loads(open(t.log_path).readlines()[1])["agent_gap_s"] is None
        t, svc, clock, rows = tour_with(d, [LOOK, SHIP], clip_s=12.0, agent_gaps=False,
                                        queued=[dict(line, expires=1100.0)])
        t.log_path = os.path.join(d, "t2.jsonl")
        t.run(rows)
        assert json.loads(open(t.log_path).readlines()[1])["agent_gap_s"] is None


def skip_and_stop():
    with tempfile.TemporaryDirectory() as d:
        bad_ship = dict(SHIP, id="gone", target={"platform": "Nowhere"})
        t, svc, clock, rows = tour_with(d, [LOOK, dict(LOOK, id="uncharted", target={"surface": "nauvis", "x": 99,
                                        "y": 99}), bad_ship, LONG], clip_s=5.0, refuse=[("nauvis", 99.0, 99.0)])
        aired, skipped = t.run(rows)
        assert (aired, skipped) == (2, 2)
        log = [json.loads(x) for x in open(t.log_path)]
        sk = [r for r in log if r["event"] == "skipped"]
        assert [r["id"] for r in sk] == ["uncharted", "gone"] and sk[0]["reason"] == "not charted", sk
        assert "no camera view for a platform" in sk[1]["reason"]
        assert [x["tour"] for x in svc.clips] == ["a", "c"], "a skipped stop's narration does not air"
        a, c = [r for r in log if r["event"] == "aired"]
        assert abs(c["cut"] - a["ended"]) < 1e-6 and c["cut"] - (a["cut"] + tour.LEAD_S + 5 + tour.TAIL_S) < 0.6, \
            "the next stop takes the skipped ones' time"
    with tempfile.TemporaryDirectory() as d:
        t, svc, clock, rows = tour_with(d, [dict(LONG, min_seconds=95), LOOK], clip_s=5.0)
        real = clock.sleep

        def sleep(s):  # the operator runs `tour.py stop` 30 s in
            real(s)
            if clock.t >= 1030 and not os.path.exists(t.stop_file):
                open(t.stop_file, "w").close()
        t.sleep = sleep
        aired, _ = t.run(rows)
        assert aired == 0 and t.stopped
        log = [json.loads(x) for x in open(t.log_path)]
        assert log[1]["event"] == "aired" and log[1]["cut_short"] and log[1]["seconds"] < 30, log[1]
        assert log[-1] == dict(log[-1], event="end", stopped=True)
        assert svc.look_hold is None and not os.path.exists(t.hush_file)
        assert svc.cancelled == ["c1"], "the narration scheduled is taken back"
    with tempfile.TemporaryDirectory() as d:  # stopped in the preroll: the next stop's narration is taken back
        t, svc, clock, rows = tour_with(d, [LOOK, SHIP], clip_s=5.0)
        real = clock.sleep

        def sleep(s):
            real(s)
            if len(svc.clips) == 2 and not os.path.exists(t.stop_file):
                open(t.stop_file, "w").close()
        t.sleep = sleep
        t.run(rows)
        assert svc.cancelled == ["c1", "c2"] and svc.look_hold is None


def operator_hold_kept():
    """An operator's own look posted mid-tour is not cleared at the end."""
    with tempfile.TemporaryDirectory() as d:
        t, svc, clock, rows = tour_with(d, [LOOK], clip_s=3.0)
        t.run(rows)
        svc.look_hold = {"by": "operator", "until": clock() + 30, "label": "x", "id": None, "cut_at": 0}
        t.finish()
        assert svc.look_hold and svc.look_hold["by"] == "operator"


def moves():
    spot = {"id": "m", "target": {"surface": "nauvis", "x": 10, "y": 0, "zoom": 0.5}, "narration": "x"}
    mf = lambda m, n=20.0, **kw: tour.move_for(tour.check_stop(dict(spot, move=m, **kw))[0], n)
    seg = mf({"to": {"x": 40}, "zoom": 0.9})["segments"]
    assert seg == [{"pts": [{"x": 10.0, "y": 0.0, "zoom": 0.5}, {"x": 40.0, "y": 0.0, "zoom": 0.9}], "t0": 0.0,
                    "t1": 20.0, "ease": "inout"}], seg
    seg = mf({"zoom": 1.2, "from_s": 2, "to_s": -3, "ease": "out"})["segments"][0]
    assert (seg["t0"], seg["t1"], seg["ease"], seg["pts"][1]) == (2.0, 17.0, "out", {"x": 10.0, "y": 0.0, "zoom": 1.2})
    assert mf({"to": {"x": 0}, "to_s": "end"}, 33)["segments"][0]["t1"] == 33.0
    segs = mf([{"zoom": 1.0}, "hold", {"path": [{"x": 30, "y": 10}, {"x": 50, "y": -10, "zoom": 0.6}]}], 30)["segments"]
    assert [(g["t0"], g["t1"]) for g in segs] == [(0.0, 10.0), (20.0, 30.0)], segs
    assert segs[1]["pts"] == [{"x": 10.0, "y": 0.0, "zoom": 1.0}, {"x": 30.0, "y": 10.0, "zoom": 1.0},
                              {"x": 50.0, "y": -10.0, "zoom": 0.6}], "the next move starts where the last ended"
    assert mf(None) is None and mf("hold") is None
    ship = {"id": "s", "target": {"platform": "Spindle"}, "narration": "x"}
    assert tour.move_for(tour.check_stop(ship)[0], 20) == "pan"
    assert tour.move_for(tour.check_stop(dict(ship, move="hold"))[0], 20) is None
    path = tour.move_for(tour.check_stop(dict(ship, move={"path": [{"x": 0, "y": -40, "zoom": 1}, {"x": 0, "y": 40}]}))[0], 20)
    assert path["segments"][0]["pts"][1] == {"x": 0.0, "y": 40.0, "zoom": 1.0}
    why = [w for _, x, w in tour.checked([dict(spot, move={"zoom": 9}), dict(ship, move={"zoom": 1}),
                                         dict(spot, id="j", move={"jump": 1}), dict(spot, id="k", move=[{}] * 9)])]
    assert why == ["move: segment 1 point 2 zoom must be 0.3..3",
                   "move: a whole ship has no spot to move from: give target x, y or a path",
                   "move: give to {x, y, zoom}, zoom, or path [...]", "move is one move or a list of 1..8"], why
    # the look carries it: a spot's move, a ship's pan over the stop
    t = tour.Tour(None, [], None, None, os.devnull)
    b = t.look_body(tour.check_stop(dict(spot, move={"zoom": 1}))[0], 1000, 30, 20)
    assert b["move"]["segments"][0]["t1"] == 20.0 and b["seconds"] == 30
    b = t.look_body(tour.check_stop(ship)[0], 1000, 30, 25)
    assert b["move"] == "pan" and b["move_s"] == 25 and b["platform"] == "Spindle"


def overlays():
    """(CK3) A stop with marks posts them with the view the look gave (its move too), ahead of the cut; the end clears."""
    with tempfile.TemporaryDirectory() as d:
        marks = [{"type": "circle", "at": {"x": 12, "y": -5}, "text": "the pad", "to_s": -2}]
        ship = dict(SHIP, marks=[{"type": "arrow", "at": {"x": 0, "y": 10}, "from": "e"}])
        t, svc, clock, rows = tour_with(d, [dict(LOOK, marks=marks, move={"zoom": 1}), LONG, ship], clip_s=6.0)
        t.run(rows)
        by = {o["id"]: o for o in svc.overlays if o}
        a, c, s = by["a"], by["c"], by["b"]
        log = [json.loads(x) for x in open(t.log_path)]
        cut_a = next(r["cut"] for r in log if r.get("id") == "a")
        assert a["id"] == "a" and a["cut"] == cut_a and a["length"] == tour.LEAD_S + 6 + tour.TAIL_S
        assert a["marks"][0]["text"] == "the pad" and a["marks"][0]["to_s"] == -2.0
        assert a["view"]["position"] == {"x": 10.0, "y": -5.0} and a["view"]["move"]["segments"][0]["pts"][1]["zoom"] == 1
        assert a["until"] == cut_a + a["length"] + tour.LOOK_SPARE_S
        assert s["view"] == {"surface": "platform-1", "position": {"x": 0, "y": -3}, "zoom": 0.6}, "a ship: the frame given"
        assert svc.overlays[-1] is None, "the end clears the overlay"
        # (CK4) captions: every narrated stop's, timed from its narration's moment; the narrator's own box left out
        assert c["marks"] == [] and c["subs"] and c["subs"][0]["text"] == "Slow." and c["subs_pos"] == "bottom"
        narr = {x["tour"]: x for x in svc.clips}
        assert all(o["subs_at"] == narr[i]["at"] for i, o in by.items())
        assert all(x["caption"] is False for x in svc.clips)
    with tempfile.TemporaryDirectory() as d:  # subtitles false (a stop) or off (the run): no captions, the box back
        t, svc, clock, rows = tour_with(d, [dict(LOOK, subtitles=False), dict(LONG, subtitles="top")], clip_s=6.0)
        t.run(rows)
        assert [o["id"] for o in svc.overlays if o] == ["c"] and svc.overlays[0]["subs_pos"] == "top"
        assert [x["caption"] for x in svc.clips] == [True, False]
        t, svc, clock, rows = tour_with(d, [LOOK], clip_s=6.0)
        t.subtitles = False
        t.run(rows)
        assert not [o for o in svc.overlays if o] and svc.clips[0]["caption"] is True
    why = [w for _, x, w in tour.checked([dict(LOOK, marks=[{"type": "star", "at": {"x": 0, "y": 0}}])])]
    assert why == ["mark 1: type must be one of arrow, circle, box, label"], why


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
        # a: 0.8 + 3 words / 2.5 + 1.5 = 3.5 s (MIN_STOP_S 3); b: 0.8 + 0.8 + 1.5 = 3.1 s; its 20 s noted as unused
        assert "total 0:06 (2 stops, 1 invalid; 2 clip lengths estimated" in text, text
        assert "seconds not used for 2 narrated stops (a, b)" in text, text
        assert not os.path.exists(os.path.join(d, "tour-clips")), "dry-run writes nothing"


if __name__ == "__main__":
    for f in (script_checks, timing, prepare_clips, run_tour, agent_gaps, skip_and_stop, operator_hold_kept, moves,
              overlays, caster_hush, cli_dry_run):
        f()
        print("ok", f.__name__)
    print("test_tour: all ok")
