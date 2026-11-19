#!/usr/bin/env python3
"""(mt309) Model bake-off sprints: solo arms (one agent per force) from a fixed save, a fixed score, burn per arm.

  sprint.py plan ARMS_FILE --per-run 3 [--runs N] [--prefix s1] [--out DIR]   rosters with rotated spawns + expected burn
  sprint.py score RUN [--minutes M]                                          the fixed score per force (SCORE_VERSION)
  sprint.py burn RUN                                                         tokens per arm from its CLI's own logs, in
                                                                             meter percent and plan dollars
  sprint.py run RUN ROSTER MINUTES [--execute]                               launch (tools/mt/launch.py, test mode, the
                                                                             r307 clean baseline), stop after MINUTES of
                                                                             played game time, score, burn, stop-mt.sh

ARMS_FILE: arm<TAB>kind<TAB>route<TAB>model<TAB>effort<TAB>label<TAB>harness (the roster's columns without the team).
The agents are never told the length: 2.1.24 runs are continuous (no deadline.txt, start-mt.sh POG_CONTINUOUS=1) and
nothing here writes into a workspace. Never a account B route. One private server at a time (run_state.CLAIM).
"""
import argparse
import bisect
import glob
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
CAL = json.loads((Path(__file__).with_name('burn_calibration.json')).read_text())
FORCES = ('green', 'yellow', 'blue')        # the r307 baseline's three spawns (seed 30744, ~1,300 tiles apart)
BASELINE = ROOT/'docs/reports/mt307/data/map/baseline-ready.zip'
BASELINE_SHA = '1859bda9bf77b23ec622aca2d6b13c72629a01150c330e195e582bc78009479a'
FORBIDDEN_ROUTES = ('claude-b', 'codex-b', 'gsopenrouter')
ROUTE_HOME = {'claude': '~/.claude-profiles/personal', 'claude-c': '~/.claude-profiles/account-c', 'codex': '~/.codex'}

# ---- the score (fixed before Stage 1; a change is a new SCORE_VERSION, never a re-score of old runs) --------------
SCORE_VERSION = 1
GATES = (  # name, test on (research set, entity counts, produced counts); 10 points each, plus up to 5 for speed
    ('power', lambda r, e, p: e.get('steam-engine', 0) + e.get('solar-panel', 0) >= 1),
    ('automation', lambda r, e, p: 'automation' in r),
    ('automated-red-science', lambda r, e, p: p.get('automation-science-pack', 0) >= 20 and e.get('lab', 0) >= 1 and
        sum(v for k, v in e.items() if k.startswith('assembling-machine')) >= 1),
    ('military', lambda r, e, p: 'military' in r),
    ('turret', lambda r, e, p: e.get('gun-turret', 0) >= 1),
    ('green-science', lambda r, e, p: 'logistic-science-pack' in r),
    ('pumpjack', lambda r, e, p: e.get('pumpjack', 0) >= 1),
    ('oil-processing', lambda r, e, p: 'oil-processing' in r),
)
SCIENCE = ('automation-science-pack', 'logistic-science-pack', 'military-science-pack', 'chemical-science-pack')
BASIC_AUTOMATION = 'automated-red-science'


def fields(score):
    """(research set, entity counts, produced counts) from one score row's 'score' (lists or {name: count})."""
    def d(v): return v if isinstance(v, dict) else {}
    return set(score.get('research_done') or []), d(score.get('entities')), d(score.get('produced'))


