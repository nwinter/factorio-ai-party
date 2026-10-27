#!/usr/bin/env python3
"""tools/stream/vx_review.py on a small fixture run (d26 batch237 VX): python3 tools/stream/test_vx_review.py

A run folder and a logs folder written here, every time a fixed epoch (no clock, no live data), and checks:
- the inputs: the director log stream-service.log names, the caster log stamped seconds after it, hourly.log's log,
  the run's tour-hourly log;
- missed action: a build on air at once, a vehicle outing never on air, a loss the director skipped (missed) and one it
  took, a departure it chose not to show (by design) and one shown as an inset, a platform made;
- idle airtime: an agent idle on air, a view shown again within REPEAT_S;
- narration: cue to line, a chronicle event to the line announcing it (batch255: its cue names it; mentions apart), a chat to its voiced line, the audio wait, a clip
  cut short and one skipped, a repeated line, a platform called new that the run did not make;
- data clarity: a push failure, a gap, a tick that stopped moving, chart surfaces without cells, base-map frames, the
  Updates rows open and due;
- cost: slow game reads and an error; the module reads no game and opens no connection;
- --from/--to narrows the span; the markdown and JSON land in --out.
"""
import datetime, json, re, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vx_review as vx  # noqa: E402

T0 = datetime.datetime(2026, 10, 26, 10, 0, 0, tzinfo=vx.PACIFIC).timestamp()  # 10:00:00 Pacific


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def hms(t):
    return datetime.datetime.fromtimestamp(t, vx.PACIFIC).strftime("%H:%M:%S")


def jl(path, rows):
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


def journal(path, items):
    """items: (t, action, args, result): a request at t and its reply 1 s later."""
    rows = []
    for i, (t, action, args, result) in enumerate(items):
        rows.append({"event": "request", "at": iso(t), "request": {"id": f"r{i}", "action": action, "args": args}})
        rows.append({"event": "response", "at": iso(t + 1), "response": {"id": f"r{i}", "ok": True, "result": result}})
    path.parent.mkdir(parents=True, exist_ok=True)
    jl(path, rows)


def slot(t, slot_, reason, follow=None, agents=()):
    return {"t": T0 + t, "slot": slot_, "reason": reason, "target": {"agents": list(agents)}, "cmd": {"follow": follow} if follow else {}}


def prog(t, reason):
    return {"t": T0 + t, "slot": "program", "reason": reason}


