#!/usr/bin/env python3
"""tools/archive/ (the video archive's index, captions, calibration, clip ranker and HLS sample data) on a made-up
shift: python3 tools/test_video_archive.py

- recordings: OBS's box-clock names (PST) become PDT; Replay_ clips are left out; the fitted offset moves t0; a gap
  before the first file and between two files; a time in a gap points at the nearest footage;
- clock: tick <-> wall time through the score rows, a pause stays flat; a chronicle row written late in a batch takes
  the time its tick gives;
- on air: one interval per ON AIR line; a replay (lines without a clock) sits between the stamped lines around it and
  takes the program over; a camera on a platform lost under it falls back; cameras from the director's jsonl;
- events: a death once (the chronicle's, marked with the director's cut), a battle with its score, a maiden flight,
  an arrival, each thousandth rocket, a replay with its Replay_ file, a viewer answer (a deleted viewer's left out);
- lines: each voiced clip's text from the caster row pushed in its second; chat: agents and viewers that passed the
  filter, not the operator, not a deleted viewer, not the relayed copy;
- captions: cue times from the recording's t0, long lines split, a window counts from its start and clamps its end;
- calibration: a known shift between logged and heard speech comes back as the offset;
- clips: the platform lost at the edge ranks first; a moment in a gap scores 0 and says so; one fight is one clip;
  in and out points move to voiced lines' edges; the HLS window carries the stats row before it and no local paths;
- the R2 uploader: content types and cache rules per file, and it refuses a master.
"""
import array
import datetime
import json
import math
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "archive"))
import archive_index as ai  # noqa: E402
import calibrate  # noqa: E402
import captions  # noqa: E402
import clips  # noqa: E402
import hls  # noqa: E402
import r2_put  # noqa: E402

PDT = ai.PACIFIC
START = datetime.datetime(2026, 10, 20, 18, 0, 0, tzinfo=PDT)
T0 = START.timestamp()


def hms(sec):
    return (START + datetime.timedelta(seconds=sec)).strftime("%H:%M:%S")


def iso(sec):
    return (START + datetime.timedelta(seconds=sec)).strftime("%Y-%m-%dT%H:%M:%S")


def jl(path, rows):
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


