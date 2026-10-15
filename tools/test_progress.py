#!/usr/bin/env python3
"""fh progress (tools/progress.py) on a made-up run: python3 tools/test_progress.py

Three shifts chained by resumed-from (s3 began from an earlier save than s2 ended on): own changes per shift, SPM from
the labs' use, packs made, plates and circuits a minute, rockets, platforms built and lost, deaths and hand moves from
agent-stats.json (journal-counted before the game's count), machines and the machine share from efficiency.jsonl,
tokens; the short, full and JSON forms; no local paths in the output."""
import io, json, os, sys, tempfile
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import progress as P  # noqa: E402

PACKS = ("automation-science-pack", "logistic-science-pack", "agricultural-science-pack")


def score(t, tick, rockets, done, made, used, plates, circuits, platforms):
    return {"t": t, "world": "n", "score": {
        "tick": tick, "rockets": rockets, "research_done": done, "current_research": "planet-discovery-aquilo",
        "produced": dict({k: made.get(k, 0) for k in PACKS}, **{"iron-plate": plates, "electronic-circuit": circuits}),
        "consumed": {k: used.get(k, 0) for k in PACKS},
        "platforms": [{"name": n, "at": at, "hub": True} for n, at in platforms], "planets": ["nauvis", "vulcanus"]}}


def write(root, name, parent, rows, stats=None, eff=None, tokens=None):
    d = os.path.join(root, name)
    os.makedirs(d)
    if parent:
        open(os.path.join(d, "resumed-from"), "w").write(parent + "\n")
    open(os.path.join(d, "scores.jsonl"), "w").write("".join(json.dumps(r) + "\n" for r in rows))
    if stats:
        json.dump({"version": 7, "run": name, "agents": stats[0], "machines_team": stats[1]}, open(os.path.join(d, "agent-stats.json"), "w"))
    if eff:
        open(os.path.join(d, "efficiency.jsonl"), "w").write("".join(json.dumps({"t": 1, "tick": 1, "team": e, "agents": []}) + "\n" for e in eff))
    if tokens:
        json.dump({"version": 1, "run": name, "final": tokens[1], "agents": tokens[0],
                   "sources": {"/Users/someone/.codex/sessions/x.jsonl": [1, 2]}}, open(os.path.join(d, "tokens.json"), "w"))


def run(argv):
    buf = io.StringIO()
    with redirect_stdout(buf):
        assert P.main(argv) == 0
    return buf.getvalue()


