#!/usr/bin/env python3
"""tools/bench_ticks.py on a made-up --benchmark-verbose output: python3 tools/test_bench_ticks.py

- the per-tick rows are read from the CSV after its header (nanoseconds to ms), a second header starts run 2;
- ticks over --spike-ms are listed with their top categories, and a shared tick % N names the period;
- --parts adds the harness bench timers' parts for each spike tick.
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_ticks as B  # noqa: E402

HEADER = "tick,timestamp,wholeUpdate,latencyUpdate,gameUpdate,entityUpdate,luaGarbageIncremental,scriptUpdate,"


def bench_text():
    lines = ["Factorio 2.0.77 (build 1, linux64, headless)", "Running update 1/3", HEADER]
    for run in (1, 2):
        if run == 2:
            lines.append(HEADER)
        for t in range(1000, 1600):
            script = 70_000_000 if t % 300 == 120 else 1_000_000
            whole = 4_000_000 + script
            lines.append(f"t{t},{t * 1000},{whole},0,{whole},3000000,0,{script},")
    lines.append("Performed 600 updates in 4000.000 ms")
    return lines


def main():
    rows = B.read_bench(bench_text())
    assert len(rows) == 1200 and {r[0] for r in rows} == {1, 2}, len(rows)
    assert abs(rows[0][2]["wholeUpdate"] - 5.0) < 1e-9 and rows[0][1] == 1000, rows[0]
    parts = B.read_parts(["  12.0 Script log: agent-harness bench tick=1020 part=census.tick Duration: 61.25ms",
                          "agent-harness bench tick=1020 part=survey.tick Duration: 3.5 ms", "unrelated line"])
    assert parts == {1020: {"census.tick": 61.25, "survey.tick": 3.5}}, parts
    out = "\n".join(B.summary(rows, 20, parts))
    assert "1200 ticks in 2 run(s)" in out, out
    assert "4 ticks >= 20 ms" in out, out
    assert "tick 1020: 74.0 ms = scriptUpdate 70.0, entityUpdate 3.0" in out and "harness: census.tick 61.2" in out, out
    assert "tick % 300 == 120 (4/4)" in out and "tick % 60 == 0" not in out, out
    assert "no per-tick rows" in "\n".join(B.summary([], 20))
    bench_mod()
    print("bench ticks: ok (rows by run, spike ticks with categories and harness parts, the shared period; "
          "bench_mod.py's control.lua patch)")


def bench_mod():
    """tools/bench_mod.py patches this checkout's control.lua: the timers hook before the runtime tick, the folder's
    runtime instead of the save's; the result compiles (luac -p, when installed)."""
    import shutil, subprocess, tempfile
    import bench_mod as M
    with open(os.path.join(M.MOD, "control.lua")) as f:
        src = f.read()
    both = M.patch(src, True, True)
    assert both.startswith("local BENCH\nlocal BENCH_PARTS = {") and "if BENCH then BENCH(runtime) end" in both, both[:200]
    assert "runtime = default_runtime\nend" in both and "compile(storage.agent_harness.source) or default_runtime" not in both
    assert M.patch(src, False, False) == src
    for name, field in M.PARTS:  # every part names a runtime field the tick uses
        assert name in open(os.path.join(M.MOD, "runtime.lua")).read(), name
    if shutil.which("luac"):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "control.lua")
            open(path, "w").write(both)
            r = subprocess.run(["luac", "-p", path], capture_output=True, text=True)
            assert r.returncode == 0, r.stderr


if __name__ == "__main__":
    main()
