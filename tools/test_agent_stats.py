#!/usr/bin/env python3
"""tools/agent_stats.py: deaths from the journals' deaths counter (the game's), the director's lines for their time only,
and infinite research levels apart from finished technologies (d17 study P3: 9/3/2 deaths against 7/3/2 counted)."""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agent_stats  # noqa: E402


def journal(rows):
    out = []
    for i, (at, result) in enumerate(rows):
        out.append({"at": at, "event": "request", "request": {"id": f"r{i}", "action": "status", "args": {}}})
        out.append({"at": at, "event": "response", "response": {"id": f"r{i}", "ok": True, "tick": result.pop("_tick"), "result": result}})
    return "".join(json.dumps(x) + "\n" for x in out)


def main():
    with tempfile.TemporaryDirectory() as d:
        run = Path(d) / "s1"
        for k in ("opus", "haiku", "sol"):
            (run / k).mkdir(parents=True)
        (run / "team.txt").write_text("opus|Opus\nhaiku|Haiku\nsol|Sol\n")
        (run / "scores.jsonl").write_text(
            json.dumps({"t": "2026-10-13T10:00:00", "score": {"tick": 36000, "research_done": ["automation"],
                        "infinite": {"health": 1, "mining-productivity-3": 3}}}) + "\n" +
            json.dumps({"t": "2026-10-13T11:00:00", "score": {"tick": 252000, "research_done": ["automation", "logistics"],
                        "infinite": {"health": 2, "mining-productivity-3": 5, "railgun-damage-1": 1}}}) + "\n")
        # opus: the counter rises 67 -> 68 -> 70 (two deaths between two records); the director saw one at 10:10:00
        # (tick 72000), the other not. Another agent's record (sol's deaths 9) in opus's reply is not opus's.
        (run / "opus" / "journal.jsonl").write_text(journal([
            ("2026-10-13T10:05:00Z", {"_tick": 54000, "player": {"name": "opus", "deaths": 67, "tick": 54000}}),
            ("2026-10-13T10:10:30Z", {"_tick": 73800, "player": {"name": "opus", "deaths": 68, "tick": 73800},
                                      "players": [{"name": "sol", "deaths": 9}]}),
            ("2026-10-13T10:40:00Z", {"_tick": 180000, "player": {"name": "opus", "deaths": 70, "tick": 180000}}),
        ]))
        # haiku: the counter rises once, no director line (the study's missed Haiku death)
        (run / "haiku" / "journal.jsonl").write_text(journal([
            ("2026-10-13T10:05:00Z", {"_tick": 54000, "status": {"name": "haiku", "deaths": 0}}),
            ("2026-10-13T10:45:00Z", {"_tick": 198000, "status": {"name": "haiku", "deaths": 1}}),
        ]))
        # sol: no counter in its journal: the director's lines count
        (run / "sol" / "journal.jsonl").write_text(journal([("2026-10-13T10:05:00Z", {"_tick": 54000, "clock": "c"})]))
        (run / "stream-service.log").write_text(
            "[director] 10:10:00 ON AIR cam2: @attack  <- death: Opus died\n"
            "[director] 10:10:02 cam2:  zoom 1.1  <- death: Opus died\n"
            "[director] 10:20:00 ON AIR main: @attack  <- death: Sol died\n")
        r = agent_stats.compute(run)
        o, h, s = r["agents"]["opus"], r["agents"]["haiku"], r["agents"]["sol"]
        assert (o["deaths"], o["deaths_from"], o["deaths_director"]) == (3, "counter", 1), o
        assert o["death_ticks"] == [72000, 180000, 180000], o["death_ticks"]
        assert (h["deaths"], h["deaths_from"], h["deaths_director"], h["death_ticks"]) == (1, "counter", 0, [198000]), h
        assert (s["deaths"], s["deaths_from"], s["death_ticks"]) == (1, "director", [108000]), s
        assert "death_counter" not in o and "counter_seen" not in o
        # infinite levels apart: health 1, mining-productivity-3 2, railgun-damage-1 1; logistics the finished one
        assert r["infinite_levels"] == {"health": 1, "mining-productivity-3": 2, "railgun-damage-1": 1}, r["infinite_levels"]
        assert agent_stats.research_done(run) == {"logistics"}
        # a counter that drops (a new character record) starts again; it never counts down
        assert agent_stats.counter_steps([(1, 5), (2, 6), (3, 0), (4, 1)]) == [[1, 2, 1], [3, 4, 1]]
    print("agent_stats: ok")


if __name__ == "__main__":
    main()
