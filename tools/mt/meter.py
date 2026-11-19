#!/usr/bin/env python3
"""(mt309) The subscription meter: per account and per seat, the share of each window used and its plan-dollar value.

  meter.py accounts                        every approved account's windows now (ai-usage brief), age and plan value
  meter.py run RUN [--json]                per seat over a run: account window deltas (ai-usage quota history from the
                                           run's start) and, for Claude and Codex, the seat's own tokens times the
                                           Stage 0 calibration (tools/mt/burn_calibration.json)

Plan value of a window share = share x the plan's monthly price / weeks a month (weekly windows); a 5-hour window is a
rate cap, reported as its share and the seats it would hold, not in dollars. An account another user draws on at the
same time (the engineers' Claude route, Nick's other projects) is marked shared: its delta is an upper bound, and the
seat's own tokens times the calibration is the figure to use. Unknown or stale readings stay unknown, never 0%.
Read only: no model calls, no quota refresh (ai-usage's own publisher keeps the brief fresh).
"""
import argparse
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path.home()/'.cache/ai-usage'
CAL = json.loads(Path(__file__).with_name('burn_calibration.json').read_text())
APPROVED = {'claude_personal': 'claude', 'claude_account_c': 'claude-c', 'codex_account_a': 'codex', 'grok_personal': 'grok',
            'agy_local': 'agy', 'muse_local': 'muse'}        # never a account B profile
ROUTE_PROFILE = {v: k for k, v in APPROVED.items()}
FRESH = 900


def week_usd(route):
    usd = (CAL['plans'].get(route) or {}).get('usd_month')
    return usd / CAL['weeks_per_month'] if usd else None


def accounts(brief=None, now=None):
    b = brief if brief is not None else json.loads((CACHE/'agent-brief.json').read_text())
    now = now or time.time()
    out = {}
    for p in b.get('profiles', []):
        route = APPROVED.get(p.get('id'))
        if not route:
            continue
        age = now - (p.get('observed_at') or 0)
        fresh = bool(p.get('available')) and not p.get('stale') and 0 <= age <= FRESH
        wins = {}
        for w in p.get('windows') or []:
            weekly = w.get('duration_minutes') == 10080 and 'scoped' not in w['key']   # Fable's sub-cap: share only
            wins[w['key']] = dict(label=w.get('label'), percent=w.get('percent') if fresh else None,
                                  resets_at=w.get('resets_at'), weekly=weekly,
                                  used_usd=(round(w['percent'] / 100 * week_usd(route), 2)
                                            if fresh and weekly and week_usd(route) and w.get('percent') is not None else None))
        out[route] = dict(profile=p['id'], fresh=fresh, age_s=round(age), windows=wins,
                          plan=(CAL['plans'].get(route) or {}).get('plan'), note=None if fresh else (p.get('status_note') or 'stale'))
    return out


def history(profile, since, until=None):
    """{window key: [(at, percent, resets_at)]} from ai-usage's quota history."""
    snaps = json.loads((CACHE/'quota-history.json').read_text()).get('snapshots', [])
    out = {}
    for s in snaps:
        if s.get('profile') != profile or not since <= s.get('at', 0) <= (until or 9e9):
            continue
        for w in s.get('windows') or []:
            if w.get('percent') is not None:
                out.setdefault(w['key'], []).append((s['at'], w['percent'], w.get('resets_at')))
    return {k: sorted(v) for k, v in out.items()}


def delta(series):
    """Percent points used over a series; a reset (resets_at moves on) starts a new period and is added, never
    subtracted. None when fewer than two readings."""
    if len(series) < 2:
        return None
    total, prev = 0.0, series[0]
    for cur in series[1:]:
        if cur[2] and prev[2] and abs(cur[2] - prev[2]) > 3600:      # a new period
            total += cur[1]
        else:
            total += max(0.0, cur[1] - prev[1])
        prev = cur
    return round(total, 1)


def run_meter(run):
    op = ROOT/'runs'/run/'op'
    sprint = json.loads((op/'sprint.json').read_text()) if (op/'sprint.json').exists() else {}
    since = sprint.get('start_at') or (op/'teams.tsv').stat().st_mtime
    until = sprint.get('end_at')
    burn = json.loads((op/'sprint-burn.json').read_text()) if (op/'sprint-burn.json').exists() else {}
    seats = {}
    for line in (op/'teams.tsv').read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        team, name, kind, route, model, effort, label, harness = line.split('\t')
        seats[name] = dict(team=team, kind=kind, route=route if route not in ('-', '') else kind, model=model,
                           effort=effort, tokens_meter=(burn.get(name) or {}).get('meter'))
    by_route = {}
    for n, s in seats.items():
        by_route.setdefault(s['route'], []).append(n)
    acc = {}
    for route, names in by_route.items():
        prof = ROUTE_PROFILE.get(route)
        if not prof:
            continue
        d = {k: delta(v) for k, v in history(prof, since, until).items()}
        acc[route] = dict(seats=names, window_delta=d,
                          shared=route in ('claude', 'claude-c') or len(names) > 1,
                          note='other users draw on this account: the delta is an upper bound' if route in ('claude', 'claude-c') else
                               ('split between this run\'s seats on it' if len(names) > 1 else None))
        for n in names:
            seats[n]['account_delta'] = {k: (None if v is None else round(v / len(names), 2)) for k, v in d.items()}
            wk = next((v for k, v in d.items() if v is not None and ('10080' in k or 'weekly' in k.lower()) and 'fable' not in k.lower()), None)
            seats[n]['plan_usd_from_delta'] = round(wk / len(names) / 100 * week_usd(route), 3) if wk is not None and week_usd(route) else None
    out = dict(run=run, since=since, until=until, hours=round(((until or time.time()) - since) / 3600, 2), seats=seats, accounts=acc)
    (op/'meter.json').write_text(json.dumps(out, indent=1))
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('accounts')
    q = sub.add_parser('run'); q.add_argument('run'); q.add_argument('--json', action='store_true')
    a = p.parse_args(argv)
    if a.cmd == 'accounts':
        for route, r in accounts().items():
            ws = '; '.join(f"{w['label']} {w['percent'] if w['percent'] is not None else '?'}%"
                           + (f" (${w['used_usd']})" if w['used_usd'] is not None else '') for w in r['windows'].values())
            print(f"{route:9} {'fresh' if r['fresh'] else 'UNKNOWN':7} {r['age_s']:>5}s  {ws}  [{r['plan']}]")
        return
    out = run_meter(a.run)
    if a.json:
        json.dump(out, sys.stdout, indent=1); return
    print(f"run {a.run}: {out['hours']} h")
    for n, s in out['seats'].items():
        print(f"  {n:12} {s['route']:8} tokens->meter {(s['tokens_meter'] or {}).get('pct')}  account delta {s.get('account_delta')}"
              f"  plan$ {(s['tokens_meter'] or {}).get('plan_usd') or s.get('plan_usd_from_delta')}")


if __name__ == '__main__':
    main()
