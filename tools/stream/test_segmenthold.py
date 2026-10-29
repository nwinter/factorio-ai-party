#!/usr/bin/env python3
"""The segment hold (d28 batch319 SU, viewer Aurora site:5401: "routine spoken updates wait until a narrator overview or
recap finishes ... allow urgent interruptions and resume unfinished important parts. Release on playback completion
with failure cleanup. Test bursts and reload/restart for lost parts, duplicates, stale floods or stuck mute"):
python3 tools/stream/test_segmenthold.py

1. The page (segment_audio_selftest.mjs in Node, a fake DOM and WebAudio): bursts during a two-part piece wait for
   its last part; an urgent line goes between parts; an operator line held past its expiry plays, host banter drops
   (skip: expired); a release event, a failed last part and a timeout each end the hold; a clip sent twice plays once;
   a page loaded again mid-piece plays the replayed lines once each, after the last part. Skipped without node.
2. The service (serve.AudioHub): a page that connects gets the clips still queued (not started, done, expired or
   control; a timed clip only while its moment is under 2 s past); POST /audio/release sends a `release` event;
   a skip's reason is logged (expired, late, cancelled), once though two pages report it; a restarted service has
   no clips to replay (the page's own queue then fails over as errors, which end its hold).
3. The tour: a segment's clips carry {id, part, parts}; its first cut waits for a line playing now (at most
   FIRST_WAIT_MAX_S) instead of ducking it; the tour's end releases the hold. (hourly.py's resume of an interrupted
   piece: test_hourly.py.)
"""
import json, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import serve  # noqa: E402
import tour  # noqa: E402


