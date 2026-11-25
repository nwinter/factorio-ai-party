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
import collections
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
# (mt309 Stage 2) the prepared mid-game save (tools/mt/stage2_save.py), its SHA-256 beside it
STAGE2_SAVE = ROOT/'docs/reports/mt309/data/stage2-ready.zip'
STAGE2_SPAWN = dict(green='near', yellow='far', blue='far')   # nearest base building to its nest: 90, 115, 112 tiles
# (note-mt309-t) the three-team contact map (stage2_save.py --map contact): every nest 122 tiles from its base
CONTACT_SAVE = ROOT/'docs/reports/mt309/data/contact-ready.zip'
# (note-mt309-y) ct2's two builds: starts 750 apart, and the same with each team's corridor fields short of one ore
SAVES = {'stage2': STAGE2_SAVE, 'contact': CONTACT_SAVE, 'ct2': ROOT/'docs/reports/mt309/data/ct2-ready.zip',
         'ct2-shortage': ROOT/'docs/reports/mt309/data/ct2-shortage-ready.zip',
         'ct3': ROOT/'docs/reports/mt309/data/ct3-ready.zip'}     # (note-mt309-z7) two teams, each with the other's ore
CONTACT_SAVES = ('contact', 'ct2', 'ct2-shortage', 'ct3')     # stage2_save.py --map names the same maps
CONTACT_MINUTES = 240
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


def arm_files(kind, route, ws, extra=(), start=None):
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
    # (s1r1d) agy, Grok and Muse: tools/stream/tokens.py's Finder, which knows each CLI's layout (agy's conversations
    # in ~/.gemini/antigravity-cli/brain, one every ~5 min, placed by the run they name; Grok's .grok-home in the
    # workspace; Muse's sessions by cwd). The glob it replaces skipped hidden folders (.grok-home) and searched the
    # workspace for agy's and Muse's logs, which live in the CLI's home: tokens read None for every such arm.
    sys.path.insert(0, str(ROOT/'tools'/'stream'))
    import tokens as T
    ws = Path(ws)
    start = start if start is not None else os.path.getmtime(ws)
    found = T.Finder(str(ws.parent), {ws.name: kind}, start=start, end=time.time()).files()
    native = ws/'.native-root'          # a scoped CLI's private home, while it still exists
    if native.exists() and Path(native.read_text().strip()).is_dir():
        pattern = {'agy': 'transcript.jsonl', 'grok': 'unified.jsonl', 'muse': 'session.jsonl'}[kind]
        found.update({p: None for p in glob.glob(str(Path(native.read_text().strip())/'**'/pattern), recursive=True,
                                                 include_hidden=True)})
    return sorted(found)


def arm_tokens(kind, files):
    sys.path.insert(0, str(ROOT/'tools'/'stream'))
    import tokens as T
    parse = {'claude': T.claude_line, 'codex': T.codex_line, 'grok': T.grok_line, 'agy': T.agy_line, 'muse': T.muse_line}[kind]
    acc = T.blank(); models = {}
    for p in files:
        st = {}
        fn = T.grok_updates_line if kind == 'grok' and p.endswith('updates.jsonl') else parse
        with open(p, 'rb') as f:
            for line in f:
                try:
                    before = acc['input'] + acc['output']
                    fn(line, acc, st)
                except (ValueError, KeyError, TypeError, AttributeError):
                    continue
                if kind == 'claude' and acc['input'] + acc['output'] != before and b'"model"' in line:
                    m = json.loads(line).get('message', {}).get('model', '?')
                    models[m] = models.get(m, 0) + 1
    out = {k: acc[k] for k in ('input', 'cache_read', 'cache_write', 'output', 'reasoning', 'calls', 'compactions')}
    out.update(first=acc['first'], last=acc['last'], files=len(files), models=models)
    if kind == 'codex':     # (note-mt309-t) sub-agent threads: their rollouts are among files, so in the sums above
        out['subagents'] = len(codex_subagent_files(files))
    return out


def codex_subagent_files(files):
    """The Codex rollouts among files that a spawn_agent call started (session_meta thread_source subagent, s1ax)."""
    out = []
    for p in files:
        try:
            with open(p) as f:
                meta = json.loads(f.readline()).get('payload') or {}
        except (OSError, ValueError):
            continue
        if meta.get('thread_source') == 'subagent':
            out.append(p)
    return out


