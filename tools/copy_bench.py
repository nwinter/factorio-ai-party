#!/usr/bin/env python3
"""One benchmark of a private copy, so reports from different machines compare (d27 batch279 IM: the iMac's native
copy against OrbStack's x86 emulation on the Mac Studio). Read only for the game's state: it unpauses the copy and
runs the harness's own profilers; never point it at world n.

  python3 tools/copy_bench.py --world imac --log-cmd "tools/imac-copy.sh log 0"
  python3 tools/copy_bench.py --port 27205 --password-file ~/code/pog-headless-b205/rcon-pass.txt \\
      --log-cmd "docker exec pog-b205-headless cat /pog/factorio/factorio-current.log"

It measures, in order, and prints one JSON line (and --out FILE keeps it):
  ups         game ticks per real second over --ups-seconds (the copy unpaused, no client)
  tick_ms     the harness tick's own average (profile_ticks N; its log line)
  profile     profile_ticks {seconds}: tools/profile_log.py's ranking, and the total ms per game second
  reads       dispatch timings (LuaProfiler around remote.call) of fixed reads as --bot, each --repeat times
"""
import argparse, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pog  # noqa: E402
import profile_log  # noqa: E402

READS = [  # (label, action, args): reads that touch the world as agents' do, not world n
    ("status", "status", {}),
    ("labs_nauvis", "observe", {"surface": "nauvis", "scope": "labs"}),
    ("networks", "networks", {"surface": "nauvis"}),
]
TICK_AVG = re.compile(r"agent-harness tick average over (\d+) ticks .*?: Duration: ([\d.]+) ?ms")
MARK = re.compile(r"COPYBENCH (\S+) (\d+) Duration: ([\d.]+) ?ms")


class Copy:
    def __init__(self, a):
        world = a.world or ("imac" if not a.port else None)  # --port alone: a copy on this Mac (OrbStack)
        port = a.port or pog.PORTS[world]
        host = a.host or pog.HOSTS.get(world, "127.0.0.1")
        pw = open(os.path.expanduser(a.password_file or f"~/.config/pog/rcon-{world}.pw")).read().strip()
        self.r = pog.Rcon(host, port, pw, timeout=600)
        self.log_cmd = a.log_cmd

    def lua(self, code):
        return self.r.command("/silent-command " + " ".join(code.split("\n")))

    def tick(self):
        return int(self.lua("rcon.print(game.tick)"))

    def log(self):
        return subprocess.run(self.log_cmd, shell=True, capture_output=True, text=True, check=True).stdout


def wait_for(copy, pattern, after_len, timeout):
    """The first match of `pattern` in the log past its first after_len characters, waiting up to timeout s."""
    end = time.time() + timeout
    while time.time() < end:
        text = copy.log()
        m = pattern.search(text, after_len)
        if m:
            return m, text
        time.sleep(5)
    raise SystemExit(f"timed out waiting for {pattern.pattern!r} in the log")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", help="a pog world name (default imac; with --port alone: 127.0.0.1)")
    ap.add_argument("--host")
    ap.add_argument("--port", type=int)
    ap.add_argument("--password-file")
    ap.add_argument("--log-cmd", required=True, help="prints the copy's whole factorio-current.log")
    ap.add_argument("--bot", default="astra")
    ap.add_argument("--ups-seconds", type=float, default=30)
    ap.add_argument("--tick-n", type=int, default=600)
    ap.add_argument("--profile-seconds", type=int, default=60)
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--label", default="")
    ap.add_argument("--out")
    a = ap.parse_args()
    c = Copy(a)
    out = {"label": a.label or a.world or f"port {a.port}", "at": time.strftime("%Y-%m-%d %H:%M:%S %Z")}
    c.lua("game.tick_paused = false")
    t0, k0 = time.time(), c.tick()
    time.sleep(a.ups_seconds)
    t1, k1 = time.time(), c.tick()
    ups = (k1 - k0) / (t1 - t0)
    out.update(ups=round(ups, 1), tick=k1)
    print(f"ups {ups:.1f} over {t1 - t0:.0f} s", file=sys.stderr)
    # the harness tick's average (profile_ticks N)
    n0 = len(c.log())
    c.lua(f"rcon.print(helpers.table_to_json(remote.call('agent_harness','profile_ticks',{a.tick_n})))")
    m, _ = wait_for(c, TICK_AVG, n0, a.tick_n / max(ups, 1) * 3 + 60)
    out["tick_ms"] = float(m.group(2))
    print(f"harness tick average {out['tick_ms']} ms over {m.group(1)} ticks", file=sys.stderr)
    # the dispatch and event profiler for a stretch of game time
    n0 = len(c.log())
    c.lua(f"rcon.print(helpers.table_to_json(remote.call('agent_harness','profile_ticks',{{seconds={a.profile_seconds}}})))")
    _, text = wait_for(c, profile_log.DONE, n0, a.profile_seconds * 60 / max(ups, 1) * 3 + 120)
    done, seconds, totals = [r for r in profile_log.runs(text[n0:]) if r[0]][-1][:3]
    per_key = {}
    for _, cnt, key, ms in totals:
        per_key[key] = {"n": cnt, "ms": round(ms, 2)}
    span_s = max(1, (int(done.group(2)) - int(done.group(1))) / 60)
    star = per_key.get("*", {}).get("ms")
    out["profile"] = {"game_seconds": round(span_s, 1), "harness_ms_per_game_second": round(star / span_s, 3) if star else None,
                      "top": sorted(((k, v) for k, v in per_key.items() if k != "*"), key=lambda kv: -kv[1]["ms"])[:12]}
    print(f"profile: {out['profile']['harness_ms_per_game_second']} ms per game second", file=sys.stderr)
    # fixed reads as the bot, timed in the game
    reads = {}
    for label, action, args in READS:
        n0 = len(c.log())
        for i in range(a.repeat):
            req = json.dumps({"id": f"copybench-{label}-{i}-{time.time_ns()}", "bot": a.bot, "action": action, "args": args})
            c.lua(f"local p=helpers.create_profiler(); remote.call('agent_harness','dispatch',[==[{req}]==]); p.stop(); "
                  f"log({{'','COPYBENCH {label} {i} ',p}}); rcon.print('ok')")
        ms = [float(x.group(3)) for x in MARK.finditer(c.log(), n0) if x.group(1) == label]
        reads[label] = {"ms": ms, "min": min(ms) if ms else None}
    out["reads"] = reads
    line = json.dumps(out)
    print(line)
    if a.out:
        with open(a.out, "a") as f:
            f.write(line + "\n")


if __name__ == "__main__":
    main()