def make(root):
    runs, logs, rec = root / "runs", root / "logs", root / "rec"
    for p in (runs / "sx", logs, rec):
        p.mkdir(parents=True)
    d = runs / "sx"
    (d / "stream.json").write_text(json.dumps({"shift": {"start": T0, "end": T0 + 3600}}))
    (d / "start.log").write_text("18:00:00 world n: resuming\n")
    # scores every 2 minutes; ticks run at 60/s except a 4-minute pause from 20 to 24 min; rocket 1000 at ~31 min
    rows, tick = [], 1_000_000
    for k in range(31):
        sec = k * 120
        if k:
            tick += 0 if 10 < k <= 12 else 7200
        rows.append({"t": iso(sec), "score": {"tick": tick, "paused": 10 < k <= 12, "rockets": 990 + k,
                                               "research_done": ["automation"] + (["rocket-silo"] if k > 5 else []),
                                               "produced": {"automation-science-pack": 100 * k}, "planets": ["nauvis"],
                                               "platforms": [{"name": "Wren", "at": "nauvis", "hub": True}],
                                               "current_research": "health"}})
    jl(d / "scores.jsonl", rows)
    tick_at = {r["t"]: r["score"]["tick"] for r in rows}
    jl(d / "chronicle.jsonl", [
        {"type": "event", "kind": "rocket", "tick": tick_at[iso(120)], "t": T0 + 125, "surface": "nauvis"},
        {"type": "event", "kind": "research", "name": "rocket-silo", "tick": tick_at[iso(720)], "t": T0 + 719,
         "queued_by": "astra"},
        # written late: its t is 10 minutes after where its tick puts it (6 min in)
        {"type": "entry", "agent": "grok", "title": "Late note", "tick": tick_at[iso(360)], "t": T0 + 960},
        {"type": "event", "kind": "death", "agent": "opus", "planet": "nauvis", "surface": "nauvis",
         "by": "big-biter", "position": {"x": 1, "y": 2}, "tick": tick_at[iso(1800)], "t": T0 + 1800.5},
        {"type": "event", "kind": "platform_lost", "platform": "Wren", "surface": "platform-3",
         "from": "solar-system-edge", "to": "aquilo", "flown": 19, "tick": tick_at[iso(2400)], "t": T0 + 2400.0},
    ])
    jl(d / "chat.jsonl", [
        {"from": "opus", "text": "Going to the nests.", "logged_at": iso(1700), "tick": 1},
        {"from": "viewer Ann", "viewer": True, "text": "relayed copy", "logged_at": iso(1710), "tick": 1},
        {"from": "server", "text": "saved", "logged_at": iso(1720), "tick": 1},
    ])
    # voiced clips: ids are the hub's add second; start = t - played
    jl(d / "audio-played.jsonl", [
        {"t": T0 + 1, "state": "load"},
        {"t": T0 + 1806, "id": f"{int(T0 + 1800)}-1", "state": "end", "ended": True, "channel": "caster",
         "speaker": "Rook", "played": 4.0, "duration": 4.0},
        {"t": T0 + 2425, "id": f"{int(T0 + 2410)}-2", "state": "end", "ended": True, "channel": "caster",
         "speaker": "Vale", "played": 12.0, "duration": 12.0},
        {"t": T0 + 3000, "id": f"{int(T0 + 2990)}-3", "state": "end", "ended": True, "channel": "agent",
         "speaker": "Sol", "agent": "sol", "played": 5.0, "duration": 5.0},
    ])
    (d / "stream-service.log").write_text("\n".join([
        f"[director] {hms(0)} ON AIR main: astra  <- back to astra",
        f"[director] {hms(1795)} ON AIR cam2: @attack  <- incoming: 9 biters",
        f"[director] {hms(1802)} cam2:  zoom 1.1  <- death: Opus died",
        f"[director] {hms(1804)} ON AIR cam2: @attack  <- death: Opus died",
        f"[director] {hms(1830)} BATTLE (score 3.1): 14 lost near (5, 6): 12 stone wall (by behemoth biters)",
        f"[director] {hms(1850)} main:  zoom 0.99  <- loss: 14 lost near (5, 6): 12 stone wall (by behemoth biters)",
        "[replays] saved D:/pog/recordings/Replay_2026-10-20_17-31-00.mkv for Opus died",
        f"[director] {hms(1900)} threat battle skip",
        "[replays] on air: Opus died (D:/pog/recordings/Replay_2026-10-20_17-31-00.mkv, from 1000 ms of 41000 ms)",
        f"[director] {hms(1910)} ON AIR main: sol  <- back to sol",
        f"[director] {hms(1916)} threat group skip",
        "[replays] back to stream (replay over)",
        f"[director] {hms(1924)} threat group skip",
        f"[director] {hms(2000)} maiden flight: Kite · maiden flight · Nauvis to Fulgora · built by Sol",
        f"[director] {hms(2100)} ON AIR cam2: @segment  <- segment: Kite reaches Fulgora",
        f"[director] {hms(2380)} ON AIR main: @platform  <- platform danger: Wren under fire",
        f"[director] {hms(2450)} ON AIR cam2: luna  <- back to luna",
        f"[director] {hms(2600)} LAYOUT trio  <- busy",
    ]) + "\n")
    stamp = START.strftime("%Y%m%d-%H%M%S")
    jl(logs / f"director-{stamp}.jsonl", [
        {"t": T0 + 2379, "slot": "main", "cmd": {"position": {"x": 1, "y": 20}, "zoom": 0.3, "surface": "platform-3"},
         "result": {"camera": {"position": {"x": 1, "y": 20}, "zoom": 0.3, "surface": "platform-3"}}},
    ])
    jl(logs / "director-20261020-150000.jsonl", [  # the shift before's log
        {"t": T0 - 3000, "slot": "main", "cmd": {"position": {"x": 9, "y": 9}, "surface": "nauvis"}}])
    jl(logs / f"caster-{stamp}.jsonl", [
        {"type": "caster", "who": "pbp", "event": "death", "pushed": True, "t": T0 + 1800.3, "seconds": 4.0,
         "line": "Opus is down on Nauvis."},
        {"type": "caster", "who": "color", "event": "loss", "pushed": True, "t": T0 + 2410.2, "seconds": 12.0,
         "line": "Wren is gone. Everything aboard went with it, and the platform was never even built, a long line "
                 "that needs more than one cue <here>."},
        {"type": "caster", "who": "pbp", "event": "space", "pushed": False, "t": T0 + 2990.1, "seconds": 5.0,
         "line": "not pushed"},
    ])
    jl(logs / f"viewers-{stamp}.jsonl", [
        {"t": T0 + 1805, "id": "site:1", "name": "Ann", "text": "oh no opus", "pass": True, "source": "site"},
        {"t": T0 + 1806, "id": "site:2", "name": "Bob", "text": "rude", "pass": False},
        {"t": T0 + 1807, "id": "site:3", "name": "Gone", "text": "deleted later", "pass": True},
        {"t": T0 + 1808, "id": "site:4", "name": "NickWinter", "text": "operator line", "pass": True},
        {"t": T0 + 1809, "id": "site:1", "name": "Ann", "text": "oh no opus", "pass": True},
    ])
    jl(logs / f"viewer-answers-{stamp}.jsonl", [
        {"t": T0 + 1500, "viewer": "Ann", "text": "is opus ok?", "reply": {"question": "Is Opus okay?",
                                                                          "answer": "Opus is fighting nests."}},
        {"t": T0 + 1600, "viewer": "Gone", "text": "deleted later", "reply": {"answer": "x"}},
        {"t": T0 + 1700, "viewer": "Cy", "text": "do a thing", "reply": {"skip": "a task"}},
    ])
    # recordings: names in PST; the first starts 18:00:30 PDT and runs 1700 s; the second 18:32:00 PDT to the end
    for name in ("2026-10-20_17-00-30.mkv", "2026-10-20_17-32-00.mkv", "Replay_2026-10-20_17-31-00.mkv",
                 "2026-10-20_13-00-00.mkv"):
        (rec / name).write_bytes(b"")
    return runs, logs, rec


