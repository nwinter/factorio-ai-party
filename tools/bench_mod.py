#!/usr/bin/env python3
"""A benchmark copy of the agent-harness mod: python3 tools/bench_mod.py OUT_DIR [--timers] [--folder-runtime]

For `factorio --benchmark SAVE --benchmark-verbose all` on a private copy only (never world n). The copy is the mod
folder with control.lua patched:
- --timers: from the first tick, every harness tick part reachable from the runtime table is timed on every tick, one
  log line each ("agent-harness bench tick=T part=NAME Duration: X ms"; tools/bench_ticks.py --parts reads them), and
  the runtime's own profiler (profile_ticks) runs for 600 s, so the parts it alone reaches (survey.tick, threat.tick,
  scheduler.tick, clock.tick) get per-second lines (tools/profile_log.py). The log lines cost time themselves: compare
  totals from a run without --timers.
- --folder-runtime: the runtime is this folder's runtime.lua (require), not the one deployed in the save (control.lua
  compiles storage.agent_harness.source). A before/after pair of runs then compares two branches' runtime.lua on the
  same save without a deploy.
OUT_DIR gets agent-harness_0.1.0/ and a mod-list.json with base, space-age, quality, elevated-rails and agent-harness.
"""
import argparse, json, os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "vendor", "factorio-harness", "mod", "agent-harness_0.1.0")

# Reachable as fields of the runtime table M (runtime.lua tick_body calls them through these fields).
PARTS = [("tick_body", None), ("carry", "carry"), ("research", "tick"), ("bots", "tick"), ("drops", "tick"),
         ("drop_jobs_tick", None), ("nametags", "tick"), ("networks", "tick"), ("pushalerts", "tick"),
         ("census", "tick"), ("chronicle", "tick"), ("ground", "watch_tick"), ("scienceline", "tick"),
         ("powercut", "tick"), ("burnerfuel", "tick"), ("turretammo", "tick"), ("ores", "tick"), ("avoid", "prune"),
         ("space", "watch_stops"), ("freight", "tick"), ("launchwatch", "tick"), ("pods", "tick"),
         ("freight", "pod_tick"), ("engine", "tick"), ("spoil", "tick"), ("beltgaps", "tick"), ("orders", "tick"),
         ("reminders", "tick"), ("cameras", "tick"), ("efficiency", "tick"), ("visuals", "tick"), ("tick_action", None),
         ("on_event", None)]

HOOK = r"""
-- bench_mod.py: timers for a private benchmark copy (never deployed)
BENCH = function(M)
  BENCH = nil
  local function wrap(t, field, label)
    local fn = t and t[field]
    if type(fn) ~= 'function' then return end
    t[field] = function(...)
      local p = helpers.create_profiler()
      local out = table.pack(fn(...))
      p.stop()
      log({'', 'agent-harness bench tick=', game.tick, ' part=', label, ' ', p})
      return table.unpack(out, 1, out.n)
    end
  end
  for _, part in ipairs(BENCH_PARTS) do
    if part[2] then pcall(wrap, M[part[1]], part[2], part[1] .. '.' .. part[2]) else pcall(wrap, M, part[1], part[1]) end
  end
  if M.operator and M.operator.profile_ticks then pcall(M.operator.profile_ticks, {seconds=600}) end
end
"""


def lua_parts():
    rows = ", ".join("{%s, %s}" % (json.dumps(a), json.dumps(b) if b else "nil") for a, b in PARTS)
    return "local BENCH_PARTS = {" + rows + "}\n"


def patch(control, timers, folder_runtime):
    src = control
    call = "local ok, err = pcall(runtime.tick, event)"
    assert call in src, "control.lua's on_tick call changed; update bench_mod.py"
    if timers:
        src = "local BENCH\n" + lua_parts() + src
        src = src.replace(call, "if BENCH then BENCH(runtime) end\n  " + call, 1)
        src += HOOK
    if folder_runtime:
        boot = "  runtime = storage.agent_harness and storage.agent_harness.source\n    and compile(storage.agent_harness.source) or default_runtime"
        assert boot in src, "control.lua's boot changed; update bench_mod.py"
        src = src.replace(boot, "  runtime = default_runtime", 1)
    return src


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out")
    ap.add_argument("--timers", action="store_true")
    ap.add_argument("--folder-runtime", action="store_true")
    ap.add_argument("--mod", default=MOD, help="the mod folder to copy (default this checkout's)")
    a = ap.parse_args(argv)
    dest = os.path.join(a.out, "agent-harness_0.1.0")
    if os.path.exists(dest):
        shutil.rmtree(dest)
    shutil.copytree(a.mod, dest)
    path = os.path.join(dest, "control.lua")
    with open(path) as f:
        src = f.read()
    with open(path, "w") as f:
        f.write(patch(src, a.timers, a.folder_runtime))
    mods = [{"name": n, "enabled": True} for n in ("base", "elevated-rails", "quality", "space-age", "agent-harness")]
    with open(os.path.join(a.out, "mod-list.json"), "w") as f:
        json.dump({"mods": mods}, f, indent=1)
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
