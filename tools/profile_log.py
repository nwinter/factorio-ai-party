#!/usr/bin/env python3
"""Rank the harness profiler's log lines (profile_ticks with a table, profile.lua).

LuaProfiler readings cannot be compared inside the game, so the runtime logs one
line per key per game second and one total per key; this reads them from the
server log (factorio-current.log) and prints the worst keys by total time with
their count, average and worst second, then the game seconds where the harness
spent the most. Part keys run inside a dispatch or the tick and are already in
its time.

  python3 tools/profile_log.py factorio-current.log [--top 20] [--run -1]
"""
import argparse
import re
import sys

LINE = re.compile(r'agent-harness profile (second|total) ticks?=(\d+) n=(\d+) key=(.+) time=\D*?([\d.]+) ?ms\s*$')
DONE = re.compile(r'agent-harness profile done from_tick=(\d+) to_tick=(\d+) \((\w+)\)(.*)$')


def runs(text):
    """Each finished run: (done match, second rows, total rows). Rows are (tick_or_ticks, n, key, ms)."""
    out, seconds, totals = [], [], []
    for raw in text.splitlines():
        m = LINE.search(raw)
        if m:
            row = (int(m.group(2)), int(m.group(3)), m.group(4), float(m.group(5)))
            (seconds if m.group(1) == 'second' else totals).append(row)
            continue
        d = DONE.search(raw)
        if d:
            out.append((d, seconds, totals))
            seconds, totals = [], []
    if seconds or totals:
        out.append((None, seconds, totals))
    return out


def report(run, top):
    done, seconds, totals = run
    lines = []
    if done:
        lines.append(f'run from tick {done.group(1)} to {done.group(2)} ({done.group(3)}){done.group(4)}')
    else:
        lines.append('run not finished (no done line): totals from the second lines so far')
        agg = {}
        for _, n, key, ms in seconds:
            a = agg.setdefault(key, [0, 0.0])
            a[0] += n
            a[1] += ms
        totals = [(0, n, key, ms) for key, (n, ms) in agg.items()]
    worst = {}
    for tick, n, key, ms in seconds:
        if key not in worst or ms > worst[key][0]:
            worst[key] = (ms, tick, n)
    ranked = sorted((t for t in totals if t[2] != '*'), key=lambda t: -t[3])[:top]
    lines.append(f'{"key":44} {"count":>7} {"total ms":>10} {"avg ms":>8} {"worst s ms":>10} {"at tick":>9} {"n":>4}')
    for _, n, key, ms in ranked:
        w = worst.get(key, (0.0, 0, 0))
        lines.append(f'{key[:44]:44} {n:>7} {ms:>10.2f} {ms / max(n, 1):>8.3f} {w[0]:>10.2f} {w[1]:>9} {w[2]:>4}')
    busiest = sorted((r for r in seconds if r[2] == '*'), key=lambda r: -r[3])[:min(top, 10)]
    if busiest:
        lines.append('busiest game seconds (all harness work, parts excluded):')
        for tick, n, _, ms in busiest:
            keys = sorted((r for r in seconds if r[0] == tick and r[2] != '*'), key=lambda r: -r[3])[:3]
            lines.append(f'  tick {tick}: {ms:.2f} ms over {n} calls; ' + ', '.join(f'{k} {m:.2f} ms (n={c})' for _, c, k, m in keys))
    return '\n'.join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('log', nargs='?', default='-', help='server log (factorio-current.log), - for stdin')
    ap.add_argument('--top', type=int, default=20)
    ap.add_argument('--run', type=int, default=-1, help='which run in the log (-1 the last)')
    a = ap.parse_args(argv)
    text = sys.stdin.read() if a.log == '-' else open(a.log, encoding='utf-8', errors='replace').read()
    found = runs(text)
    if not found:
        print('no agent-harness profile lines in the log')
        return 1
    print(report(found[a.run], a.top))
    return 0


if __name__ == '__main__':
    sys.exit(main())