def codex_subagents(op, state):
    """(note-mt309-t: spawn_agent stays allowed) Each Codex arm's sub-agent rollouts; a new one is logged in
    sprint.json's subagents and woken once. Their tokens count in the arm's burn (cmd_burn reads every rollout of the
    arm's workspace, sub-agents' too). Returns {arm: count}."""
    ws = json.loads((op/'workspaces.json').read_text()) if (op/'workspaces.json').exists() else {}
    seen = state.setdefault('subagents', {})
    out = {}
    for r in state.get('roster', []):
        if r['kind'] != 'codex':
            continue
        d = Path((ws.get(r['team']) or {}).get('dir', ''))/r['arm']
        files = codex_subagent_files(arm_files('codex', r['route'], d, extra=[op/'codex-sessions']))
        new = [p for p in files if p not in seen.get(r['arm'], [])]
        if new:
            seen.setdefault(r['arm'], []).extend(new)
            wake(f"{op.parent.name}: {r['arm']} started {len(new)} Codex sub-agent(s) ({len(seen[r['arm']])} in all); "
                 f"allowed, their tokens count in its burn")
        out[r['arm']] = len(seen.get(r['arm'], []))
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
    fit = CAL.get('agy', {}).get('weekly_pct_per_m_output', {})
    key = next((k for k in fit if kind == 'agy' and model.startswith(k)), None)
    if key:      # (note-mt309-y) agy's Gemini week from output tokens (Neon's fit)
        lo, hi = CAL['agy']['weekly_pct_per_m_output_range'][key]
        return dict(pct={'gemini_weekly': round(tok['output'] / 1e6 * fit[key], 3)},
                    pct_range=[round(tok['output'] / 1e6 * lo, 3), round(tok['output'] / 1e6 * hi, 3)])
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
    st = json.loads((op_dir(a.run)/'sprint.json').read_text()) if (op_dir(a.run)/'sprint.json').exists() else {}
    start = st.get('start_at')
    out = {}
    for r in roster_rows(op_dir(a.run)/'teams.tsv'):
        ws = Path((ws_map.get(r['team']) or {}).get('dir') or tree/'runs'/a.run)/r['arm']
        files = arm_files(r['kind'], r['route'], ws, extra=[op_dir(a.run)/'codex-sessions'], start=start)
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


# (s1r1d) An agent that ends its turn is never asked to go on in a sprint: supervise.sh needs a deadline.txt that
# continuous runs do not write ("deadline reached after 0 nudges" at launch), and full_run.py's watch, whose
# idle-prompt does this in full runs, does not start (its init refuses Claude arms). Grok ended its turn at game
# minute 46 of s1r1d ("research is running in a stable state") and sat idle for 44 minutes. The sprint applies
# full_run's rule to every arm alike, with its text minus "with your teammate" (sprint arms play alone), plus one
# rule for panes whose status never reads idle (Muse): 10 minutes without a game request and no busy marker.
NUDGE_S = 20      # seconds after a turn ends before the idle prompt (sprint run --nudge-s; note-mt309-p; 20 s the
                  # default from note-mt309-t, every arm: Astra's waits fell from 47.8 to 15.2 min of 90)
# (note-mt309-z7) A sprint's idle arms get only idle_prompts' prompt: full_run's watch, which launch.py starts for
# every run, prompts none (POG_PANE_PROMPT), and its game-tell nudge is off (POG_IDLE_NUDGE). In ct2 both prompted
# Astra: 16 of the watch's 34 prompts came within 15 s of one of the sprint's 47.
SPRINT_PROMPTS = dict(POG_IDLE_NUDGE='0', POG_PANE_PROMPT='0')
SPRINT_NUDGE = ('Operator (automatic): check your own status, tells, board and notes.md. Keep building toward the '
                'goal. If blocked, explain the blocker once and choose another useful task. Keep your current '
                'identity and update your notes.')