def page():
    node = shutil.which("node")
    if not node:
        print("1. skipped (no node)")
        return
    for attempt in (1, 2):  # real timers: a loaded machine gets one more try
        r = subprocess.run([node, os.path.join(HERE, "segment_audio_selftest.mjs")], capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            break
    assert r.returncode == 0, r.stdout[-3000:] + r.stderr[-2000:]
    print("1. the page's segment hold (Node selftest): ok")


def hub():
    with tempfile.TemporaryDirectory() as d:
        log = os.path.join(d, "audio-played.jsonl")
        h = serve.AudioHub(log)
        now = time.time()
        a = h.push({"channel": "agent", "speaker": "Sol", "duration": 3, "expires_in": 20}, b"x", "audio/mpeg")
        b = h.push({"channel": "operator", "speaker": "Operator", "duration": 5, "expires_in": 60}, b"x", "audio/mpeg")
        old = h.push({"channel": "caster", "speaker": "Rook", "duration": 2, "expires_in": 1}, b"x", "audio/mpeg")
        n1 = h.push({"channel": "narrator", "at": now - 5, "duration": 4, "segment": {"id": "p", "part": 1, "parts": 2}}, b"x", "audio/mpeg")
        n2 = h.push({"channel": "narrator", "at": now + 8, "duration": 4, "segment": {"id": "p", "part": 2, "parts": 2}}, b"x", "audio/mpeg")
        h.played({"id": a["id"], "state": "start", "duration": 3})
        ids = [c["id"] for c in h.pending(now=now + 2)]
        assert ids == [b["id"], n2["id"]], ids  # a started, old expired, n1's moment past; n2 keeps its segment
        assert h.pending(now=now + 2)[1]["segment"] == {"id": "p", "part": 2, "parts": 2}
        assert h.release("p") and not h.release("")
        seq, clips = h.wait(0, 0)
        rel = [c for c in clips if c.get("release")]
        assert rel and rel[-1]["release"] == "p" and rel[-1]["channel"] == "control"
        assert all(c["id"] != rel[-1]["id"] for c in h.pending()), "a control event is never replayed"
        # a skip's reason, logged once though two pages report it
        h.played({"id": old["id"], "state": "skip", "reason": "expired"})
        h.played({"id": old["id"], "state": "skip", "reason": "expired"})
        h.played({"id": n1["id"], "state": "skip", "reason": "late"})
        rows = [json.loads(l) for l in open(log)]
        skips = [r for r in rows if r.get("state") == "skip"]
        assert [(r["id"], r["reason"]) for r in skips] == [(old["id"], "expired"), (n1["id"], "late")], skips
        # a restarted service: nothing to replay (its clips were in memory); the counters come back from the log
        h2 = serve.AudioHub(log)
        assert h2.pending() == [] and len(h2.ended) == len([r for r in rows if r.get("ended")])
    print("2. the service: queued clips replayed to a page that connects, release events, skip reasons logged once: ok")


class Svc:
    """A stand-in stream service for tour.Tour: a line playing for `busy` more seconds, then nothing."""
    def __init__(self, clock, busy):
        self.clock, self.busy_until, self.calls, self.clips = clock, clock() + busy, [], []

    def call(self, method, path, body=None, timeout=10):
        self.calls.append((method, path, body))
        if path == "/audio":
            self.clips.append(body)
            return 200, {"id": f"c{len(self.clips)}"}
        if path == "/look":
            return 200, {"until": self.clock() + 60}
        return 200, {}

    def state(self):
        last = next((b for m, p, b in reversed(self.calls) if p == "/look"), None)
        return {"look": {"id": last["id"], "aired": self.clock(), "by": "tour"}} if last else {}

    def audio_status(self):
        left = self.busy_until - self.clock()
        playing = [{"id": "op1", "channel": "operator", "ends_in": round(left, 2)}] if left > 0 else []
        playing += [{"id": c, "channel": "narrator", "started": self.clock()} for c in [f"c{len(self.clips)}"] if self.clips]
        return {"playing": playing, "queued": []}


def tour_segment():
    t = [1000.0]
    clock = lambda: t[0]
    def sleep(s):
        t[0] += max(s, 0.05)
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "out")
        os.makedirs(out)
        stops, clips = [], {}
        for k in (1, 2):
            path = os.path.join(out, f"s{k}.mp3")
            open(path, "wb").write(b"mp3")
            stops.append({"id": f"s{k}", "target": {"platform": "Spindle"}, "caption": f"stop {k}", "narration": f"Stop {k}.",
                          "seconds": 6})
            clips[f"s{k}"] = {"file": f"s{k}.mp3", "duration": 4.0}
        manifest = {"voice": "v", "clips": clips}
        rows = tour.checked(stops)
        assert all(s for _, s, _ in rows), rows
        orig = tour.clip_for
        tour.clip_for = lambda m, o, s: {"path": os.path.join(out, f"{s['id']}.mp3"), "duration": 4.0}
        try:
            svc = Svc(clock, busy=7.5)
            T = tour.Tour(svc, rows, manifest, out, os.path.join(d, "t.jsonl"), hush_file=os.path.join(d, "hush"),
                          stop_file=os.path.join(d, "stop"), clock=clock, sleep=sleep, segment="hour-7")
            T.run(rows)
        finally:
            tour.clip_for = orig
        segs = [c["segment"] for c in svc.clips]
        assert segs == [{"id": "hour-7", "part": 1, "parts": 2}, {"id": "hour-7", "part": 2, "parts": 2}], segs
        assert svc.clips[0]["at"] >= 1000.0 + 7.5, ("the first narration waits for the operator line", svc.clips[0]["at"])
        rows_log = [json.loads(l) for l in open(os.path.join(d, "t.jsonl"))]
        w = [r for r in rows_log if r["event"] == "waited"]
        assert w and w[0]["why"] == "a voice line was playing", rows_log[:3]
        assert ("POST", "/audio/release", {"segment": "hour-7"}) in svc.calls
        assert T.agent_gaps is False and T.aired_ids == ["s1", "s2"]
        # a line playing longer than FIRST_WAIT_MAX_S: the wait stops there (the narration ducks the rest)
        t[0] = 2000.0
        tour.clip_for = lambda m, o, s: {"path": os.path.join(out, f"{s['id']}.mp3"), "duration": 4.0}
        try:
            svc = Svc(clock, busy=90)
            T = tour.Tour(svc, rows[:1], manifest, out, os.path.join(d, "t2.jsonl"), hush_file=os.path.join(d, "hush"),
                          stop_file=os.path.join(d, "stop"), clock=clock, sleep=sleep, segment="hour-8")
            T.run(rows[:1])
        finally:
            tour.clip_for = orig
        assert svc.clips[0]["at"] <= 2000.0 + tour.PREROLL_S + T.lead + tour.FIRST_WAIT_MAX_S + 0.5, svc.clips[0]["at"]
    print("3. the tour: parts carry the segment, the first cut waits for a line playing (bounded), the end releases: ok")


if __name__ == "__main__":
    page()
    hub()
    tour_segment()
    print("test_segmenthold: all ok")