def score_rows(rows, start_tick, minutes):
    """The fixed score of one force over [start_tick, start_tick + minutes of game time]. rows: score rows
    ({'t', 'score': {tick, research_done, entities, produced}}) in time order."""
    end = start_tick + minutes * 3600
    rs = [r for r in rows if start_tick <= (r.get('score') or {}).get('tick', -1) <= end]
    out = dict(version=SCORE_VERSION, minutes=minutes, rows=len(rs), gates={}, points={})
    if not rs:
        out.update(total=0.0, basic_automation=False)
        return out
    for r in rs:
        tick = r['score']['tick']; R, E, P = fields(r['score'])
        for name, test in GATES:
            if name not in out['gates'] and test(R, E, P):
                out['gates'][name] = round((tick - start_tick) / 3600, 1)   # minutes after the start
    R, E, P = fields(rs[-1]['score'])
    last_tick = rs[-1]['score']['tick']
    # plates a minute over the sprint's last 30 minutes (the row nearest to 30 minutes before its last row)
    ticks = [r['score']['tick'] for r in rs]
    i = max(0, bisect.bisect_left(ticks, last_tick - 30 * 3600))
    _, _, P0 = fields(rs[i]['score']); span = max(1, (last_tick - ticks[i]) / 3600)
    plates = sum(P.get(k, 0) - P0.get(k, 0) for k in ('iron-plate', 'copper-plate')) + 5 * (P.get('steel-plate', 0) - P0.get('steel-plate', 0))
    rate = max(0.0, plates / span) if last_tick - ticks[i] >= 10 * 3600 else 0.0
    packs = sum(P.get(k, 0) for k in SCIENCE)
    pts = out['points']
    pts['gates'] = sum(10 + 5 * max(0.0, 1 - t / minutes) for t in out['gates'].values())
    pts['research'] = 2 * len(R)
    pts['plate_rate'] = 8 * math.log2(1 + rate / 30)
    pts['science'] = 4 * math.log2(1 + packs / 20)
    pts['drills'] = min(20, E.get('electric-mining-drill', 0))
    out.update(total=round(sum(pts.values()), 1), research=len(R), plates_per_min=round(rate, 1), packs=packs,
               basic_automation=BASIC_AUTOMATION in out['gates'], last_tick=last_tick)
    out['points'] = {k: round(v, 1) for k, v in pts.items()}
    return out


# ---- burn: tokens per arm from the CLI's own logs, then meter percent and plan dollars ----------------------------
def escaped(path):
    return str(path).replace('/', '-').replace('.', '-')


def arm_files(kind, route, ws):
    """Session files of one arm's workspace ws (absolute)."""
    ws = os.path.abspath(ws)   # the agent's cwd as the CLI saw it (no symlink resolution)
    if kind == 'claude':
        home = Path(os.path.expanduser(ROUTE_HOME.get(route, '~/.claude')))
        return sorted(glob.glob(str(home/'projects'/escaped(ws)/'**'/'*.jsonl'), recursive=True))
    if kind == 'codex':
        out = []
        for p in glob.glob(os.path.expanduser('~/.codex/sessions/*/*/*/rollout-*.jsonl')):
            if os.path.getmtime(p) < os.path.getmtime(ws) - 86400:
                continue
            with open(p, 'rb') as f:
                if ws.encode() in f.read(16384):
                    out.append(p)
        return sorted(out)
    native = Path(ws)/'.native-root'
    roots = [Path(ws)] + ([Path(native.read_text().strip())] if native.exists() else [])
    pattern = {'agy': 'transcript.jsonl', 'grok': 'unified.jsonl', 'muse': 'session.jsonl'}.get(kind)
    return sorted({p for r in roots if pattern for p in glob.glob(str(r/'**'/pattern), recursive=True)})


def arm_tokens(kind, files):
    sys.path.insert(0, str(ROOT/'tools'/'stream'))
    import tokens as T
    parse = {'claude': T.claude_line, 'codex': T.codex_line, 'grok': T.grok_line, 'agy': T.agy_line, 'muse': T.muse_line}[kind]
    acc = T.blank(); models = {}
    for p in files:
        st = {}
        with open(p, 'rb') as f:
            for line in f:
                try:
                    before = acc['input'] + acc['output']
                    parse(line, acc, st)
                except (ValueError, KeyError, TypeError, AttributeError):
                    continue
                if kind == 'claude' and acc['input'] + acc['output'] != before and b'"model"' in line:
                    m = json.loads(line).get('message', {}).get('model', '?')
                    models[m] = models.get(m, 0) + 1
    out = {k: acc[k] for k in ('input', 'cache_read', 'cache_write', 'output', 'reasoning', 'calls', 'compactions')}
    out.update(first=acc['first'], last=acc['last'], files=len(files), models=models)
    return out


def family(model):
    for f in ('opus', 'sonnet', 'haiku', 'fable'):
        if f in str(model):
            return f
    return None