def idle_prompts(op, state, panes=None, now=None):
    """Prompt each arm that is idle: herdr reads idle/done (or Grok's native end_turn at an empty prompt), its journal
    unchanged 120 s and no prompt in 180 s; or no journal change in 600 s with no busy marker on its screen."""
    sys.path.insert(0, str(ROOT/'tools'))
    import full_run, pane_resume
    now = now or time.time()
    panes = panes or pane_resume.HerdrPanes()
    ws = json.loads((op/'workspaces.json').read_text())
    pane_of = {l.split()[1]: l.split()[2] for l in (op/'panes.txt').read_text().splitlines() if len(l.split()) == 4}
    log = state.setdefault('idle_prompts', {})
    for r in state['roster']:
        pane = pane_of.get(r['arm'])
        if not pane:
            continue
        folder = Path(ws[r['team']]['dir'])
        journal = folder/r['arm']/'journal.jsonl'
        quiet = now - (journal.stat().st_mtime if journal.exists() else state['start_at'])
        last = max([state['start_at']] + [x['at'] for x in log.get(r['arm'], [])])
        # (note-mt309-p) the wait after a turn ends is the run's nudge_s (default 20 s); the gap between two prompts
        # to one arm scales with it (180 s at 120, 30 s at 20), so a prompt is never sent twice before its turn starts
        wait = state.get('nudge_s', NUDGE_S)
        if now - last < wait * 1.5 or quiet < wait:
            continue
        status = panes.status(pane)
        screen = panes.read(pane)
        a = dict(kind=r['kind'], folder=str(folder), name=r['arm'], started=state['start_at'], nudge_s=wait)
        native = status == 'unknown' and full_run.native_idle(a, screen, now)
        busy = bool(pane_resume.BUSY.search('\n'.join(screen.splitlines()[-25:])))
        why = ('status ' + status) if status in ('idle', 'done') else f"{r['kind']} end_turn" if native else \
              'silent 600 s' if quiet >= 600 and not busy else None
        if not why:
            continue
        how, ok, detail = panes.prompt(pane, SPRINT_NUDGE)
        row = dict(at=now, why=why, quiet_s=round(quiet), how=how, ok=ok, detail=detail[:120],
                   first_failed=(lambda v: v if isinstance(v, str) else None)(getattr(panes, 'last_failed', None)))   # (note-mt309-x) the attempt before the one that worked
        log.setdefault(r['arm'], []).append(row)
        with (op/'idle-prompts.jsonl').open('a') as f:
            f.write(json.dumps(dict(arm=r['arm'], **row)) + '\n')
        print(time.strftime('%H:%M:%S'), 'idle prompt', r['arm'], why, how, ok, flush=True)


def cmd_idle_watch(a):
    """idle_prompts for a sprint whose runner started before them (s1r2), until its world pauses at the end."""
    op = op_dir(a.run)
    state = json.loads((op/'sprint.json').read_text())
    state['idle_watch_from'] = time.time()
    rcon_route()
    while True:
        tick, paused = rcon_tick()
        if tick - state['start_tick'] >= state['minutes'] * 3600 or (paused and tick > state['start_tick'] + 3600):
            break
        idle_prompts(op, state)
        (op/'idle-watch.json').write_text(json.dumps({k: state.get(k) for k in ('idle_watch_from', 'idle_prompts')}, indent=1))
        time.sleep(20)


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
    used = {r['route'] if r['kind'] == 'claude' else r['kind'] for r in sprint_state.get('roster', [])}
    try:
        # (note-mt309-t) only the roster's own accounts (Grok and Muse are out: no reads of theirs). accounts() reads
        # the menu bar's cached brief, never a provider.
        acc = {k: v for k, v in M.accounts().items() if k in used}
    except (OSError, ValueError) as e:
        acc = {'error': str(e)}
    with (op/'meter-checks.jsonl').open('a') as f:
        f.write(json.dumps({'at': time.time(), 'accounts': acc}) + '\n')
    for route, r in acc.items() if isinstance(acc, dict) else []:
        if route not in used:      # (s1r1d) Codex's 100% week was noted with no Codex arm in the run
            continue
        for key, w in (r.get('windows') or {}).items() if isinstance(r, dict) else []:
            if (w.get('percent') or 0) >= 80 and f'{route}:{key}' not in sprint_state.setdefault('over_80', {}):
                sprint_state['over_80'][f'{route}:{key}'] = time.time()
    return acc


