#!/usr/bin/env python3
"""Bounded shift14 journal census. No expanded timelines or copied responses.

Reads each journal only to its initial byte size. Pairs concurrent calls by ID,
deduplicates status.last observations, and reports reviewed recovery intervals
as per-agent unions (never sums simultaneous retries). Request line numbers are
stable while the journals grow. Output is JSON on stdout, normally <100 KB.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime
import json
from pathlib import Path
import re

AGENTS = 'astra gemini grok haiku luna muse opus sol sonnet'.split()
START = '2026-10-15T03:06:00.000Z'
END = '2026-10-15T07:07:00.000Z'


def seconds(at):
    return datetime.fromisoformat(at.replace('Z', '+00:00')).timestamp()


def action(q):
    return q.get('args', {}).get('scope', q['action'])


def norm(message):
    message = message.split(' [ran as ')[0].split(';')[0]
    message = re.sub(r'\([^)]*\)', '(...)', message)
    return re.sub(r'\d+(?:\.\d+)?', 'N', message)[:160]


def load(path):
    pending, calls, terminals, sleeps = {}, [], [], []
    seen_last, seen_sleep = set(), set()
    stats = Counter()
    first = last = first_tick = None
    size = path.stat().st_size
    with path.open('rb') as stream:
        line_no = 0
        while stream.tell() < size:
            raw = stream.readline(size - stream.tell())
            line_no += 1
            try:
                row = json.loads(raw)
            except json.JSONDecodeError:
                stats['incomplete_lines'] += 1
                continue
            if not START <= row['at'] <= END:
                continue
            first = first or row['at']
            last = row['at']
            event = row['event']
            stats[event] += 1
            if event == 'request':
                q = row['request']
                pending[q['id']] = dict(line=line_no, at=row['at'],
                    action=action(q), args=q.get('args', {}))
                continue
            if event == 'transport_error':
                pending.pop(row.get('id'), None)
                stats['outcome_unknown' if 'outcome unknown' in row.get('error', '') else 'transport_not_sent_or_other'] += 1
                continue
            if event != 'response':
                continue
            reply = row['response']
            if first_tick is None:
                first_tick = reply.get('tick')
            call = pending.pop(reply.get('id'), None)
            if call is None:
                stats['orphan_responses'] += 1
                continue
            out = reply.get('result') or {}
            if not isinstance(out, dict):
                out = {}
            call.update(ok=reply.get('ok'), tick=reply.get('tick'),
                        response_at=row['at'], error=reply.get('error'), cut=out.get('cut'))
            calls.append(call)
            if not call['ok']:
                stats['failed'] += 1
            if call['cut']:
                stats['cut_' + call['action']] += 1
            if out.get('corrected'):
                stats['corrected'] += 1
            terminal = out.get('last')
            if isinstance(terminal, dict):
                key = (terminal.get('tick'), terminal.get('kind'), terminal.get('outcome'))
                if key not in seen_last and terminal.get('tick') is not None and terminal['tick'] >= (first_tick or 0):
                    seen_last.add(key)
                    terminals.append(dict(line=line_no, at=row['at'], **terminal))
            if call['action'] in ('sleep', 'sleep_check') and out.get('woke'):
                key = (out.get('until_tick'), out.get('woke'), out.get('repeat'))
                if key not in seen_sleep:
                    seen_sleep.add(key)
                    sleeps.append(dict(woke=out['woke'], repeat=bool(out.get('repeat'))))
    calls.sort(key=lambda c: c['line'])
    stats['unmatched_requests'] = len(pending)
    return calls, terminals, sleeps, dict(stats, bytes=size, first=first, last=last)


def union_seconds(intervals):
    total, end = 0, float('-inf')
    for lo, hi in sorted(intervals):
        total += max(0, hi - max(lo, end))
        end = max(end, hi)
    return total


def read_candidates(calls):
    """Signals only: journals cannot show whether the next read was dependent."""
    repeated, batchable = [], []
    previous = None
    for c in calls:
        if c['action'] in ('status', 'sleep_check', 'lookahead') or (
            c['action'] == 'observe' and c['args'].get('entity_types') == ['character']
        ):
            continue
        if previous and c['ok'] and previous['ok'] and 0 <= seconds(c['at']) - seconds(previous['response_at']) <= 2:
            if c['action'] == previous['action'] and c['action'] in ('inspect', 'scan', 'supply', 'platforms', 'science'):
                if c['args'] == previous['args']:
                    repeated.append(c['line'])
                elif c['action'] == 'inspect' and 'position' in c['args'] and 'position' in previous['args']:
                    rest = lambda a: {k: v for k, v in a.items() if k != 'position'}
                    if rest(c['args']) == rest(previous['args']):
                        batchable.append(c['line'])
        previous = c
    return {'identical_read_candidates': len(repeated), 'batchable_inspect_extra_calls': len(batchable),
            'examples': {'identical': repeated[:3], 'batchable': batchable[:3]}}


def reviewed_group(calls):
    """Candidate cause labels, not a claim that every refusal is a defect."""
    out = defaultdict(list)
    for c in calls:
        a, args = c['action'], c['args']
        m = (c.get('error') or {}).get('message', '')
        label = None
        if a == 'operator' and c['cut']:
            label = 'operator_clipping'
        elif c['ok']:
            continue
        elif a == 'equip' and 'incompatible with slot' in m:
            label = 'equip_default'
        elif a == 'queue_submit' and 'aboard platform' not in m:
            label = 'queue_diagnostics'
        elif a == 'trace' and 'surface, near and radius go with item' in m:
            label = 'trace_surface'
        elif a == 'labs' and 'unknown argument surface' in m:
            label = 'labs_surface'
        elif a == 'wait_until' and ('until must be one of' in m or 'unknown argument ticks' in m):
            label = 'wait_syntax'
        elif a == 'supply' and args.get('item', '').startswith('molten-'):
            label = 'supply_fluid'
        elif a == 'transfer' and 'items and to go with pick' in m:
            label = 'transfer_multiple_items'
        if label:
            out[label].append(c)
    return out


# Reviewed workarounds: endpoints were checked against the surrounding requests.
# Do not use the next same-named tool blindly: it often concerns different work.
# Overlap is merged, including four simultaneous Astra queue validations.
PAIRS = {
    'operator_clipping': {'astra': [(11865, 12067)]},
    'equip_default': {'opus': [(16437, 16515), (16439, 16517),
                              (16509, 16515), (16511, 16517)]},
    'queue_diagnostics': {'astra': [(6501, 6509), (6502, 6512),
                                    (6503, 6511), (6504, 6510), (7085, 7099),
                                    (12475, 12477), (7353, 7355)],
                          'grok': [(5735, 5737)]},
    'trace_surface': {'astra': [(4713, 4729), (12130, 12165), (13535, 13539)],
                      'sol': [(15993, 15995)]},
    'labs_surface': {'astra': [(5395, 5397)], 'luna': [(2189, 2191)]},
    'wait_syntax': {'luna': [(1759, 1763), (9859, 9863), (12371, 12375), (15021, 15029)],
                    'sol': [(12423, 12427)]},
    # The two other fluid reads were abandoned; no elapsed cost assigned.
    'supply_fluid': {'astra': [(5677, 5687)], 'muse': [(567, 571)]},
    'transfer_multiple_items': {'grok': [(5849, 5857)], 'sol': [(6379, 6383)]},
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--extract', help='agent:request-line:first-N-calls (max 30)')
    args = parser.parse_args()
    all_calls, coverage, terminal_counts, sleep_counts, read_signals = {}, {}, Counter(), Counter(), {}
    errors = defaultdict(lambda: {'count': 0, 'agents': set(), 'examples': []})
    groups = defaultdict(lambda: {'count': 0, 'agents': set(), 'intervals': defaultdict(list), 'evidence': []})
    for agent in AGENTS:
        calls, terminals, sleeps, stats = load(args.root / agent / 'journal.jsonl')
        all_calls[agent], coverage[agent] = calls, stats
        read_signals[agent] = read_candidates(calls)
        for c in calls:
            if c['ok']:
                continue
            k = c['action'] + ': ' + norm((c['error'] or {}).get('message', ''))
            r = errors[k]; r['count'] += 1; r['agents'].add(agent)
            if len(r['examples']) < 2:
                r['examples'].append(f'{agent}:{c["line"]}')
        for t in terminals:
            terminal_counts[f'{t.get("kind")}:{t.get("outcome")}'] += 1
        for s in sleeps:
            sleep_counts[f'{s["woke"]}' + (' (repeat)' if s['repeat'] else '')] += 1
        for label, members in reviewed_group(calls).items():
            groups[label]['count'] += len(members)
            groups[label]['agents'].add(agent)
        # A wait ended by a message counts once, however many polls saw it.
        for t in terminals:
            if t.get('kind') != 'wait_until' or t.get('outcome') not in ('told', 'mentioned'):
                continue
            g = groups['wait_messages']; g['count'] += 1; g['agents'].add(agent)
            starts = [c for c in calls if c['action'] == 'wait_until' and c['ok']
                      and c['line'] < t['line'] and (c.get('tick') or 0) <= t['tick']]
            if not starts:
                continue
            original = starts[-1]['args']
            signature = {k: v for k, v in original.items() if k not in ('timeout', 'wake_on_viewers')}
            for c in calls:
                if c['line'] <= t['line']:
                    continue
                gap = seconds(c['at']) - seconds(t['at'])
                if gap > 120:
                    break
                if c['action'] == 'wait_until' and c['ok'] and signature == {
                    k: v for k, v in c['args'].items() if k not in ('timeout', 'wake_on_viewers')
                }:
                    g['intervals'][agent].append((seconds(t['at']), seconds(c['response_at'])))
                    g['evidence'].append(f'{agent}:{t["line"]}->{c["line"]}')
                    break
    if args.extract:
        agent, start, count = args.extract.split(':')
        skip = {'status', 'sleep_check', 'observe', 'chat', 'lookahead'}
        rows = [c for c in all_calls[agent] if c['line'] >= int(start) and c['action'] not in skip]
        for c in rows[:min(30, int(count))]:
            print(json.dumps({**c, 'args': json.dumps(c['args'], ensure_ascii=False)[:650]}, ensure_ascii=False))
        return
    for label, agents in PAIRS.items():
        for agent, pairs in agents.items():
            by_line = {c['line']: c for c in all_calls[agent]}
            for start, end in pairs:
                if start not in by_line or end not in by_line:
                    continue
                a, b = by_line[start], by_line[end]
                assert b['ok'], (agent, end, 'reviewed recovery endpoint failed')
                groups[label]['intervals'][agent].append((seconds(a['response_at']), seconds(b['response_at'])))
                groups[label]['evidence'].append(f'{agent}:{start}->{end}')
    for g in groups.values():
        g['recovery_wall_s'] = round(sum(union_seconds(v) for v in g.pop('intervals').values()), 3)
        g['agents'] = sorted(g['agents'])
    for e in errors.values():
        e['agents'] = sorted(e['agents'])
    print(json.dumps(dict(window=[START, END], coverage=coverage,
                         ranked_reviewed=sorted(groups.items(), key=lambda kv: -kv[1]['recovery_wall_s']),
                         errors=sorted(errors.items(), key=lambda kv: -kv[1]['count']),
                         unique_terminal_outcomes=dict(terminal_counts), sleep_wakes=dict(sleep_counts),
                         read_candidates=read_signals),
                     indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
