#!/usr/bin/env python3
"""Rank the harness profiler's log lines (profile_ticks with a table, profile.lua).

LuaProfiler readings cannot be compared inside the game, so the runtime logs one
line per key per game second and one total per key; this reads them from the
server log (factorio-current.log) and prints the worst keys by total time with
their count, average and worst second, then the game seconds where the harness
spent the most. Part keys run inside a dispatch or the tick and are already in
its time. Heap lines (the harness's Lua heap each second: KB, grown, fallen) mark
the seconds a garbage collection finished (the heap fell), beside the busiest
seconds and in a summary line.

  python3 tools/profile_log.py factorio-current.log [--top 20] [--run -1]
"""
import argparse
import re
import sys

LINE = re.compile(r'agent-harness profile (second|total) ticks?=(\d+) n=(\d+) key=(.+) time=\D*?([\d.]+) ?ms\s*$')
HEAP = re.compile(r'agent-harness profile heap tick=(\d+) kb=(\d+) grew_kb=(\d+) fell_kb=(\d+)')
DONE = re.compile(r'agent-harness profile done from_tick=(\d+) to_tick=(\d+) \((\w+)\)(.*)$')
# (d22 batch110 BT1) profile_ticks {alloc: true}: the heap grown inside each key over the run (KB), and how many calls
# saw it fall inside (a collection step freed more than the call made: not counted).
ALLOC = re.compile(r'agent-harness profile alloc ticks=(\d+) n=(\d+) key=(.+) kb=(\d+) gc_inside=(\d+)\s*$')


def runs(text):
    """Each finished run: (done match, second rows, total rows, heap rows, alloc rows). Rows are (tick_or_ticks, n,
    key, ms); heap rows (tick, kb, grew_kb, fell_kb); alloc rows (ticks, n, key, kb, gc_inside)."""
    out, seconds, totals, heaps, allocs = [], [], [], [], []
    for raw in text.splitlines():
        a = ALLOC.search(raw)
        if a:
            allocs.append((int(a.group(1)), int(a.group(2)), a.group(3), int(a.group(4)), int(a.group(5))))
            continue
        m = LINE.search(raw)
        if m:
            row = (int(m.group(2)), int(m.group(3)), m.group(4), float(m.group(5)))
            (seconds if m.group(1) == 'second' else totals).append(row)
            continue
        h = HEAP.search(raw)
        if h:
            heaps.append(tuple(int(h.group(i)) for i in range(1, 5)))
            continue
        d = DONE.search(raw)
        if d:
            out.append((d, seconds, totals, heaps, allocs))
            seconds, totals, heaps, allocs = [], [], [], []
    if seconds or totals:
        out.append((None, seconds, totals, heaps, allocs))
    return out


def report(run, top):
    done, seconds, totals = run[:3]
    heaps = {row[0]: row for row in (run[3] if len(run) > 3 else [])}
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
            h = heaps.get(tick)
            fell = f'; heap fell {h[3] / 1024:.1f} MB (a garbage collection finished)' if h and h[3] > 0 else ''
            lines.append(f'  tick {tick}: {ms:.2f} ms over {n} calls; ' + ', '.join(f'{k} {m:.2f} ms (n={c})' for _, c, k, m in keys) + fell)
    if heaps:
        rows = sorted(heaps.values())
        kb = [r[1] for r in rows]
        falls = [r for r in rows if r[3] > 0]
        grew = sum(r[2] for r in rows) / max(1, len(rows))
        lines.append(f'Lua heap: {min(kb) / 1024:.1f}-{max(kb) / 1024:.1f} MB, grew {grew / 1024:.2f} MB a second; it fell in '
                     f'{len(falls)} of {len(rows)} seconds' + (': ' + ', '.join(f'tick {r[0]} ({r[3] / 1024:.1f} MB)' for r in falls[:10]) if falls else ''))
    allocs = run[4] if len(run) > 4 else []
    if allocs:
        secs = max(1, allocs[0][0]) / 60
        lines.append(f'Lua heap grown inside each key (alloc run; parts are inside their tick or dispatch), {secs:.0f} s:')
        lines.append(f'{"key":44} {"count":>7} {"MB":>9} {"MB a s":>8} {"KB a call":>10} {"gc inside":>9}')
        for ticks, n, key, kb, gc in sorted(allocs, key=lambda r: -r[3])[:top]:
            lines.append(f'{key[:44]:44} {n:>7} {kb / 1024:>9.2f} {kb / 1024 / secs:>8.3f} {kb / max(n, 1):>10.2f} {gc:>9}')
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
