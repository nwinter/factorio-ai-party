#!/usr/bin/env python3
"""How each agent slept in a run, from the journals (docs/studies/sleep.md's measures, plus the eng/sleep fields).

  tools/analysis/sleep_share.py runs/shake7 [--since 2026-10-11T20:30]   (--since: UTC ISO, a resumed shift's start)

Per agent: share of the window asleep (first request to deadline.txt, or to the last request), sleeps, seconds asked
(median), how sleeps ended (woke), what kept going (while_asleep: queue / action / idle; blank on older runtimes), the
character's idle share during sleeps (from the wake replies' clock lines), sleeps with --until, repeats (a sleep
right after a wake), sleeps that never waited (a sleep with no sleep_check after it: the old `fh call sleep`), loops (a
sleep starting within 5 s of the previous one's end), and requests after the deadline (the final summary is due then).
"""
import argparse, collections, datetime, glob, gzip, json, os, re, statistics, sys

sys.dont_write_bytecode = True
IDLE = re.compile(r'\+(?:(\d+)h)?(?:(\d+)m)?(\d+)s since your last request, character idle (?:(\d+)h)?(?:(\d+)m)?(\d+)s of it')


def ts(text):
    return datetime.datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp()


def secs(h, m, s):
    return int(h or 0) * 3600 + int(m or 0) * 60 + int(s or 0)


def deadline_of(agent_dir):
    path = os.path.join(agent_dir, 'deadline.txt')
    if not os.path.exists(path):
        return None
    line = open(path).read().strip().split('\n')[0]
    m = re.match(r'(\d{4}-\d{2}-\d{2}) (\d{1,2}):(\d{2})(?::(\d{2}))? ?(\w+)?', line)
    if not m:
        return None
    zones = {'PDT': -7, 'PST': -8, 'UTC': 0, 'GMT': 0}
    base = datetime.datetime.strptime(f"{m[1]} {m[2]}:{m[3]}:{m[4] or '00'}", '%Y-%m-%d %H:%M:%S')
    offset = zones.get(m[5] or 'PDT', -7)
    return base.replace(tzinfo=datetime.timezone(datetime.timedelta(hours=offset))).timestamp()


def journal(agent_dir):
    for name in ('journal.jsonl.gz', 'journal.jsonl'):
        path = os.path.join(agent_dir, name)
        if os.path.exists(path):
            with (gzip.open(path, 'rt') if name.endswith('.gz') else open(path)) as f:
                for line in f:
                    try:
                        yield json.loads(line)
                    except ValueError:
                        continue
            return


def agent(agent_dir, since):
    reqs, sleeps, first, last, cur = {}, [], None, None, None
    after_deadline = 0
    deadline = deadline_of(agent_dir)
    for e in journal(agent_dir):
        at = ts(e['at']) if e.get('at') else None
        if at is None or at < since:
            continue
        if e.get('event') == 'request':
            r = e['request']
            reqs[r.get('id')] = r
            first = first if first is not None else at
            last = at
            if deadline and at > deadline:
                after_deadline += 1
            if r.get('action') == 'sleep':
                cur = {'start': at, 'asked': (r.get('args') or {}).get('seconds'), 'until': 'condition' in (r.get('args') or {}),
                       'end': None, 'woke': None, 'checks': 0}
                sleeps.append(cur)
        elif e.get('event') == 'response':
            resp = e.get('response') or {}
            r = reqs.pop(resp.get('id'), None) or {}
            res = resp.get('result') or {}
            if r.get('action') == 'sleep' and sleeps and resp.get('ok'):
                s = sleeps[-1]
                s['while'] = res.get('while_asleep')
                s['repeat'] = bool(res.get('repeat'))
            if r.get('action') == 'observe' and (r.get('args') or {}).get('scope') == 'sleep_check' and cur:
                cur['checks'] += 1
                cur['end'] = at
                if not (r.get('args') or {}).get('peek') and resp.get('ok'):
                    cur['woke'] = res.get('woke')
                    m = IDLE.search(res.get('clock') or '')
                    if m:
                        cur['span'], cur['idle'] = secs(*m.groups()[:3]), secs(*m.groups()[3:])
    window_end = deadline if deadline else last
    if first is None or window_end is None or window_end <= first:
        return None
    asleep = sum(max(0, min(s['end'] or s['start'], window_end) - s['start']) for s in sleeps)
    loops, prev_end = 0.0, None
    for s in sleeps:
        if prev_end is not None and s['start'] - prev_end <= 5:
            loops += max(0, min(s['end'] or s['start'], window_end) - s['start'])
        prev_end = s['end'] or s['start']
    spans = [s for s in sleeps if s.get('span')]
    kinds = collections.Counter()
    for s in sleeps:
        w = s.get('while') or ''
        kinds['repeat' if s.get('repeat') else 'queue' if w.startswith('your queue') else 'action' if w.startswith('your ')
              else 'idle' if w.startswith('no queue') else 'unknown'] += 1
    return {
        'window_min': (window_end - first) / 60, 'asleep': asleep / (window_end - first), 'sleeps': len(sleeps),
        'asked': statistics.median([s['asked'] for s in sleeps if s['asked']]) if sleeps else 0,
        'woke': collections.Counter(s['woke'] or ('never waited' if s['checks'] == 0 else 'open') for s in sleeps),
        'kinds': kinds, 'until': sum(1 for s in sleeps if s['until']),
        'idle': sum(s['idle'] for s in spans) / sum(s['span'] for s in spans) if spans and sum(s['span'] for s in spans) else None,
        'loops': loops / asleep if asleep else 0, 'after_deadline': after_deadline}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('run')
    ap.add_argument('--since', help='UTC ISO time; only requests from then on (a resumed shift)')
    a = ap.parse_args()
    since = ts(a.since + ('' if a.since.endswith('Z') or '+' in a.since else '+00:00')) if a.since else 0
    for agent_dir in sorted(glob.glob(os.path.join(a.run, '*/'))):
        row = agent(agent_dir, since)
        if not row:
            continue
        name = os.path.basename(agent_dir.rstrip('/'))
        idle = f"{100 * row['idle']:.0f}%" if row['idle'] is not None else '-'
        print(f"{name:8s} asleep {100 * row['asleep']:3.0f}% of {row['window_min']:.0f}m, {row['sleeps']} sleeps (median {row['asked']} s asked), "
              f"character idle {idle} of it, loops {100 * row['loops']:.0f}%, --until {row['until']}, after deadline {row['after_deadline']} requests")
        print(f"         woke: {dict(row['woke'].most_common())}")
        print(f"         while asleep: {dict(row['kinds'].most_common())}")


if __name__ == '__main__':
    main()
