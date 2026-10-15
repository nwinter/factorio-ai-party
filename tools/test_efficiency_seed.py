#!/usr/bin/env python3
"""Who built the machines already standing, from the agents' journals: python3 tools/test_efficiency_seed.py

A world's chain of shifts (resumed-from), oldest first; a hand build's reply (unit, name, spot), a batch build's spots
in order (none when an entry failed), a ghost placement's request spots (a platform's: no surface), dry runs and
failures left out, only machines; the operator seed commands, 1000 rows a call."""
import gzip, json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import efficiency_seed as S  # noqa: E402


def journal(path, pairs, gz=True):
    lines = []
    for i, (action, args, result, ok, tick) in enumerate(pairs):
        rid = f"r{i}"
        lines.append({"at": "x", "event": "request", "request": {"id": rid, "action": action, "bot": None, "args": args}})
        lines.append({"at": "x", "event": "response", "response": {"id": rid, "ok": ok, "tick": tick, "result": result}})
    text = "".join(json.dumps(x) + "\n" for x in lines)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if gz:
        with gzip.open(path, "wt") as f:
            f.write(text)
    else:
        open(path, "w").write(text)


def main():
    names = {"assembling-machine-2", "electric-furnace", "electric-mining-drill", "lab"}
    with tempfile.TemporaryDirectory() as d:
        root = os.path.join(d, "runs")
        # s1 then s2 (resumed from s1); s0 is another world
        journal(os.path.join(root, "s1", "astra", "journal.jsonl.gz"), [
            ("build", {"item": "assembling-machine-2", "position": {"x": 10, "y": 10}},
             {"entity": {"name": "assembling-machine-2", "position": {"x": 10.5, "y": 10.5}, "unit_number": 77}}, True, 100),
            ("build", {"item": "transport-belt", "position": {"x": 1, "y": 1}},
             {"entity": {"name": "transport-belt", "position": {"x": 1.5, "y": 1.5}, "unit_number": 78}}, True, 101),
            ("build", {"builds": [{"item": "lab", "position": {"x": 0, "y": 0}}, {"item": "electric-furnace", "position": {"x": 5, "y": 0}}]},
             {"built": 2, "placed": [{"x": 0.5, "y": 0.5}, {"x": 5, "y": 0}]}, True, 102),
            ("build", {"builds": [{"item": "lab", "position": {"x": 9, "y": 9}}], "skip_failed": True},
             {"built": 0, "placed": [], "failed": [{"index": 1}]}, True, 103),
            ("build", {"item": "lab", "position": {"x": 2, "y": 2}, "dry_run": True}, {"dry_run": True, "entity": {"name": "lab"}}, True, 104),
            ("build", {"item": "lab", "position": {"x": 3, "y": 3}}, {"entity": {"name": "lab", "unit_number": 9}}, False, 105),
        ])
        journal(os.path.join(root, "s2", "sol", "journal.jsonl"), [
            ("place_ghosts", {"entities": [{"name": "electric-mining-drill", "position": {"x": 40.5, "y": 40.5}},
                                           {"name": "transport-belt", "position": {"x": 1, "y": 1}}], "surface": "vulcanus"},
             {"placed": 2}, True, 50),
            ("place_ghosts", {"entities": [{"name": "assembling-machine-2", "position": {"x": -6.5, "y": 1.5}}], "platform": "Sunward"},
             {"placed": 1}, True, 60),
            ("place_ghosts", {"entities": [{"name": "lab", "position": {"x": 0, "y": 0}}], "dry_run": True},
             {"dry_run": True}, True, 70),
        ], gz=False)
        open(os.path.join(root, "s2", "resumed-from"), "w").write("s1\n")
        journal(os.path.join(root, "s0", "opus", "journal.jsonl.gz"), [
            ("build", {"item": "lab", "position": {"x": 0, "y": 0}}, {"entity": {"name": "lab", "position": {"x": 0.5, "y": 0.5}, "unit_number": 1}}, True, 1)])
        chain = [os.path.basename(p) for p in S.chain("s2", [root])]
        assert chain == ["s1", "s2"], chain
        rows = S.collect("s2", [root], names)
        got = [(r["by"], r["how"], r.get("unit"), r["name"], r["x"], r["y"], r["surface"], r["tick"]) for r in rows]
        assert got == [
            ("sol", "ghost", None, "electric-mining-drill", 40.5, 40.5, "vulcanus", 50),
            ("sol", "ghost", None, "assembling-machine-2", -6.5, 1.5, None, 60),     # a platform: no surface
            ("astra", "build", 77, "assembling-machine-2", 10.5, 10.5, None, 100),
            ("astra", "build batch", None, "lab", 0.5, 0.5, None, 102),
            ("astra", "build batch", None, "electric-furnace", 5, 0, None, 102),
        ], got
        assert S.summary(rows).startswith("5 rows, 1 with a unit number"), S.summary(rows)
        # the operator seed: one call per 1000 rows, the rows without the how and empty fields
        cmds = S.seed_commands(rows, chunk=2)
        assert len(cmds) == 3 and cmds[0].startswith('/silent-command rcon.print(remote.call("agent_harness", "dispatch", [[{')
        req = json.loads(cmds[2].split("[[", 1)[1].rsplit("]]", 1)[0])
        assert req["operator"] is True and req["action"] == "efficiency_seed" and len(req["args"]["rows"]) == 1
        assert req["args"]["rows"][0] == {"by": "astra", "tick": 102, "name": "electric-furnace", "x": 5, "y": 0}, req
        assert S.lua_string("a]]b") == "[=[a]]b]=]"
        # the kb's machine names: assemblers, furnaces, drills, labs, silos (no belts)
        kb = S.machine_names()
        assert kb and "assembling-machine-2" in kb and "rocket-silo" in kb and "transport-belt" not in kb
    print("efficiency seed: ok (the chain, builds by unit, batches by spot, ghosts by spot, dry runs and failures left out, the seed calls)")


if __name__ == "__main__":
    main()