def meter(kind, route, model, tok):
    """{window: percent} and plan dollars for one arm's tokens (None where Stage 0 has no token calibration)."""
    plan = CAL['plans'].get(route) or CAL['plans'].get(kind) or {}
    week_usd = plan.get('usd_month') and plan['usd_month'] / CAL['weeks_per_month']
    unc = max(0, tok['input'] - tok['cache_read'] - tok['cache_write'])
    if kind == 'claude':
        f = family(model) or 'opus'; p = CAL['claude']['list_prices'][f]
        usd = (unc * p[0] + tok['output'] * p[1] + tok['cache_write'] * p[2] + tok['cache_read'] * p[3]) / 1e6
        pct = {'weekly': usd * CAL['claude']['weekly_pct_per_list_usd']}
        if f == 'fable':
            pct['weekly_fable'] = usd * CAL['claude']['fable_window_pct_per_fable_list_usd']
        lo, hi = CAL['claude']['weekly_pct_per_list_usd_range']
        return dict(list_usd=round(usd, 2), pct={k: round(v, 3) for k, v in pct.items()},
                    pct_weekly_range=[round(usd * lo, 3), round(usd * hi, 3)],
                    plan_usd=week_usd and round(pct['weekly'] / 100 * week_usd, 3))
    if kind == 'codex':
        pct = (unc + tok['output']) / 1e6 * CAL['codex']['weekly_pct_per_mtok']
        return dict(pct={'weekly': round(pct, 3)}, plan_usd=week_usd and round(pct / 100 * week_usd, 3),
                    plan_usd_if={str(u): round(pct / 100 * u / CAL['weeks_per_month'], 3) for u in plan.get('usd_month_if', [])})
    return dict(pct=None, note='no token calibration for this CLI yet: use the account window deltas (ai-usage history)')


# ---- plan: arms into runs, spawns rotated --------------------------------------------------------------------------
def read_arms(path):
    arms = []
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        f = line.split('\t')
        assert len(f) == 7, f'{path}: 7 tab-separated fields: {line!r}'
        assert f[2] not in FORBIDDEN_ROUTES, f'account B route refused: {f[2]}'
        arms.append(dict(zip(('arm', 'kind', 'route', 'model', 'effort', 'label', 'harness'), f)))
    assert len({a['arm'] for a in arms}) == len(arms), 'arm names must be unique'
    return arms


def account(a):
    return a['route'] if a['route'] not in ('-', '') else a['kind']


def plan_runs(arms, per_run=3, runs=None):
    """Runs of per_run arms, each arm once per pass, no two arms of one account in a run where avoidable (a shared
    window confounds their burn), and each arm's spawn rotated from pass to pass: run r puts its slot s on
    FORCES[(s + r) % 3]."""
    n = runs or math.ceil(len(arms) / per_run)
    slots = [[] for _ in range(n)]
    for a in sorted(arms, key=lambda a: -sum(account(b) == account(a) for b in arms)):
        free = [i for i in range(n) if len(slots[i]) < per_run]
        assert free, 'more arms than slots'
        best = min(free, key=lambda i: (sum(account(b) == account(a) for b in slots[i]), len(slots[i]), i))
        slots[best].append(a)
    out = []
    for r, arms_r in enumerate(slots):
        out.append([dict(a, team=FORCES[(s + r) % len(FORCES)]) for s, a in enumerate(arms_r)])
    return out


def expected_burn(a, minutes):
    """Expected burn of one arm for a sprint, from the Stage 0 priors (text)."""
    h = minutes / 60; pri = CAL['per_seat_hour_priors']
    if a['kind'] == 'claude':
        rate = {'opus': (4.5, 8.2), 'sonnet': (0.5, 2.0), 'haiku': (0.05, 0.1), 'fable': (9.0, 16.4)}.get(family(a['model']) or 'opus')
        k = CAL['claude']['weekly_pct_per_list_usd']
        return f"{rate[0]*h*k:.2f}-{rate[1]*h*k:.2f}% of the weekly window (${rate[0]*h:.0f}-{rate[1]*h:.0f} list)"
    if a['kind'] == 'codex':
        return f"{0.9*h:.1f}-{1.45*h:.1f}% of the weekly window"
    if a['kind'] == 'agy':
        p = pri['agy_gemini_3.8_flash_high']
        note = '' if 'flash' in a['model'] else ' if it costs what Flash does (unmeasured: Gemini 4 may cost several times more)'
        return f"{p['gemini_weekly']*h:.1f}% of the Gemini week and {p['gemini_5h']*h:.0f}% of its 5-hour window{note}"
    if a['kind'] == 'grok':
        return f"{pri['grok_4.7_medium']['weekly']*h:.1f}-{pri['grok_4.7_low']['weekly']*h:.1f}% of the weekly window"
    if a['kind'] == 'muse':
        p = pri['muse_spark_1.3_low']
        return f"{p['weekly']*h:.1f}% of the week and {p['5h']*h:.0f}% of the 5-hour window"
    return 'unknown'


