#!/usr/bin/env python3
"""Where a save's tick time goes, on a private headless copy (never world n):

  python3 tools/bench_private.py --factorio factorio/bin/x64/factorio --save save.zip --out bench-out [--ticks 3600]
      [--variants harness,no-harness,timers] [--runtime-from OTHER_CHECKOUT]

Each variant is one `factorio --benchmark SAVE --benchmark-ticks N --benchmark-runs 1 --benchmark-verbose all` with
its own mod folder (tools/bench_mod.py), its output in OUT/VARIANT.txt and a summary from tools/bench_ticks.py:
- harness: the mod as the save runs it (the runtime deployed in the save);
- no-harness: agent-harness disabled (the game and the other mods alone);
- timers: the harness with per-tick part timers (OUT/timers.log is that run's factorio-current.log; the summary names
  the harness parts in each slow tick);
- folder: this checkout's runtime.lua instead of the save's; with --runtime-from, also folder-other from that checkout
  (a before/after pair on the same save).
The benchmark has no clients, no RCON and no agents: what it shows is the game and the harness's own tick work.
"""
import argparse, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_mod  # noqa: E402
import bench_ticks  # noqa: E402


def mods_for(variant, out, runtime_from=None):
    d = os.path.join(out, "mods-" + variant)
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    mod = bench_mod.MOD
    if variant == "folder-other":
        mod = os.path.join(runtime_from, "vendor", "factorio-harness", "mod", "agent-harness_0.1.0")
    argv = [d, "--mod", mod]
    if variant == "timers":
        argv.append("--timers")
    if variant in ("folder", "folder-other"):
        argv.append("--folder-runtime")
    bench_mod.main(argv)
    if variant == "no-harness":
        import json
        path = os.path.join(d, "mod-list.json")
        data = json.load(open(path))
        for m in data["mods"]:
            if m["name"] == "agent-harness":
                m["enabled"] = False
        json.dump(data, open(path, "w"), indent=1)
    return d


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--factorio", required=True)
    ap.add_argument("--save", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ticks", type=int, default=3600)
    ap.add_argument("--variants", default="harness,no-harness,timers")
    ap.add_argument("--runtime-from", help="another checkout: adds folder and folder-other")
    ap.add_argument("--spike-ms", type=float, default=20.0)
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    variants = a.variants.split(",")
    if a.runtime_from:
        variants += [v for v in ("folder", "folder-other") if v not in variants]
    write_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(a.factorio))))  # factorio/
    for v in variants:
        mods = mods_for(v, a.out, a.runtime_from)
        cmd = [a.factorio, "--benchmark", a.save, "--benchmark-ticks", str(a.ticks), "--benchmark-runs", "1",
               "--benchmark-verbose", "all", "--disable-audio", "--mod-directory", mods]
        print("$ " + " ".join(cmd), flush=True)
        txt = os.path.join(a.out, v + ".txt")
        with open(txt, "w") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, check=False)
        log = os.path.join(write_dir, "factorio-current.log")
        parts = None
        if v == "timers" and os.path.exists(log):
            shutil.copy(log, os.path.join(a.out, "timers.log"))
            parts = bench_ticks.read_parts(open(log, errors="replace"))
        rows = bench_ticks.read_bench(open(txt, errors="replace"))
        print(f"== {v}")
        print("\n".join(bench_ticks.summary(rows, a.spike_ms, parts)), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