def codex_at_limit(acc, roster):
    """(note-mt309-m) The Codex window a Codex arm draws on at 99% or more (whole percents: 99 may be 99.9): no player
    ever runs on credits, so the sprint ends there. None when no Codex arm plays or the window is under 99."""
    if not any(r['kind'] == 'codex' for r in roster) or not isinstance(acc, dict):
        return None
    for key, w in ((acc.get('codex') or {}).get('windows') or {}).items():
        if (w.get('percent') or 0) >= 99:
            return f'codex {key} at {w.get("percent")}%'
    return None


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
        sub = ((bu.get(arm) or {}).get('tokens') or {}).get('subagents')
        parts.append(f"{arm} ({s['team']}): score {s['total']} [{gates}; research {s.get('research', 0)}, plates/min "
                     f"{s.get('plates_per_min', 0)}]; burn tokens->{b.get('pct')} plan ${b.get('plan_usd')}; account delta {acct}"
                     + (f"; Codex sub-agents {sub} (in its burn)" if sub else ''))
    over = st.get('over_80') or {}
    return (f"{run} done: " + ' | '.join(parts) + (f" | windows over 80%: {over}" if over else '')
            + f" | details runs/{run}/op/sprint-*.json")


def check_roster(roster):
    """At most three agents on the three spawns. (note-mt309-l) A team may hold two agents (a mixed pair on one force);
    each agent stays its own arm for burn and idle prompts, and the force's score is the team's."""
    assert 1 <= len(roster) <= 3 and all(r['team'] in FORCES for r in roster), 'at most three agents, on green, yellow, blue'
    per_team = collections.Counter(r['team'] for r in roster)
    assert max(per_team.values()) <= 2, 'at most two agents on one force'


def cmd_run(a):
    roster = roster_rows(a.roster)
    check_roster(roster)
    assert all(r['route'] not in FORBIDDEN_ROUTES for r in roster), 'account B route refused'
    assert sum(r['kind'] == 'agy' and 'gemini-4' in r['model'] for r in roster) <= 1, 'at most one Gemini 4 arm a run'
    bound = CONTACT_MINUTES if a.save in CONTACT_SAVES else 120
    assert a.minutes <= bound, f'sprints are bounded to {bound} minutes (Stage 2: two hours; the contact test four; launch.py --max-minutes)'
    # Paused start: the world waits while the agents launch, and the sprint begins for all of them at once.
    route = rcon_route()
    save, want = (BASELINE, BASELINE_SHA) if a.save == 'r307' else (SAVES[a.save], SAVES[a.save].with_suffix('.sha256').read_text().split()[0])
    env = dict(os.environ, POG_MT_FRESH='1', POG_MT_FRESH_SAVE=str(save), POG_SEED='30744', POG_GAME_TEST='0',
               **SPRINT_PROMPTS, POG_MT_PAUSED_START='1', POG_STOP_WORLD='1',
               POG_CLAIM_OWNER=os.environ.get('POG_CLAIM_OWNER', 'eng-mt309'))
    sha = subprocess.run(['shasum', '-a', '256', str(save)], capture_output=True, text=True).stdout.split()[0]
    assert sha == want, f'{save.name} changed: {sha}'
    launch = [sys.executable, str(ROOT/'tools/mt/launch.py'), a.run, str(a.minutes), '--roster', str(Path(a.roster).resolve())]
    if a.minutes > 90:
        launch += ['--max-minutes', '240' if a.minutes > 120 else '120']
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
    market = None
    if a.market == 'full':     # (note-mt309-u) design v3's market: Posts raidable, 25% of the wallet into a coin wreck
        market = market_full(a.run)
    rcon_set_paused(False)
    tick, paused = rcon_tick()
    state = dict(start_tick=tick, start_at=time.time(), minutes=a.minutes, score_version=SCORE_VERSION, roster=roster,
                 save=a.save, save_sha=sha, nudge_s=a.nudge_s, market=market)
    state.update(rcon_route=route, rcon_connect_s=rcon_connect_s())
    (op/'sprint.json').write_text(json.dumps(state, indent=1))
    meter_check(op, state)
    supervised(a.run, op, state, env, time.time() + 900)


def market_full(run):
    """mt_market {profile: full} on the paused world (as start-mt.sh does for a full run); the reply's settings, or
    SystemExit with the world left paused. It sends the agents nothing (pacts.lua)."""
    req = json.dumps({'id': f'sprint-market-{run}', 'operator': True, 'action': 'mt_market', 'args': {'profile': 'full'}})
    lua = ("local r=remote.call('agent_harness','dispatch',[[" + req + "]]) local j=helpers.json_to_table(r) "
           "rcon.print(j and j.ok and helpers.table_to_json(j.result.settings or {}) or ('REFUSED '..r))")
    sys.path.insert(0, str(ROOT/'tools'))
    out = subprocess.run([sys.executable, str(ROOT/'tools/pog.py'), '--world', 'imac2', 'rcon', '/silent-command ' + lua],
                         capture_output=True, text=True, timeout=60).stdout.strip()
    if not out.startswith('{'):
        wake(f'{run}: market profile full refused: {out[:300]} (world left paused)')
        raise SystemExit(f'{run}: market profile full refused')
    return json.loads(out)