def fixture(d):
    run, logs = d / "runs" / "shift99", d / "logs"
    run.mkdir(parents=True)
    logs.mkdir()
    stamp = datetime.datetime.fromtimestamp(T0, vx.PACIFIC).strftime("%Y%m%d-%H%M%S")
    cstamp = datetime.datetime.fromtimestamp(T0 + 12, vx.PACIFIC).strftime("%Y%m%d-%H%M%S")
    director = [
        slot(0, "main", "standby: alice", follow="alice", agents=["alice"]), prog(0, "cut to main: start"),
        slot(300, "main", "standby: bob", follow="bob", agents=["bob"]),
        {"t": T0 + 500, "slot": "program", "reason": "threat battle skip", "threat": {"threat": "battle", "key": "loss:nauvis:#1", "decision": "skip"}},
        {"t": T0 + 520, "slot": "program", "reason": "threat loss inset take", "threat": {"threat": "loss inset", "key": "loss:nauvis:#2", "decision": "take"}},
        {"t": T0 + 550, "slot": "program", "reason": "departure routine (none)", "departure": {"name": "Lark", "label": "Lark · leaving Nauvis", "news": False, "decision": "none"}},
        {"t": T0 + 560, "slot": "program", "reason": "departure routine (inset)", "departure": {"name": "Petrel", "label": "Petrel · leaving Vulcanus", "news": False, "decision": "inset"}},
        slot(565, "cam3", "inset departure: Petrel · leaving Vulcanus for Nauvis"),
        slot(600, "cam2", "base map"), prog(600, "cut to cam2: quiet"),
        prog(700, "cut to main: back to bob"),
        prog(800, "cut to cam2: quiet again"),
        prog(900, "cut to main: back to bob"),
        slot(1800, "main", "standby: bob", follow="bob", agents=["bob"]),
    ]
    jl(logs / f"director-{stamp}.jsonl", director)
    jl(logs / f"director-20200101-000000.jsonl", [slot(0, "main", "another run's")])  # not named: not read
    caster = [
        {"type": "caster", "event": "space", "exchange": T0 + 1000, "t": T0 + 1010, "line": "Oldship is new. A fresh platform appeared.",
         "facts": {"text": "New space platform: Oldship"}},
        # (batch255) an arrival announced 20 s and 25 s on (its second voice logs no facts), then a later mention
        {"type": "caster", "event": "arrival", "exchange": T0 + 1030, "t": T0 + 1040, "line": "Newship pulls in at Nauvis.",
         "facts": {"text": "Newship arrives at Nauvis", "arrival": {"platform": "Newship", "planet": "Nauvis"}}},
        {"type": "caster", "event": "arrival", "exchange": T0 + 1030, "t": T0 + 1045, "line": "Newship, first trip home."},
        {"type": "caster", "event": "camera", "exchange": T0 + 1090, "t": T0 + 1100, "line": "Newship is out on its first job for Bob."},
        {"type": "caster", "event": "info", "exchange": T0 + 1190, "t": T0 + 1200, "line": "Bob builds the furnace row now."},
        {"type": "caster", "event": "info", "exchange": T0 + 1480, "t": T0 + 1500, "line": "Bob builds the furnace row now!"},
        {"type": "chat_decision", "agent": "alice", "text": "Heading out in the tank.", "voiced": True, "t": T0 + 1300},
        {"type": "agent", "agent": "alice", "label": "aloud", "line": "Heading out in the tank.", "t": T0 + 1306},
        {"type": "cost", "usd_per_hour": 2.0, "t": T0 + 1400},
    ]
    jl(logs / f"caster-{cstamp}.jsonl", caster)
    jl(logs / f"hourly-{stamp}.jsonl", [{"t": T0 + 1600, "event": "written", "id": "hourly-shift99-1"}])
    jl(logs / f"tour-hourly-shift99-{stamp}.jsonl", [{"t": T0 + 1650, "event": "aired", "id": "stop-1", "caption": "x"}])
    (run / "hourly.log").write_text(f"10:00:00 [hourly] shift99: one piece an hour, aired; log /x/tools/stream/logs/hourly-{stamp}.jsonl\n")
    (run / "stream-service.log").write_text("\n".join([
        f"[stream] live:n on http://127.0.0.1:8788/  run=runs/shift99/stream.json  director log tools/stream/logs/director-{stamp}.jsonl",
        f"[chart] {hms(T0 + 300)} v3, 1 reads, 24 surfaces (22 with cells), 0 list blocks to read",
        f"[slow-rcon] 0.50s 100 B: /silent-command local function census(part, ore) x",
        f"[director] {hms(T0 + 400)} main: alice",
        f"[slow-rcon] 0.70s 100 B: /silent-command local function census(part, ore) x",
        "Traceback (most recent call last):",
        "ConnectionResetError: [Errno 54] Connection reset by peer",
        f"[director] {hms(T0 + 2000)} after the span",
        "[slow-rcon] 9.00s 100 B: /silent-command after the span",
    ]) + "\n")
    journal(run / "alice" / "journal.jsonl", [
        (T0 + 299, "status", {}, {"clock": "+5m0s since your last request, character idle 5m0s of it"}),
        (T0 + 400, "vehicle", {"go_to": {"x": 1, "y": 2}}, {"ok": True}),
    ])
    journal(run / "bob" / "journal.jsonl", [(T0 + 310, "build", {"name": "stone-furnace"}, {"built": 1})])
    jl(run / "chronicle.jsonl", [
        {"kind": "platform_created", "platform": "Newship", "by": "bob", "line": "platform Newship made at nauvis", "t": T0 + 900},
        {"kind": "platform_arrived", "platform": "Newship", "line": "platform Newship stopped at nauvis", "t": T0 + 1020},
        {"kind": "rocket", "surface": "nauvis", "t": T0 + 950}, {"kind": "rocket", "surface": "nauvis", "t": T0 + 960},
    ])
    jl(run / "audio-played.jsonl", [
        {"t": T0 + 1312, "id": f"{int(T0 + 1306)}-1", "ended": True, "state": "end", "channel": "agent", "speaker": "Alice", "played": 5.0, "duration": 5.0, "early": False},
        {"t": T0 + 1400, "id": f"{int(T0 + 1390)}-2", "ended": True, "state": "skip", "channel": "caster", "played": 0.0},
        {"t": T0 + 1500, "id": f"{int(T0 + 1490)}-3", "ended": True, "state": "cut", "channel": "caster", "speaker": "pbp", "played": 2.0, "duration": 6.0,
         "early": True, "reason": "cut"},
    ])
    (run / "push-live.log").write_text("\n".join([
        f"[push] {hms(T0 + 30)} start: http://x/state.json -> https://y",
        f"[push] {hms(T0 + 60)} ok: 6 pushed, 0 failed in the last 60 s, 100 bytes each, tick 5, 2 agents, terrain frames 4, chart v7",
        f"[push] {hms(T0 + 120)} ok: 6 pushed, 0 failed in the last 60 s, 100 bytes each, tick 5, 2 agents, terrain frames 4, chart v7",
        f"[push] {hms(T0 + 180)} ok: 6 pushed, 0 failed in the last 60 s, 100 bytes each, tick 5, 2 agents, terrain frames 0, chart v7",
        f"[push] {hms(T0 + 600)} ok: 6 pushed, 0 failed in the last 60 s, 100 bytes each, tick 900, 2 agents, terrain frames 4, chart v7",
        f"[push] {hms(T0 + 660)} failed (1): TimeoutError: The read operation timed out",
        f"[push] {hms(T0 + 1200)} ok: 6 pushed, 0 failed in the last 60 s, 100 bytes each, tick 950, 2 agents, terrain frames 4, chart v8",
    ]) + "\n")
    (run / "mapframes.log").write_text("\n".join([
        f"[mapframes] {hms(T0 + 100)} saved: stream cam2 box [1, 2, 3, 4] F 0.5 (10 KB)",
        f"[mapframes] {hms(T0 + 200)} skipped: no clear match",
        f"[mapframes] {hms(T0 + 250)} error: URLError: refused"]) + "\n")
    up = d / "operator-updates.json"
    up.write_text(json.dumps({"updates": [
        {"id": "a", "title": "A", "status": "planned", "dates": {"planned": "2026-10-25 10:00"}},
        {"id": "b", "title": "B", "status": "in progress", "work": "batch1", "dates": {"in progress": "2026-10-26 09:00"},
         "next_review": "2026-10-27 09:00", "owner": "operator triage", "priority": "normal"},
        {"id": "c", "title": "C", "status": "live", "work": "batch2", "dates": {"live": "2026-10-26 09:30"}}], "notices": []}))
    return run, logs, up


