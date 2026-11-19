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


POG_CODEX = Path(os.environ.get('POG_CODEX_HOME') or Path.home()/'.pog-codex'/'home')


def arm_files(kind, route, ws, extra=()):
    """Session files of one arm's workspace ws (absolute); extra: more session folders (a run's archived ones)."""
    ws = os.path.abspath(ws)   # the agent's cwd as the CLI saw it (no symlink resolution)
    if kind == 'claude':
        home = Path(os.path.expanduser(ROUTE_HOME.get(route, '~/.claude')))
        return sorted(glob.glob(str(home/'projects'/escaped(ws)/'**'/'*.jsonl'), recursive=True))
    if kind == 'codex':
        out = []
        found = glob.glob(os.path.expanduser('~/.codex/sessions/*/*/*/rollout-*.jsonl'))
        for base in (POG_CODEX/'sessions', *extra):
            found += glob.glob(str(Path(base)/'**'/'rollout-*.jsonl'), recursive=True)
        for p in found:
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
    st = json.loads((op_dir(a.run)/'sprint.json').read_text()) if (op_dir(a.run)/'sprint.json').exists() else {}
    minutes = a.minutes or st.get('played_minutes') or st['minutes']
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
        files = arm_files(r['kind'], r['route'], ws, extra=[op_dir(a.run)/'codex-sessions'])
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


def rcon_tick(patience=600):
    """(tick, paused). (s1r1 12:47) chonk lost IPv4 to imac.local for a moment ("No route to host") and one failed
    read ended the runner: a read is retried for PATIENCE seconds before it fails."""
    t0, err = time.time(), None
    while time.time() - t0 < patience:
        try:
            r = subprocess.run([sys.executable, str(ROOT/'tools/pog.py'), '--world', 'imac2', 'rcon',
                                '/silent-command rcon.print(game.tick .. " " .. tostring(game.tick_paused))'],
                               capture_output=True, text=True, timeout=30)
            out = r.stdout.split()
            if len(out) >= 2:
                return int(out[0]), out[1] == 'true'
            err = (r.stderr.strip().splitlines() or ['no output'])[-1]
        except (subprocess.TimeoutExpired, ValueError) as e:
            err = repr(e)
        print(time.strftime('%H:%M:%S'), 'tick read failed, retrying:', err, flush=True)
        time.sleep(15)
    raise RuntimeError(f'no tick read for {patience} s: {err}')


def rcon_set_paused(paused):
    for i in range(20):
        r = subprocess.run([sys.executable, str(ROOT/'tools/pog.py'), '--world', 'imac2', 'rcon',
                            f'/silent-command game.tick_paused = {"true" if paused else "false"}'], capture_output=True, timeout=30)
        if r.returncode == 0:
            return
        time.sleep(15)
    raise RuntimeError('pause/unpause failed for 5 minutes')


def rcon_route():
    """How this Mac reaches imac2's RCON: directly when Python can open a connection to the iMac, else through
    tools/mt/rcon_tunnel.sh (ssh, 127.0.0.1:27475). (s1r1 12:47 Nov 19) chonk began failing, first as macOS refusing
    Python's connections to imac.local (EHOSTUNREACH) while Apple's ssh still connected; it crashed at 13:25. The probe
    is the iMac's ssh port, which answers while Factorio is down. pog.py and fh_broker.py follow IMAC_RCON_HOST, which
    this sets for the runner and everything it starts."""
    import socket
    sys.path.insert(0, str(ROOT/'tools')); import pog
    try:
        pog.connect('imac.local', 22, 5).close()
        os.environ.pop('IMAC_RCON_HOST', None)
        return 'direct'
    except OSError as e:
        direct_err = e
    try:
        socket.create_connection(('127.0.0.1', 27475), 3).close()
    except OSError:
        raise SystemExit(f'Python cannot reach imac.local ({direct_err}) and no RCON tunnel listens: '
                         'nohup tools/mt/rcon_tunnel.sh > runs/rcon-tunnel.log 2>&1 &')
    os.environ['IMAC_RCON_HOST'] = '127.0.0.1'
    return 'tunnel'