def supervised(run, op, state, env, next_check):
    """supervise, and (note-mt309-u) when the runner itself fails (an unreadable server, a crash): wake the operator
    and stop the run rather than leave the agents playing unwatched."""
    try:
        supervise(run, op, state, env, next_check)
    except Exception as e:
        wake(f'{run}: RUNNER FAILED ({e!r}); stopping the run (server crash or lost RCON?)')
        state['ended_by'] = f'runner error: {e!r}'
        try:
            (op/'sprint.json').write_text(json.dumps(state, indent=1))
            state['stopped'] = stop_run(run, env); (op/'sprint.json').write_text(json.dumps(state, indent=1))
        finally:
            raise


def cmd_resume(a):
    """Re-enter a running sprint's supervision from its sprint.json (the runner process died, the world did not)."""
    op = op_dir(a.run)
    state = json.loads((op/'sprint.json').read_text())
    state.setdefault('resumed_at', []).append(time.time())
    rcon_route()
    env = dict(os.environ, POG_STOP_WORLD='1', POG_CLAIM_OWNER=os.environ.get('POG_CLAIM_OWNER', 'eng-mt309'))
    checks = [json.loads(l)['at'] for l in (op/'meter-checks.jsonl').read_text().splitlines()] if (op/'meter-checks.jsonl').exists() else []
    nxt = (max(checks) + 900) if checks else time.time()
    supervised(a.run, op, state, env, max(time.time(), nxt))


def stage2_measure(op, env, state=None):
    """One Stage 2 reading per force (tools/mt/stage2_save.py measure) into op/stage2.jsonl; a failed read never
    ends a sprint. (note-mt309-t) On the contact map the reading also holds the harness's first contacts (chart and
    shot, per ordered pair) and each team's losses by killer; each pair's first contact is woken once."""
    try:
        cmap = (state or {}).get('save') in CONTACT_SAVES
        r = subprocess.run([sys.executable, str(ROOT/'tools/mt/stage2_save.py'), *(['--map', state['save']] if cmap else []), 'measure'],
                           env=env, capture_output=True, text=True, timeout=60)
        row = dict(json.loads(r.stdout), at=time.time())
        with (op/'stage2.jsonl').open('a') as f:
            f.write(json.dumps(row) + '\n')
        if cmap:
            contact_wakes(op.parent.name, row, state)
    except Exception as e:
        print(time.strftime('%H:%M:%S'), 'stage 2 measure failed:', repr(e), flush=True)