# ---- run -----------------------------------------------------------------------------------------------------------
def op_dir(run):
    return ROOT/'runs'/run/'op'


def read_scores(run, team):
    p = op_dir(run)/team/'scores.jsonl'
    rows = []
    if p.exists():
        for line in p.read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def start_tick(run):
    """The sprint's first played tick: sprint.json's, else the first score row's."""
    s = json.loads((op_dir(run)/'sprint.json').read_text()) if (op_dir(run)/'sprint.json').exists() else {}
    if s.get('start_tick') is not None:
        return s['start_tick']
    ticks = [r['score']['tick'] for t in FORCES for r in read_scores(run, t)[:1]]
    return min(ticks) if ticks else 0


def roster_rows(path):
    rows = []
    for line in Path(path).read_text().splitlines():
        if line.strip() and not line.startswith('#'):
            rows.append(dict(zip(('team', 'arm', 'kind', 'route', 'model', 'effort', 'label', 'harness'), line.split('\t'))))
    return rows


def cmd_score(a):
    roster = roster_rows(op_dir(a.run)/'teams.tsv')
    minutes = a.minutes or json.loads((op_dir(a.run)/'sprint.json').read_text())['minutes']
    st = start_tick(a.run)
    out = {r['arm']: dict(team=r['team'], **score_rows(read_scores(a.run, r['team']), st, minutes)) for r in roster}
    (op_dir(a.run)/'sprint-score.json').write_text(json.dumps(out, indent=1))
    for arm, s in out.items():
        print(f"{arm:12} {s['team']:6} score {s['total']:6.1f}  gates {','.join(s['gates']) or '-'}  research {s.get('research', 0)}"
              f"  plates/min {s.get('plates_per_min', 0)}  packs {s.get('packs', 0)}")
    return out


def cmd_burn(a):
    tree = Path((op_dir(a.run)/'launch-tree').read_text().strip()) if (op_dir(a.run)/'launch-tree').exists() else ROOT
    ws_map = json.loads((op_dir(a.run)/'workspaces.json').read_text()) if (op_dir(a.run)/'workspaces.json').exists() else {}
    out = {}
    for r in roster_rows(op_dir(a.run)/'teams.tsv'):
        ws = Path((ws_map.get(r['team']) or {}).get('dir') or tree/'runs'/a.run)/r['arm']
        files = arm_files(r['kind'], r['route'], ws)
        tok = arm_tokens(r['kind'], files)
        out[r['arm']] = dict(team=r['team'], kind=r['kind'], route=r['route'], model=r['model'], effort=r['effort'],
                             tokens=tok, meter=meter(r['kind'], r['route'], r['model'], tok))
    (op_dir(a.run)/'sprint-burn.json').write_text(json.dumps(out, indent=1))
    for arm, b in out.items():
        print(f"{arm:12} {b['kind']:6} calls {b['tokens']['calls']:5}  files {b['tokens']['files']}  meter {b['meter'].get('pct')}  plan$ {b['meter'].get('plan_usd')}")
    return out


def cmd_plan(a):
    arms = read_arms(a.arms_file)
    runs = plan_runs(arms, a.per_run, a.runs)
    out = Path(a.out or (ROOT/'runs'/'sprint-plans'/a.prefix)); out.mkdir(parents=True, exist_ok=True)
    for i, arms_r in enumerate(runs, 1):
        p = out/f'{a.prefix}r{i}.tsv'
        p.write_text('# team\tname\tkind\troute\tmodel\teffort\tlabel\tharness\n' + ''.join(
            '\t'.join((x['team'], x['arm'], x['kind'], x['route'], x['model'], x['effort'], x['label'], x['harness'])) + '\n'
            for x in arms_r))
        print(f'run {a.prefix}r{i} ({p}):')
        for x in arms_r:
            print(f"  {x['team']:6} {x['arm']:10} {x['label']:22} effort {x['effort']:6} expected {expected_burn(x, a.minutes)}")