def rcon_connect_s(n=5):
    """Median seconds for a new RCON connection to imac2 by the route in use (mt308: ~0.01 s after the IPv4 fix)."""
    import statistics
    sys.path.insert(0, str(ROOT/'tools')); import pog
    host = os.environ.get('IMAC_RCON_HOST') or 'imac.local'
    out = []
    for _ in range(n):
        t = time.time(); pog.connect(host, 27475, 5).close(); out.append(time.time() - t)
    return round(statistics.median(out), 4)

# (s1r1c) the 2.1.24 server pins tools/mt/launch.py sets for start-mt.sh. stop-mt.sh (imac_mt.sh stop, imac_cam.py
# stop) without them looks in the default /Users/owner/pog-mt, finds no server.pid, prints "not running" and leaves
# imac2's server and camera running.
MT_PINS = dict(MT_DIR='/Users/owner/pog-mt21', MT_FACTORIO_APP='/Users/owner/code/factorio-mac-2.1.24/factorio.app',
               MT_EXPECT_VERSION='2.1.24', MT_RCON_PORT='27475', MT_GAME_PORT='34475',
               MT_MODS_FILE=str(ROOT/'agent/mt/mods-2.1.24.tsv'), POG_KB='space-age-2.1.24')


def stop_run(run, env):
    """stop-mt.sh with the pins, then the server must read not running (imac_mt.sh status)."""
    env = dict(env, **MT_PINS, POG_STOP_WORLD='1')
    subprocess.run(['bash', str(ROOT/'tools/mt/stop-mt.sh'), run], env=env, check=False)
    st = subprocess.run(['bash', str(ROOT/'tools/mt/imac_mt.sh'), 'status'], env=env, capture_output=True, text=True).stdout.strip()
    if not st.startswith('not running'):
        subprocess.run(['bash', str(ROOT/'tools/mt/imac_mt.sh'), 'stop'], env=env, check=False)
        st = subprocess.run(['bash', str(ROOT/'tools/mt/imac_mt.sh'), 'status'], env=env, capture_output=True, text=True).stdout.strip()
    if not st.startswith('not running'):
        wake(f"{run}: imac2 server still running after stop-mt.sh: {st}")
        raise SystemExit(f'{run}: server still running: {st}')
    return st


WAKE = Path('/Users/owner/code/pog-operator/mt309-wake.jsonl')
EXPECT = {'opus': 'claude-opus-5-5', 'sonnet': 'claude-sonnet-5-5', 'haiku': 'claude-haiku-5-5', 'fable': 'claude-fable-5-2'}


def wake(text):
    with WAKE.open('a') as f:
        f.write(json.dumps({'t': int(time.time()), 'from': 'eng-mt309', 'text': text}) + '\n')


def alive(pid):
    try:
        os.kill(pid, 0); return True
    except OSError:
        return False


def meter_check(op, sprint_state):
    """One 15-minute check: every approved account's windows into op/meter-checks.jsonl; the first time a window
    passes 80% is noted in sprint.json (the run goes on: a window that runs out is a result)."""
    import meter as M
    try:
        acc = M.accounts()
    except (OSError, ValueError) as e:
        acc = {'error': str(e)}
    with (op/'meter-checks.jsonl').open('a') as f:
        f.write(json.dumps({'at': time.time(), 'accounts': acc}) + '\n')
    for route, r in acc.items() if isinstance(acc, dict) else []:
        for key, w in (r.get('windows') or {}).items() if isinstance(r, dict) else []:
            if (w.get('percent') or 0) >= 80 and f'{route}:{key}' not in sprint_state.setdefault('over_80', {}):
                sprint_state['over_80'][f'{route}:{key}'] = time.time()