def contact_wakes(run, row, state):
    """(note-mt309-t/u) Wake rows from one contact-map reading: each pair's first contact (chart) and first shot
    between teams, once each; losses to a rival team (the first, then at most every 10 minutes a pair while they
    grow); a home Post raided (a new spill record); a harness fault (a new runtime_fault). (note-mt309-z10) Also each
    team's first diplomacy message to each other team, by sender (ct3: green's ten were read as blue's); the first
    market transaction; and each new cross-team handover link (ct3's steel went by a blue inserter onto a green belt,
    which the market never saw)."""
    at = lambda tick: round((tick - state['start_tick']) / 3600, 1)
    seen = state.setdefault('contacts_woken', [])
    for key, tick in sorted((row.get('first') or {}).items(), key=lambda kv: kv[1]):
        if key not in seen:
            seen.append(key)
            kind, pair = key.split(' ', 1)
            wake(f"{run}: first contact {key} at game minute {at(tick)}" if kind == 'chart' else
                 f"{run}: ATTACK between teams: first {key} (damage) at game minute {at(tick)}")
    teams = {r['team'] for r in state.get('roster', [])}
    woke = state.setdefault('rival_losses_woken', {})
    now = row.get('tick', 0)
    for victim, by_all in (row.get('losses') or {}).items():
        for by, n in by_all.items():
            if by not in teams or by == victim:
                continue
            k = f'{victim}<{by}'; last = woke.get(k)
            if not last or (n > last['n'] and now - last['tick'] >= 36000):
                woke[k] = dict(n=n, tick=now)
                wake(f"{run}: {victim} has lost {n} entities to {by} (game minute {at(now)})")
    if (row.get('post_spills') or 0) > state.get('post_spills_woken', 0):
        wake(f"{run}: RAID: a Post was destroyed ({row['post_spills']} spill records; game minute {at(now)})")
        state['post_spills_woken'] = row['post_spills']
    talked = state.setdefault('talk_woken', [])
    for key, t in sorted((row.get('talk') or {}).items(), key=lambda kv: kv[1].get('first', 0)):
        if key not in talked and t.get('n'):
            talked.append(key); frm, to = key.split('>', 1)
            wake(f"{run}: first message {frm} -> {to} at game minute {at(t['first'])}: \"{t.get('text', '')}\"")
    if (row.get('transactions') or 0) and not state.get('transactions_woken'):
        wake(f"{run}: TRADE: first market transaction ({row['transactions']} on record; game minute {at(now)})")
        state['transactions_woken'] = row['transactions']
    links = state.setdefault('handovers_woken', {})
    for key, x in sorted((row.get('handovers') or {}).items()):
        if x.get('links', 0) > links.get(key, 0):
            giver, taker = key.split('>', 1)
            if not links.get(key):
                kinds = ', '.join(f'{n} {k}' for k, n in sorted((x.get('kinds') or {}).items()))
                wake(f"{run}: HANDOVER between teams: {giver}'s goods can reach {taker} by {kinds} (first at "
                     f"{tuple(x.get('at') or ())}; game minute {at(now)}): a trade or shipment outside the market")
            links[key] = x['links']
    fault = row.get('runtime_fault')
    if fault and fault != state.get('fault_woken'):
        wake(f"{run}: HARNESS ERROR runtime_fault: {fault[:300]} (game minute {at(now)})"); state['fault_woken'] = fault


def integrity_fault(op):
    """(note-mt309-u) A failed integrity check in the run's own logs: an autosave copy whose ZIP CRC or archive hash
    failed (autosave.py; 'save changed during copy' and 'slot rotated' are retries, not faults). None when clean."""
    log = op/'autosave.log'
    for line in (log.read_text(errors='replace').splitlines() if log.exists() else []):
        if 'CRC failed' in line or 'hash mismatch' in line:
            return f'autosave: {line.strip()[:200]}'
    return None