def main():
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "runs")
        os.makedirs(root)
        # s1: 60 game minutes; 2 technologies; the labs used 600 red, 600 green (10 units a minute); no lab counts at first
        write(root, "s1", None, [
            score("2026-10-12T10:00:00", 0, 0, [], {}, {}, 0, 0, []),
            score("2026-10-12T10:30:00", 108000, 1, ["automation"], {"automation-science-pack": 400}, {"automation-science-pack": 100, "logistic-science-pack": 100}, 30000, 3000, []),
            score("2026-10-12T11:00:00", 216000, 3, ["automation", "logistics"], {"automation-science-pack": 900, "logistic-science-pack": 300},
                  {"automation-science-pack": 700, "logistic-science-pack": 700}, 60000, 6000, [("Starling", "nauvis")])],
              stats=({"astra": {"deaths": 2, "haul_items": 500, "haul_from": "journal"}, "sol": {"deaths": 1, "haul_items": 250, "haul_from": "journal"}}, None),
              tokens=({"astra": {"total": 2_000_000_000, "output": 1_000_000, "calls": 300}, "sol": {"total": 500_000_000, "output": 500_000, "calls": 200}}, True))
        # s2: 120 game minutes, a rocket a 10, Starling lost, Sunward built; the game's hauling count
        write(root, "s2", "s1", [
            score("2026-10-12T11:05:00", 216000, 3, ["automation", "logistics"], {"automation-science-pack": 900, "logistic-science-pack": 300},
                  {"automation-science-pack": 700, "logistic-science-pack": 700}, 60000, 6000, [("Starling", "nauvis")]),
            score("2026-10-12T13:05:00", 648000, 15, ["automation", "logistics", "electronics"], {"automation-science-pack": 3300, "logistic-science-pack": 2700, "agricultural-science-pack": 9000},
                  {"automation-science-pack": 1900, "logistic-science-pack": 1900, "agricultural-science-pack": 5000}, 300000, 30000, [("Sunward", "vulcanus")])],
              stats=({"astra": {"deaths": 0, "haul_items": 9000, "haul_from": "game"}, "sol": {"deaths": 0, "haul_items": 1000, "haul_from": "game"}}, None))
        # s3: began from an earlier save (tick 432000 < 648000); efficiency rows (the last is the shift)
        write(root, "s3", "s2", [
            score("2026-10-12T13:10:00", 432000, 9, ["automation", "logistics"], {"automation-science-pack": 2000, "logistic-science-pack": 1500},
                  {"automation-science-pack": 1300, "logistic-science-pack": 1300}, 200000, 20000, [("Sunward", "nauvis")]),
            score("2026-10-12T14:10:00", 648000, 12, ["automation", "logistics", "electronics", "steel-processing"],
                  {"automation-science-pack": 3000, "logistic-science-pack": 2500}, {"automation-science-pack": 1900, "logistic-science-pack": 1900},
                  320000, 32000, [("Sunward", "in transit")])],
              stats=({"astra": {"deaths": 1, "haul_items": 7000, "haul_from": "game"}}, {"machines": 900, "machines_working": 300, "made_items": 1, "made_share_pct": 1}),
              eff=[{"machines": 10, "running": 5, "items_shift": 5, "hand_items_shift": 5, "machine_share_pct": 50},
                   {"machines": 910, "running": 400, "items_shift": 1_200_000, "hand_items_shift": 130_000, "machine_share_pct": 90}])
        d = P.load(root)
        s1, s2, s3 = d["shifts"]
        assert [s["shift"] for s in d["shifts"]] == ["s1", "s2", "s3"]
        # own changes, from the shift's first row to its last
        assert (s1["research_new"], s1["research"], s1["researched"]) == (2, 2, ["automation", "logistics"]), s1
        assert (s1["rockets_new"], s1["rockets"]) == (3, 3)
        assert s1["spm"] == 11.7, s1["spm"]  # 700 units over 60 minutes (the first row has lab counts of 0: all are used)
        assert s2["spm"] == 10.0, s2["spm"]  # red and green 1200 each over 120 minutes; agricultural (5000, spoils) is not the unit
        assert s2["labs_use_per_min"] == {"agricultural-science-pack": 41.7, "automation-science-pack": 10.0, "logistic-science-pack": 10.0}
        assert s2["output_per_min"] == {"plates": 2000.0, "circuits": 200.0}, s2["output_per_min"]
        assert (s2["rockets_new"], s2["platforms_built"], s2["platforms_lost"]) == (12, ["Sunward"], ["Starling"])
        assert (s3["research_new"], s3["rockets_new"]) == (2, 3), s3  # its own rows: 2 technologies, 9 -> 12 rockets
        assert s3["rolled_back"] == {"game_start": "2h00m", "previous_end": "3h00m", "game_minutes": 60.0}, s3["rolled_back"]
        # agent-stats: deaths and hand moves summed; journal-counted before the game's count
        assert (s1["deaths"], s1["moved_by_hand"], s1["moved_by_hand_from"]) == (3, 750, "journal")
        assert (s2["moved_by_hand"], s2["moved_by_hand_from"]) == (10000, "game")
        # efficiency.jsonl's last row is the shift (it wins over agent-stats' machines_team)
        assert (s3["machines"], s3["machines_running"], s3["made_by_machines"], s3["moved_by_hand"], s3["machine_share_pct"]) == (910, 400, 1_200_000, 130_000, 90)
        assert s1["tokens"] == {"total": 2_500_000_000, "output": 1_500_000, "calls": 500, "final": True}
        t = d["totals"]
        assert (t["shifts"], t["research"], t["rockets"], t["deaths"], t["rollbacks"]) == (3, 4, 12, 4, ["s3"]), t
        assert t["platforms"] == ["Sunward"] and t["platforms_lost"] == ["Starling"], t
        assert d["trend"]["shifts"] == ["s1", "s2", "s3"] and d["trend"]["rockets_new"] == [3, 12, 3]
        # the short form: a line per shift, the totals, the trend
        out = run(["--runs", root, "--bot", "astra", "--journal", "/tmp/x.jsonl"]).splitlines()
        assert len(out) == 5, out
        assert out[0].startswith("s1 10:00-11:00 game 0h00m-1h00m | techs +2 (2) | SPM 11.7 | packs"), out[0]
        assert "by hand 750 (journals)" in out[0], out[0]
        assert "rockets +12 (15)" in out[1] and "plates 2000/min circuits 200/min" in out[1], out[1]
        assert "machines 400/910 running | made 1.20M, by hand 130k (90% machines)" in out[2], out[2]
        assert out[2].endswith("began from an earlier save (2h00m; the shift before ended at 3h00m)"), out[2]
        assert out[3].startswith("run s1-s3 (3 shifts), game 3h00m | techs 4 | rockets 12 |"), out[3]
        assert "platforms Sunward (lost 1)" in out[3] and out[3].endswith("earlier save at s3"), out[3]
        assert out[4] == "last 3 (s1-s3): SPM 11.7, 10, 10 | techs +2, +1, +2 | rockets +3, +12, +3 | packs/min 20, 115, 33.3 | plates/min 1000, 2000, 2000 | circuits/min 100, 200, 200 | deaths 3, 0, 1", out[4]
        # --last 1: one shift line; the totals and trend still cover the run
        out = run(["--runs", root, "--last", "1"]).splitlines()
        assert len(out) == 3 and out[0].startswith("s3 ") and out[1].startswith("run s1-s3"), out
        # --full: the technologies, the labs' use, packs made, platforms, tokens, the measures
        full = run(["--runs", root, "--full"])
        assert "  researched (1): electronics" in full
        assert "  labs' use a minute: agricultural 41.7, automation 10, logistic 10" in full, full
        assert "  platforms Sunward (vulcanus); built Sunward; lost Starling" in full
        assert "  team tokens 2.50B (output 1.50M), 500 model calls" in full
        assert "measures: spm: research units a minute" in full
        # JSON: the same data; nothing from tokens.json's sources (local paths)
        js = run(["--runs", root, "--format", "json"])
        data = json.loads(js)
        assert data["totals"]["rockets"] == 12 and len(data["shifts"]) == 3
        assert "/Users/" not in js and "sources" not in js
        # facts only: no ranking words in any form
        for word in ("best", "worst", "better", "worse", "improv", "declin", "should", "consider"):
            assert word not in (full + js).lower(), word
        # arguments
        try:
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                P.main(["--runs", root, "--bogus"])
            raise AssertionError("an unknown argument is refused")
        except SystemExit as e:
            assert e.code == 2
        # no shifts: said, exit 0
        empty = os.path.join(tmp, "none")
        os.makedirs(empty)
        assert run(["--runs", empty]).strip() == "no recorded shifts yet (no score log in the run's shifts)"
    print("progress: ok")


if __name__ == "__main__":
    main()
