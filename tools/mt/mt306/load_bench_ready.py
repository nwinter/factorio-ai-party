#!/usr/bin/env python3
"""(mt283, private) What a private copy does under a load (tools/mt/standin_load.py beside it), never world n:
  ups      game ticks a real second, read every --every s over --minutes (min, median, max of the samples)
  windows  profile_ticks {seconds=--window} back to back for --minutes, each read from the server log
           (tools/profile_log.py): the harness tick per game second (avg, p99, max; ms per tick = that / 60), the
           harness's total ms per game second, and the seconds a GC cycle finished (the heap fell) with their tick ms

  python3 tools/mt/load_bench.py --port 27476 --password-file ~/.config/pog/rcon-imac-mt.pw \\
      --log-cmd "ssh imac.local cat /Users/owner/pog-mt276/data/factorio-current.log" --minutes 30 --out x.json
"""
import argparse, json, os, re, statistics, subprocess, sys, threading, time

from config import TREE
HERE = str(TREE / "tools/mt")
sys.path.insert(0, os.path.join(HERE, ".."))
import pog  # noqa: E402

SECOND = re.compile(r'agent-harness profile second tick=(\d+) n=(\d+) key=(.+) time=\D*?([\d.]+) ?ms\s*$')
HEAP = re.compile(r'agent-harness profile heap tick=(\d+) kb=(\d+) grew_kb=(\d+) fell_kb=(\d+)')


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else None


def ups_window(samples, start_tick, end_tick):
    # Exclude intervals crossing a boundary, rather than assigning a stall
    # before this profile to its first minute. Keep raw intervals in the file.
    rates = [s["ups"] for s in samples if start_tick <= s["from_tick"] and s["to_tick"] <= end_tick]
    return {"samples": len(rates), "min": min(rates) if rates else None,
            "median": statistics.median(rates) if rates else None}


def window_stats(text, start_tick, end_tick):
    tick, total, heap = {}, {}, {}
    for line in text.splitlines():
        m = SECOND.search(line)
        if m:
            t, key, ms = int(m.group(1)), m.group(3).strip(), float(m.group(4))
            if start_tick <= t < end_tick:
                if key == "tick":
                    tick[t] = ms
                if not key.startswith("part ") and key != "*":
                    total[t] = total.get(t, 0) + ms
            continue
        m = HEAP.search(line)
        if m and start_tick <= int(m.group(1)) < end_tick:
            heap[int(m.group(1))] = (int(m.group(2)), int(m.group(4)))
    secs = sorted(tick)
    vals = [tick[s] for s in secs]
    gc = [s for s in secs if heap.get(s, (0, 0))[1] > 0]
    gc_ms = [tick[s] for s in gc]
    other = [tick[s] for s in secs if s not in gc]
    kb = [h[0] for h in heap.values()]
    return {"seconds": len(secs),
            "tick_ms_per_s": {"avg": round(statistics.mean(vals), 2) if vals else None, "p99": pct(vals, 0.99), "max": max(vals) if vals else None},
            "tick_ms_per_tick_avg": round(statistics.mean(vals) / 60, 3) if vals else None,
            "harness_ms_per_s": {"avg": round(statistics.mean(total.values()), 2) if total else None, "p99": pct(list(total.values()), 0.99),
                                 "max": max(total.values()) if total else None},
            "gc_finishes": len(gc), "gc_second_tick_ms": {"median": statistics.median(gc_ms) if gc_ms else None, "max": max(gc_ms) if gc_ms else None},
            "other_seconds_tick_ms_median": statistics.median(other) if other else None,
            "heap_mb": {"min": round(min(kb) / 1024) if kb else None, "max": round(max(kb) / 1024) if kb else None}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="imac.local")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--password-file", required=True)
    ap.add_argument("--log-cmd", required=True)
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--window", type=int, default=300)
    ap.add_argument("--every", type=float, default=10)
    ap.add_argument("--label", default="")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    if a.port in (27025,):
        sys.exit("refusing world n's port")
    pw = open(os.path.expanduser(a.password_file)).read().strip()
    r = pog.Rcon(a.host, a.port, pw, timeout=120)
    r2 = pog.Rcon(a.host, a.port, pw, timeout=120)
    t_end = time.time() + a.minutes * 60
    samples = []
    ups_samples = []

    def ups():
        last = None
        while time.time() < t_end:
            tk = int(r2.command("/silent-command rcon.print(game.tick)").strip())
            now = time.time()
            if last:
                value = (tk - last[0]) / (now - last[1])
                samples.append(value)
                ups_samples.append({"t": now, "from_tick": last[0], "to_tick": tk, "ups": value})
            last = (tk, now)
            time.sleep(a.every)
    th = threading.Thread(target=ups, daemon=True)
    th.start()
    windows = []
    while time.time() + 30 < t_end:
        seconds = int(min(a.window, (t_end - time.time())))
        start = json.loads(r.command(f"/silent-command rcon.print(remote.call('agent_harness','profile_ticks',{{seconds={seconds}}}))"))
        if not windows:
            with open(a.out + '.ready', 'w') as ready:
                json.dump(start, ready)
        print(json.dumps({'profile_start': start}), flush=True)
        s_tick = start.get("tick") or 0
        give_up = time.time() + seconds * 4  # a window is game seconds: under 60 UPS it takes longer than its seconds
        while time.time() < give_up:
            time.sleep(5)
            tk = int(r.command("/silent-command rcon.print(game.tick)").strip())
            if tk >= start.get("until_tick", s_tick + seconds * 60) + 120:
                break
        text = subprocess.run(a.log_cmd, shell=True, capture_output=True, text=True).stdout
        w = window_stats(text, s_tick, s_tick + seconds * 60)
        done = re.search(r'profile done from_tick=' + str(s_tick) + r' .*?dropped=(\d+)', text)
        w['dropped_lines'] = int(done.group(1)) if done else None
        assert w['dropped_lines'] == 0, 'profile missing completion or dropped lines'
        assert w['seconds'] >= seconds - 1, 'incomplete per-second profile'
        w["from_tick"] = s_tick
        w["until_tick"] = s_tick + seconds * 60
        w["ups"] = ups_window(ups_samples, s_tick, s_tick + seconds * 60)
        windows.append(w)
        print(json.dumps({"window": len(windows), **w}))
    t_end = time.time()  # the UPS samples stop with the last window
    th.join(timeout=a.every + 5)
    res = {"label": a.label, "at": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
           "ups": {"samples": len(samples), "min": round(min(samples), 1) if samples else None,
                   "median": round(statistics.median(samples), 1) if samples else None, "max": round(max(samples), 1) if samples else None},
           "windows": windows, "ups_samples": ups_samples}
    json.dump(res, open(a.out, "w"), indent=1)
    print(json.dumps(res["ups"]))


if __name__ == "__main__":
    main()