def stage2_summary(op, state, path=None):
    """Per force from op/stage2.jsonl: minutes (played game time from the start tick) to the nest's last spawner
    and to the first working drill on the second field, to the first attack (the first reading with a loss or a kill),
    and at the last reading what is left of the nest, losses (entities of the force killed) and character deaths;
    the second field's peak working drills, drill-minutes and drills working at the end (note-mt309-j).
    (note-mt309-f) green is the near spawn: its nearest building is about 90 tiles from its nest, 113 for the others."""
    rows = [json.loads(l) for l in (path or op/'stage2.jsonl').read_text().splitlines() if l.strip()]
    team_arm = {}   # (note-mt309-l) a two-agent team reads under both names, e.g. hydrogen+grok
    for r in state['roster']:
        team_arm[r['team']] = team_arm[r['team']] + '+' + r['arm'] if r['team'] in team_arm else r['arm']
    out = {}
    for team in FORCES:   # an empty spawn too (its arm reads empty-TEAM): its first attack is the unplayed baseline
        arm = team_arm.get(team, f'empty-{team}')
        mins = lambda row: round((row['tick'] - state['start_tick']) / 3600, 1)
        mine = [(r, r[team]) for r in rows if team in r]
        cleared = next((mins(r) for r, m in mine if m['spawners'] == 0), None)
        mining = next((mins(r) for r, m in mine if m['field_drills_working'] > 0), None)
        attacked = next((mins(r) for r, m in mine if m['lost'] > 0 or m['killed'] > 0), None)
        last = mine[-1][1] if mine else {}
        # (note-mt309-j) how much the second field mined: the peak, drill-minutes (each reading's working drills times
        # the game minutes since the reading before it) and what still works at the end
        drills = [m['field_drills_working'] for r, m in mine]
        drill_min = sum(d * (r['tick'] - p['tick']) / 3600 for (p, _), (r, _), d in zip(mine, mine[1:], drills[1:]))
        # (note-mt309-t) the contact map: each of the team's two nests, and the losses by killer at the end
        nests = [next((mins(r) for r, m in mine if (m.get('nests') or [[1]] * (k + 1))[k][0] == 0), None)
                 for k in range(len(last.get('nests') or []))]
        if state.get('save') in CONTACT_SAVES:
            out.setdefault('_contacts', {k: round((v - state['start_tick']) / 3600, 1) for k, v in (rows[-1].get('first') or {}).items()}
                           if rows else {})
            out.setdefault('_losses', (rows[-1].get('losses') or {}) if rows else {})
            # (note-mt309-z10) messages by sender, and each cross-team handover link with when it was first seen
            out.setdefault('_talk', {k: dict(n=t.get('n'), first_min=round((t['first'] - state['start_tick']) / 3600, 1))
                                     for k, t in ((rows[-1].get('talk') or {}) if rows else {}).items()})
            seen = {}
            for r in rows:
                for k, x in (r.get('handovers') or {}).items():
                    seen.setdefault(k, dict(first_min=round((r['tick'] - state['start_tick']) / 3600, 1), at=x.get('at')))
                    seen[k].update(links_last=x.get('links'), kinds_last=x.get('kinds'))
            out.setdefault('_handovers', seen)
        out[arm] = dict(team=team, spawn=STAGE2_SPAWN.get(team) if state.get('save') not in CONTACT_SAVES else state['save'],
                        first_attack_min=attacked, nest_cleared_min=cleared, nests_cleared_min=nests or None, second_field_min=mining,
                        field_drills_peak=max(drills, default=None), field_drill_min=round(drill_min, 1),
                        field_drills_end=drills[-1] if drills else None, spawners_left=last.get('spawners'),
                        worms_left=last.get('worms'), lost=last.get('lost'), characters_lost=last.get('characters_lost'),
                        killed=last.get('killed'), readings=len(mine))
    (op/'stage2-summary.json').write_text(json.dumps(out, indent=1))
    return out


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
            limit = codex_at_limit(meter_check(op, state), roster); save(); next_check += 900
            try:
                codex_subagents(op, state); save()
            except Exception as e:      # a log read never ends a sprint
                print(time.strftime('%H:%M:%S'), 'sub-agent check failed:', repr(e), flush=True)
            bad = integrity_fault(op)
            if bad:      # (note-mt309-u) an integrity check failed: stop the run and wake the operator
                state['ended_by'] = f'integrity: {bad}'; wake(f'{run}: INTEGRITY {bad}: the run stops now'); break
            if limit:      # every arm stops with it: the run's world and score end at the same tick
                state['ended_by'] = limit; wake(f'{run}: {limit}: the sprint ends now (no Codex player on credits)')
                break
        if state.get('save') in SAVES and time.time() >= state.get('next_stage2', 0):
            stage2_measure(op, env, state); state['next_stage2'] = time.time() + 120
        try:
            n = sum(len(v) for v in state.get('idle_prompts', {}).values())
            idle_prompts(op, state)
            if sum(len(v) for v in state.get('idle_prompts', {}).values()) != n:
                save()
        except Exception as e:      # a pane read never ends a sprint
            print(time.strftime('%H:%M:%S'), 'idle prompt check failed:', repr(e), flush=True)
        time.sleep(20)
    rcon_set_paused(True)
    time.sleep(130)  # one more score row per force (score-loop.sh, every 120 s), taken on the paused world
    meter_check(op, state)
    played = min(a.minutes, (tick - state['start_tick']) / 3600)
    state.update(end_tick=tick, end_at=time.time(), played_minutes=round(played, 2)); save()
    cmd_score(argparse.Namespace(run=a.run, minutes=played))
    if state.get('save') in SAVES:
        stage2_measure(op, env, state); state['stage2'] = stage2_summary(op, state); save()
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
    q.add_argument('--save', choices=['r307', 'stage2', *CONTACT_SAVES], default='r307')
    q.add_argument('--market', choices=['save', 'full'], default='save', help='full: mt_market profile full at the start')
    q.add_argument('--nudge-s', type=int, default=NUDGE_S, help='seconds after a turn ends before the idle prompt')
    q = sub.add_parser('resume'); q.add_argument('run')
    q = sub.add_parser('idle-watch'); q.add_argument('run')
    a = p.parse_args(argv)
    return {'plan': cmd_plan, 'score': cmd_score, 'burn': cmd_burn, 'run': cmd_run, 'resume': cmd_resume, 'idle-watch': cmd_idle_watch}[a.cmd](a)


if __name__ == '__main__':
    main()