def served_models(op, roster):
    """{arm: {model: calls}} for the Claude arms, from their transcripts; wakes on a model other than the one asked."""
    ws = json.loads((op/'workspaces.json').read_text()) if (op/'workspaces.json').exists() else {}
    out, bad = {}, []
    for r in roster:
        if r['kind'] != 'claude':
            continue
        d = Path((ws.get(r['team']) or {}).get('dir', ''))/r['arm']
        out[r['arm']] = arm_tokens('claude', arm_files('claude', r['route'], d))['models']
        want = EXPECT.get(family(r['model']) or '')
        if out[r['arm']] and want and set(out[r['arm']]) - {want, '<synthetic>'}:
            bad.append(f"{r['arm']} asked {r['model']} served {out[r['arm']]}")
    if bad:
        wake(f"{op.parent.name}: served model differs: {'; '.join(bad)} (run continues)")
    return out


def summary(run):
    sc = json.loads((op_dir(run)/'sprint-score.json').read_text())
    bu = json.loads((op_dir(run)/'sprint-burn.json').read_text()) if (op_dir(run)/'sprint-burn.json').exists() else {}
    me = json.loads((op_dir(run)/'meter.json').read_text()) if (op_dir(run)/'meter.json').exists() else {}
    st = json.loads((op_dir(run)/'sprint.json').read_text())
    parts = []
    for arm, s in sc.items():
        b = (bu.get(arm) or {}).get('meter') or {}
        acct = (me.get('seats', {}).get(arm) or {}).get('account_delta')
        gates = ', '.join(f'{g} {m}m' for g, m in s['gates'].items()) or 'no gate'
        parts.append(f"{arm} ({s['team']}): score {s['total']} [{gates}; research {s.get('research', 0)}, plates/min "
                     f"{s.get('plates_per_min', 0)}]; burn tokens->{b.get('pct')} plan ${b.get('plan_usd')}; account delta {acct}")
    over = st.get('over_80') or {}
    return (f"{run} done: " + ' | '.join(parts) + (f" | windows over 80%: {over}" if over else '')
            + f" | details runs/{run}/op/sprint-*.json")


def cmd_run(a):
    roster = roster_rows(a.roster)
    assert 1 <= len(roster) <= 3 and len({r['team'] for r in roster}) == len(roster), 'one arm per force, at most three'
    assert all(r['route'] not in FORBIDDEN_ROUTES for r in roster), 'account B route refused'
    assert sum(r['kind'] == 'agy' and 'gemini-4' in r['model'] for r in roster) <= 1, 'at most one Gemini 4 arm a run'
    assert a.minutes <= 90, 'test runs are bounded to 90 minutes (tools/mt/launch.py)'
    # Paused start: the world waits while the agents launch, and the sprint begins for all of them at once.
    route = rcon_route()
    env = dict(os.environ, POG_MT_FRESH='1', POG_MT_FRESH_SAVE=str(BASELINE), POG_SEED='30744', POG_GAME_TEST='0',
               POG_IDLE_NUDGE='0', POG_MT_PAUSED_START='1', POG_STOP_WORLD='1',
               POG_CLAIM_OWNER=os.environ.get('POG_CLAIM_OWNER', 'eng-mt309'))
    sha = subprocess.run(['shasum', '-a', '256', str(BASELINE)], capture_output=True, text=True).stdout.split()[0]
    assert sha == BASELINE_SHA, f'baseline changed: {sha}'
    launch = [sys.executable, str(ROOT/'tools/mt/launch.py'), a.run, str(a.minutes), '--roster', str(Path(a.roster).resolve())]
    if not a.execute:
        print('dry run:', ' '.join(launch)); subprocess.run(launch, env=env, check=True); return
    subprocess.run(launch + ['--execute'], env=env, check=True)
    op = op_dir(a.run)
    pid = json.loads((op/'launch-process.json').read_text())['pid']
    t0 = time.time()
    while alive(pid):                       # start-mt.sh returns once every agent is launched and helpers run
        assert time.time() - t0 < 1800, 'start-mt.sh still running after 30 minutes'
        time.sleep(10)
    log = (op/'start.log').read_text() if (op/'start.log').exists() else ''
    if (op/'not-started.txt').exists() or 'refusing' in log:
        wake(f"{a.run}: start failed or an agent did not start; see runs/{a.run}/op (world left paused)")
        raise SystemExit(f'{a.run}: start failed')
    rcon_set_paused(False)
    tick, paused = rcon_tick()
    state = dict(start_tick=tick, start_at=time.time(), minutes=a.minutes, score_version=SCORE_VERSION, roster=roster)
    state.update(rcon_route=route, rcon_connect_s=rcon_connect_s())
    (op/'sprint.json').write_text(json.dumps(state, indent=1))
    meter_check(op, state)
    supervise(a.run, op, state, env, time.time() + 900)