def probe(path):
    return {"2026-10-20_17-00-30.mkv": 1700.0, "2026-10-20_17-32-00.mkv": 1680.0,
            "2026-10-20_13-00-00.mkv": 600.0}.get(Path(path).name)


class Hidden:
    def hides(self, name, text):
        return name == "Gone"


def tone(master, at, seconds, lines_heard):
    """A made-up recording's audio: quiet noise with a loud tone wherever `lines_heard` (file seconds) say."""
    rate = 8000
    n = int(seconds * rate)
    out = array.array("h", [0]) * n
    for i in range(n):
        out[i] = (i * 7919) % 200 - 100
    for s, d in lines_heard:
        a, b = int((s - at) * rate), int((s + d - at) * rate)
        for i in range(max(0, a), min(n, b)):
            out[i] = int(8000 * math.sin(i * 0.3))
    return out


def main():
    with tempfile.TemporaryDirectory() as tmp:
        runs, logs, rec = make(Path(tmp))
        cal = {"2026-10-20_17-00-30.mkv": {"offset": 8.5}}
        idx = ai.build("sx", runs, logs, [rec], cal, probe=probe, hidden=Hidden())
        s = idx["shift"]
        assert s["start"] == T0 and s["number"] == 1, s
        # recordings and gaps
        names = [m["name"] for m in idx["media"]]
        assert names == ["2026-10-20_17-00-30.mkv", "2026-10-20_17-32-00.mkv"], names
        m1, m2 = idx["media"]
        assert m1["named_t0"] == T0 + 30 and m1["t0"] == T0 + 38.5 and m1["calibrated"], m1
        assert m2["t0"] == T0 + 1920 and not m2["calibrated"], m2
        assert idx["gaps"][0] == [T0, T0 + 38.5] and idx["gaps"][1] == [T0 + 1738.5, T0 + 1920.0], idx["gaps"]
        assert ai.at(idx, T0 + 100) == {"file": m1["file"], "s": 61.5}
        assert ai.at(idx, T0 + 1900)["nearest"] == T0 + 1920.0, ai.at(idx, T0 + 1900)
        # clock: linear, flat in the pause
        assert ai.tick_to_t(idx["clock"], 1_000_000 + 3600) == T0 + 60
        assert ai.t_to_tick(idx["clock"], T0 + 1380) == ai.t_to_tick(idx["clock"], T0 + 1440)
        note = next(e for e in idx["events"] if e["kind"] == "note")
        assert note["t"] == T0 + 360, note  # late batch row: its tick's time
        # on air
        on = idx["onair"]
        assert all(a[1] <= b[0] + 0.01 for a, b in zip(on, on[1:])), on
        rep = next(r for r in on if r[3] == "@replay")
        assert rep[0] == T0 + 1905 and rep[1] == T0 + 1920, rep  # middle of (1900, 1910) to middle of (1916, 1924)
        assert any(r[3] == "sol" and r[0] == T0 + 1920 for r in on), on  # sol resumes after the replay
        fb = next(r for r in on if r[3] == "@fallback")
        assert fb[0] == T0 + 2400 and fb[1] == T0 + 2450, fb
        plat = next(r for r in on if r[3] == "@platform")
        assert plat[1] == T0 + 2400 and plat[5][0] == "platform-3", plat
        assert idx["layout"] == [[T0 + 2600, "trio"]], idx["layout"]
        # events
        kinds = {}
        for e in idx["events"]:
            kinds.setdefault(e["kind"], []).append(e)
        assert len(kinds["death"]) == 1 and kinds["death"][0]["cut_t"] == T0 + 1802, kinds["death"]
        assert kinds["death"][0]["title"] == "Opus dies on Nauvis (big biter)", kinds["death"]
        assert kinds["battle"][0]["score"] == 3.1 and kinds["loss"][0]["lost"] == 14
        assert kinds["maiden"][0]["agents"] == ["sol"] and kinds["arrival"][0]["planet"] == "Fulgora"
        assert [e["title"] for e in kinds["rocket"]] == ["First rocket of the shift", "Rocket 1,000"], kinds["rocket"]
        assert kinds["replay"][0]["replay_file"] == str(rec / "Replay_2026-10-20_17-31-00.mkv"), kinds["replay"]
        assert [e["viewer"] for e in kinds["viewer_answer"]] == ["Ann"], kinds["viewer_answer"]
        assert kinds["death"][0]["on_air"] == "@attack" and kinds["death"][0]["tick"] is not None
        assert {e["id"] for e in idx["events"] if e["id"] in idx["milestones"]} >= {"research-001", "maiden-001"}
        # lines and chat
        lines = idx["lines"]
        assert [(round(r["t"] - T0, 1), r["who"], r["text"][:12]) for r in lines] == [
            (1802.0, "Rook", "Opus is down"), (2413.0, "Vale", "Wren is gone"), (2995.0, "Sol", "")], lines
        assert lines[0]["event"] == "death"
        chat = [(c["kind"], c["who"]) for c in idx["chat"]]
        assert chat == [("agent", "opus"), ("viewer", "Ann")], chat
        assert idx["stats"][-1][idx["stats_cols"].index("deaths")] == 1, idx["stats"][-1]
        # captions: from the first recording's t0, long lines split, escaped, a window clamps
        v = captions.vtt(lines, m1["t0"])
        assert v.startswith("WEBVTT\n") and "00:29:23.500 --> 00:29:27.500\n<v Rook>Opus is down on Nauvis." in v, v
        assert v.count("<v Vale>") == 2 and "&lt;here&gt;" in v, v
        w = captions.vtt(lines, m1["t0"], T0 + 2415, T0 + 2420)
        assert "00:00:00.000 --> " in w and "Rook" not in w and all(
            float(x.split(" --> ")[1][6:]) <= 5.0 for x in w.splitlines() if " --> " in x), w
        # calibration: heard 8.0 s before the log puts it, so the file began 8.0 s after its name
        speech = [(i * 37.0, 6.0) for i in range(60)]  # log epoch = file second when the offset is 0
        heard = [(s - 8.0, d) for s, d in speech]
        fit = calibrate.calibrate("x.mkv", speech, 0.0, 2000.0, n_windows=3, minutes=2,
                                  sampler=lambda m, at, sec: tone(m, at, sec, heard))
        assert abs(fit["offset"] - 8.0) <= 0.15 and fit["used"] == 3 and abs(fit["drift_s_per_h"] or 0) < 0.5, fit
        quiet = calibrate.calibrate("x.mkv", [], 0.0, 2000.0, n_windows=2, minutes=1,
                                    sampler=lambda m, at, sec: tone(m, at, sec, []))
        assert quiet["offset"] is None and not any(w["ok"] for w in quiet["windows"]), quiet
        # clips
        cands = clips.candidates(idx)
        top = cands[0]
        assert top["kind"] == "platform_lost" and "at the solar system's edge" in top["why"], cands[:2]
        assert top["t_in"] == T0 + 2385 and top["t_out"] == T0 + 2430 and top["on_air_share"] == 1.0, top
        death = next(c for c in cands if c["kind"] == "death")
        assert death["score"] == 0 and any("no footage" in w for w in death["why"]), death
        assert "battle-001" in death.get("also", []) or any("battle-001" in c.get("also", []) for c in cands), cands
        assert death["t_in"] == T0 + 1788.5 and "file" not in death, death
        assert all(abs(a["t_event"] - b["t_event"]) > clips.NMS_S for a in cands for b in cands if a is not b), cands
        assert "file" in top and top["s_in"] == round(T0 + 2385 - m2["t0"], 2), top
        md = clips.review(idx, cands, 10)
        assert md.count("\n| ") >= 3 and "platform_lost" in md, md
        cmd = clips.cut_cmd(top, "out.mp4")
        assert cmd[:3] == ["nice", "-n", "19"] and "libx264" in cmd and "+faststart" in cmd, cmd
        # the HLS window and playlist
        win = hls.window(idx, T0 + 1830, T0 + 2430)
        assert win["stats"][0][0] < T0 + 1830 <= win["stats"][1][0], win["stats"][:2]
        assert all(T0 + 1830 <= e["t"] <= T0 + 2430 and e["kind"] != "note" for e in win["events"]), win["events"]
        assert "replay_name" in json.dumps(win) and str(rec) not in json.dumps(win), win["events"]  # published: no paths
        assert hls.wall(idx, "18:30") == T0 + 1800 and hls.wall(idx, "17:30") == T0 + 84600
        pl = hls.master([1080, 540])
        assert pl.splitlines()[0] == "#EXTM3U" and "1080/index.m3u8" in pl and "RESOLUTION=960x540" in pl, pl
        # the uploader: content types and cache rules by file; a master never goes up
        up = Path(tmp) / "up"
        (up / "1080").mkdir(parents=True)
        for name in ("master.m3u8", "1080/seg0000.m4s", "1080/init.mp4", "captions.vtt", "notes.md"):
            (up / name).write_text("x")
        got = {k: (c, cc) for _, k, c, cc in r2_put.plan(up, "/shift48/sample-1820/")}
        assert set(got) == {"shift48/sample-1820/master.m3u8", "shift48/sample-1820/1080/seg0000.m4s",
                            "shift48/sample-1820/1080/init.mp4", "shift48/sample-1820/captions.vtt"}, got
        assert got["shift48/sample-1820/1080/seg0000.m4s"] == ("video/iso.segment", r2_put.LONG), got
        assert got["shift48/sample-1820/master.m3u8"][1] == r2_put.SHORT, got
        (up / "2026-10-20_16-01-48.mkv").write_text("x")
        try:
            r2_put.plan(up, "x")
            raise AssertionError("a master was planned for upload")
        except SystemExit as e:
            assert "web renditions only" in str(e), e
    print("video archive: ok (recordings and gaps, clock, on air with replays and a lost platform, events, lines, "
          "chat, captions, calibration, clip ranking, HLS window, uploader plan)")


if __name__ == "__main__":
    main()