def main():
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        run, logs, up = fixture(d)
        r = vx.review(run, logs, updates_path=up)
        assert r["inputs"]["director"] == [p.name for p in sorted(logs.glob("director-2026*.jsonl"))], r["inputs"]
        assert len(r["inputs"]["caster"]) == 1 and len(r["inputs"]["hourly"]) == 1 and len(r["inputs"]["tour_hourly"]) == 1, r["inputs"]
        assert r["from"] == "10:00:00" and r["to"] == "10:30:00" and r["minutes"] == 30.0, r
        ma = r["missed_action"]
        assert ma["new build"] == {"n": 1, "at_once": 1, "late": 0, "missed": 0, "missed_examples": [], "late_examples": [], "median_delay_s": 0.0}, ma
        assert ma["vehicle outing"]["missed"] == 1 and ma["vehicle outing"]["missed_examples"] == ["10:06:40 alice: vehicle"], ma
        assert ma["loss"]["n"] == 2 and ma["loss"]["missed"] == 1 and ma["loss"]["at_once"] == 1, ma["loss"]
        assert ma["platform departure (routine)"]["not_shown_by_design"] == 1 and ma["platform departure (routine)"]["at_once"] == 1, ma
        assert ma["platform departure (routine)"]["missed"] == 0  # the inset counts as on air
        assert ma["platform made"]["at_once"] == 1, ma["platform made"]  # bob on air when Newship was made
        rk = dict(r["rockets"])
        assert rk.pop("on_air")["shots"] == 0 and rk == {"launches": 2, "by_surface": {"nauvis": 2}}, r["rockets"]
        ia = r["idle_airtime"]
        assert ia["idle_min"] == 5.0 and ia["idle_loop_by_agent_min"] == {"alice": 5.0}, ia
        assert ia["repeat_min"] > 0 and ia["repeats"][0].startswith("@base map 'base map' again 1x"), ia["repeats"]
        assert ia["on_air_min"]["bob"] > ia["on_air_min"]["alice"] == 5.0, ia["on_air_min"]
        n = r["narration"]
        assert n["cue_to_line_median_s"] == 10.0 and n["event_to_line_n"] == 2 and n["event_to_line_median_s"] == 22.5, n
        assert n["mention_n"] == 1 and n["mention_median_s"] == 80.0, n  # (batch255) the camera line: a mention, not the lag
        assert n["chat_to_voice_median_s"] == 6.0 and n["audio_wait_by_channel_median_s"] == {"agent": 1.0, "caster": 8.0}, n
        assert n["audio_wait_median_s"] == 4.5 and n["audio_wait_p90_s"] == 8.0, n
        assert n["clips_cut_short"] == 1 and n["clips_skipped"] == 1, n
        assert n["repeated_lines"] == 1 and "(first 10:20:00)" in n["repeated_examples"][0], n["repeated_examples"]
        assert n["called_new_wrongly_n"] == 1 and "the run made no platform Oldship: newship made" in n["called_new_wrongly"][0], n
        assert n["hourly_pieces"] == 1 and n["tour_stops_aired"] == 1, n
        dc = r["data_clarity"]
        assert dc["push"]["failed"] == 1 and dc["push"]["gaps_n"] == 2 and len(dc["push"]["tick_stuck"]) == 1, dc["push"]
        assert dc["push"]["gaps"][1] == "10:11:00-10:20:00 (9.0 min with no push line)", dc["push"]["gaps"]
        assert dc["push"]["tick_stuck"][0] == "10:03:00: the pushed state's tick 5 unchanged for 3 pushes", dc["push"]
        assert dc["push"]["chart_stale"] == ["10:01:00-10:20:00: chart v7 for 19 min"] and dc["push"]["terrain_empty_pushes"] == 1, dc["push"]
        assert dc["chart_empty_layers"] == ["10:05:00 chart: 2 of 24 surfaces without cells"], dc
        assert dc["base_map_frames"] == {"saved": 1, "skipped": 1, "errors": 1}, dc
        assert {k: dc["updates_page"][k] for k in ("open", "due_for_review", "no_owner", "no_priority")} == \
            {"open": 2, "due_for_review": 1, "no_owner": 1, "no_priority": 1}, dc["updates_page"]
        c = r["cost"]
        assert c["slow_game_reads"] == 2 and c["slow_game_read_s"] == 1.2 and c["service_errors"] == 1, c
        assert c["caster_usd_per_hour_median"] == 2.0 and c["game_reads_by_this_review"] == 0, c
        areas = [f["area"] for f in r["findings"]]
        assert r["findings"][0]["what"] == "site push: 1 failures, 2 gaps over 3 min, 1 stretches of a frozen tick" and r["findings"][0]["minutes"] == 7.0, r["findings"][0]
        assert areas[1] == "idle airtime" and "narration" in areas and "missed action" in areas, areas
        assert "vehicle outing: 1 of 1 never on air, 0 late" == next(x["what"] for x in r["findings"] if x["what"].startswith("vehicle")), r["findings"]
        assert all(r["findings"][i]["minutes"] >= r["findings"][i + 1]["minutes"] for i in range(len(r["findings"]) - 1))
        # a span: 10:00-10:08 leaves out what came after
        s = vx.review(run, logs, "10:00", "10:08", updates_path=up)
        assert s["to"] == "10:08:00" and "platform made" not in s["missed_action"] and s["narration"]["lines"] == 0, s
        assert s["cost"]["slow_game_reads"] == 2  # both lines before 10:08 (one carries the time of the line before it)
        # the command: markdown and JSON into --out
        out = d / "out"
        assert vx.main([str(run), "--logs", str(logs), "--updates", str(up), "--out", str(out)]) == 0
        md = (out / "vx-review.md").read_text()
        assert md.startswith("# Viewer-experience review: shift99 10:00:00-10:30:00 (30.0 min)") and "## 5. Cost" in md, md[:300]
        assert json.loads((out / "vx-review.json").read_text())["run"] == "shift99"
        assert not (run / "vx-review.md").exists()
    # logs only: no game read, no connection
    src = (HERE / "vx_review.py").read_text()
    imports = " ".join(re.findall(r"^\s*(?:import|from) ([\w., ]+)", src, re.M))
    for bad in ("socket", "urllib", "pog", "requests", "http", "subprocess", "idle_nudge", "live"):
        assert not re.search(r"\b" + bad + r"\b", imports), (bad, imports)
    assert "Rcon" not in src and re.search(r"^import airtime", src, re.M)
    print("vx review: ok (missed action, idle airtime, narration, data clarity and cost from a fixture run's logs; a span; logs only)")


if __name__ == "__main__":
    main()
