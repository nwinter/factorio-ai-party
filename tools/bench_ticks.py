#!/usr/bin/env python3
"""Where a save's slow ticks go: python3 tools/bench_ticks.py BENCH.txt [--parts FACTORIO.log] [--spike-ms 20]

BENCH.txt is the output of `factorio --benchmark SAVE --benchmark-ticks N --benchmark-verbose all` (one CSV row per
tick: tick, timestamp, then the engine's update categories in nanoseconds; scriptUpdate is every mod's Lua, on_tick
and on_nth_tick handlers included). It prints the per-tick average and percentiles, the categories' average share,
the ticks over --spike-ms with their top categories, and how the spike ticks fall on common periods (tick % N), which
names an on_nth_tick or `tick % N == 0` handler.

--parts reads the agent-harness bench timers (tools/perf/bench-mod.sh adds them to a private copy of the mod: one
log line per timed part per tick, "agent-harness bench tick=T part=NAME Duration: X ms") and lists, for each spike
tick, the harness parts that took the time. Private copies only: never on world n.
"""
import argparse, collections, re, sys

PERIODS = (2, 5, 10, 15, 30, 60, 120, 180, 300, 600, 900, 1200, 1800, 3600)
PART = re.compile(r"agent-harness bench tick=(\d+) part=(\S+) Duration: ([\d.]+)\s*ms")


def read_bench(lines):
    """[(run, tick, {category: ms})]: rows after each header line; a new header starts a new run."""
    header, run, rows = None, 0, []
    for line in lines:
        line = line.strip()
        if "wholeUpdate" in line and line.split(",")[0] in ("tick", "t"):
            header = [h for h in line.split(",") if h]
            run += 1
            continue
        if header and re.match(r"^t\d+,", line):
            vals = line.split(",")
            tick = int(vals[0][1:])
            cats = {}
            for name, v in zip(header[2:], vals[2:]):
                try:
                    cats[name] = int(v) / 1e6  # nanoseconds
                except ValueError:
                    pass
            rows.append((run, tick, cats))
    return rows


def read_parts(lines):
    """{tick: {part: ms}}"""
    out = collections.defaultdict(dict)
    for line in lines:
        m = PART.search(line)
        if m:
            t, part, ms = int(m.group(1)), m.group(2), float(m.group(3))
            out[t][part] = out[t].get(part, 0.0) + ms
    return out


def pct(sorted_vals, p):
    return sorted_vals[min(len(sorted_vals) - 1, int(len(sorted_vals) * p))] if sorted_vals else 0.0


def summary(rows, spike_ms, parts=None, top=25):
    out = []
    whole = sorted(r[2].get("wholeUpdate", 0.0) for r in rows)
    n = len(whole)
    if not n:
        return ["no per-tick rows (was the benchmark run with --benchmark-verbose all?)"]
    mean = sum(whole) / n
    out.append(f"{n} ticks in {len({r[0] for r in rows})} run(s): wholeUpdate mean {mean:.2f} ms, p50 {pct(whole, .5):.2f}, "
               f"p99 {pct(whole, .99):.2f}, max {whole[-1]:.2f} ms")
    cats = collections.Counter()
    for _, _, c in rows:
        for k, v in c.items():
            if k not in ("wholeUpdate", "gameUpdate", "latencyUpdate"):
                cats[k] += v
    out.append("mean ms per tick by category (top 12): " + ", ".join(f"{k} {v / n:.2f}" for k, v in cats.most_common(12)))
    spikes = [r for r in rows if r[2].get("wholeUpdate", 0.0) >= spike_ms]
    out.append(f"{len(spikes)} ticks >= {spike_ms:g} ms ({len(spikes) / n * 100:.2f}% of ticks, "
               f"{sum(r[2]['wholeUpdate'] for r in spikes) / max(1, sum(whole)) * 100:.1f}% of the time)")
    for run, tick, c in sorted(spikes, key=lambda r: -r[2]["wholeUpdate"])[:top]:
        parts_txt = ""
        cs = sorted(((k, v) for k, v in c.items() if k not in ("wholeUpdate", "gameUpdate", "latencyUpdate")), key=lambda kv: -kv[1])[:3]
        if parts and tick in parts:
            ps = sorted(parts[tick].items(), key=lambda kv: -kv[1])[:4]
            parts_txt = " | harness: " + ", ".join(f"{k} {v:.1f}" for k, v in ps)
        out.append(f"  run {run} tick {tick}: {c['wholeUpdate']:.1f} ms = " + ", ".join(f"{k} {v:.1f}" for k, v in cs) + parts_txt)
    if spikes:
        found = {}
        for p in PERIODS:
            phase = collections.Counter(r[1] % p for r in spikes)
            ph, cnt = phase.most_common(1)[0]
            if cnt >= max(2, len(spikes) * 0.8):
                found[p] = (ph, cnt)
        # the longest periods only: tick % 300 == 120 implies tick % 60 == 0
        hits = [f"tick % {p} == {ph} ({cnt}/{len(spikes)})" for p, (ph, cnt) in found.items()
                if not any(q > p and q % p == 0 for q in found)]
        out.append("periods shared by >= 80% of spike ticks: " + (", ".join(hits) or "none"))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("bench")
    ap.add_argument("--parts", help="factorio-current.log with the bench timers' lines")
    ap.add_argument("--spike-ms", type=float, default=20.0)
    ap.add_argument("--top", type=int, default=25)
    a = ap.parse_args(argv)
    with open(a.bench, errors="replace") as f:
        rows = read_bench(f)
    parts = None
    if a.parts:
        with open(a.parts, errors="replace") as f:
            parts = read_parts(f)
    print("\n".join(summary(rows, a.spike_ms, parts, a.top)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