def cmd_resume(a):
    """Re-enter a running sprint's supervision from its sprint.json (the runner process died, the world did not)."""
    op = op_dir(a.run)
    state = json.loads((op/'sprint.json').read_text())
    state.setdefault('resumed_at', []).append(time.time())
    rcon_route()
    env = dict(os.environ, POG_STOP_WORLD='1', POG_CLAIM_OWNER=os.environ.get('POG_CLAIM_OWNER', 'eng-mt309'))
    checks = [json.loads(l)['at'] for l in (op/'meter-checks.jsonl').read_text().splitlines()] if (op/'meter-checks.jsonl').exists() else []
    nxt = (max(checks) + 900) if checks else time.time()
    supervise(a.run, op, state, env, max(time.time(), nxt))


def supervise(run, op, state, env, next_check):
    roster, minutes = state['roster'], state['minutes']
    a = argparse.Namespace(run=run, minutes=minutes)
    save = lambda: (op/'sprint.json').write_text(json.dumps(state, indent=1))
    save(); checked_models = 'served_models' in state
    while True:   # played game time, so a pause never shortens a sprint
        tick, paused = rcon_tick()
        # full_run.py's single shift (2.1.24 runs are continuous) stops the agents MINUTES after its init, a few
        # seconds before the unpause: the sprint ends there or at MINUTES of played game time, whichever is first.
        done = (json.loads((op/'full-run.json').read_text()).get('phase') if (op/'full-run.json').exists() else None) == 'shifts-complete'
        if done or tick - state['start_tick'] >= a.minutes * 3600:
            state['ended_by'] = 'shift end' if done else 'game time'
            break
        if not checked_models and time.time() - state['start_at'] > 600:
            state['served_models'] = served_models(op, roster); checked_models = True; save()
        if time.time() >= next_check:
            meter_check(op, state); save(); next_check += 900
        time.sleep(20)
    rcon_set_paused(True)
    time.sleep(130)  # one more score row per force (score-loop.sh, every 120 s), taken on the paused world
    meter_check(op, state)
    played = min(a.minutes, (tick - state['start_tick']) / 3600)
    state.update(end_tick=tick, end_at=time.time(), played_minutes=round(played, 2)); save()
    cmd_score(argparse.Namespace(run=a.run, minutes=played))
    state['stopped'] = stop_run(a.run, env); save()
    cmd_burn(argparse.Namespace(run=a.run))
    if any(r['kind'] == 'codex' for r in roster):   # a later arm never reads this run's Codex transcripts
        sys.path.insert(0, str(ROOT/'tools')); import codex_pog_home
        state['codex_sessions'] = codex_pog_home.archive(POG_CODEX, op/'codex-sessions'); save()
    import meter as M
    time.sleep(300)  # ai-usage refreshes every ~5 minutes: one reading after the end
    M.run_meter(a.run)
    wake(summary(a.run))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    q = sub.add_parser('plan'); q.add_argument('arms_file'); q.add_argument('--per-run', type=int, default=3)
    q.add_argument('--runs', type=int); q.add_argument('--prefix', default='s1'); q.add_argument('--out')
    q.add_argument('--minutes', type=int, default=90)
    q = sub.add_parser('score'); q.add_argument('run'); q.add_argument('--minutes', type=float)
    q = sub.add_parser('burn'); q.add_argument('run')
    q = sub.add_parser('run'); q.add_argument('run'); q.add_argument('roster'); q.add_argument('minutes', type=int)
    q.add_argument('--execute', action='store_true')
    q = sub.add_parser('resume'); q.add_argument('run')
    a = p.parse_args(argv)
    return {'plan': cmd_plan, 'score': cmd_score, 'burn': cmd_burn, 'run': cmd_run, 'resume': cmd_resume}[a.cmd](a)


if __name__ == '__main__':
    main()