def rcon_tick():
    out = subprocess.run([sys.executable, str(ROOT/'tools/pog.py'), '--world', 'imac2', 'rcon',
                          '/silent-command rcon.print(game.tick .. " " .. tostring(game.tick_paused))'],
                         capture_output=True, text=True, timeout=30).stdout.split()
    return int(out[0]), out[1] == 'true'


def cmd_run(a):
    roster = roster_rows(a.roster)
    assert 1 <= len(roster) <= 3 and len({r['team'] for r in roster}) == len(roster), 'one arm per force, at most three'
    assert all(r['route'] not in FORBIDDEN_ROUTES for r in roster), 'account B route refused'
    assert a.minutes <= 90, 'test runs are bounded to 90 minutes (tools/mt/launch.py)'
    env = dict(os.environ, POG_MT_FRESH='1', POG_MT_FRESH_SAVE=str(BASELINE), POG_SEED='30744', POG_GAME_TEST='0',
               POG_IDLE_NUDGE='0',
               POG_CLAIM_OWNER=os.environ.get('POG_CLAIM_OWNER', 'eng-mt309'))
    sha = subprocess.run(['shasum', '-a', '256', str(BASELINE)], capture_output=True, text=True).stdout.split()[0]
    assert sha == BASELINE_SHA, f'baseline changed: {sha}'
    launch = [sys.executable, str(ROOT/'tools/mt/launch.py'), a.run, str(a.minutes), '--roster', str(Path(a.roster).resolve())]
    if not a.execute:
        print('dry run:', ' '.join(launch)); subprocess.run(launch, env=env, check=True); return
    subprocess.run(launch + ['--execute'], env=env, check=True)
    op = op_dir(a.run)
    # The sprint starts at the first unpaused tick after every agent has started (start-mt.sh unpauses then).
    while True:
        tick, paused = rcon_tick()
        if not paused and (op/'panes.txt').exists():
            break
        time.sleep(10)
    (op/'sprint.json').write_text(json.dumps(dict(start_tick=tick, start_at=time.time(), minutes=a.minutes,
                                                  score_version=SCORE_VERSION, roster=roster), indent=1))
    while True:   # played game time, so a pause never shortens a sprint
        tick, paused = rcon_tick()
        if tick - json.loads((op/'sprint.json').read_text())['start_tick'] >= a.minutes * 3600:
            break
        time.sleep(20)
    subprocess.run([sys.executable, str(ROOT/'tools/pog.py'), '--world', 'imac2', 'rcon',
                    '/silent-command game.tick_paused = true'], check=True, timeout=30)
    time.sleep(130)  # one more score row per force (score-loop.sh, every 120 s), taken on the paused world
    s = json.loads((op/'sprint.json').read_text()); s.update(end_tick=tick, end_at=time.time())
    (op/'sprint.json').write_text(json.dumps(s, indent=1))
    cmd_score(argparse.Namespace(run=a.run, minutes=a.minutes))
    subprocess.run(['bash', str(ROOT/'tools/mt/stop-mt.sh'), a.run], env=env, check=False)
    cmd_burn(argparse.Namespace(run=a.run))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    q = sub.add_parser('plan'); q.add_argument('arms_file'); q.add_argument('--per-run', type=int, default=3)
    q.add_argument('--runs', type=int); q.add_argument('--prefix', default='s1'); q.add_argument('--out')
    q.add_argument('--minutes', type=int, default=90)
    q = sub.add_parser('score'); q.add_argument('run'); q.add_argument('--minutes', type=int)
    q = sub.add_parser('burn'); q.add_argument('run')
    q = sub.add_parser('run'); q.add_argument('run'); q.add_argument('roster'); q.add_argument('minutes', type=int)
    q.add_argument('--execute', action='store_true')
    a = p.parse_args(argv)
    return {'plan': cmd_plan, 'score': cmd_score, 'burn': cmd_burn, 'run': cmd_run}[a.cmd](a)


if __name__ == '__main__':
    main()
