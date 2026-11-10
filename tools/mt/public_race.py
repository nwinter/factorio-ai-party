"""Public race facts. Bounded, typed projection; no operator text or action payloads.

Reuses stream science, chronicle and basemap snapshots and the site's icon index.
Only this module's constructed records may cross the public HTTP boundary.
"""
from collections import deque
from datetime import datetime
import importlib.util
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mt_gameicons', ROOT / 'site/gameicons.py')
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)

ACTIVITY = {'thinking', 'acting', 'idle', 'resting', 'offline', 'dead'}
ACTIONS = {'mine': 'Mining', 'craft': 'Crafting', 'build': 'Building', 'build_blueprint': 'Placing a blueprint',
           'walk': 'Moving', 'move': 'Moving', 'insert': 'Loading machines', 'take': 'Collecting materials',
           'research': 'Starting research', 'shoot': 'Fighting', 'attack': 'Fighting', 'kite': 'Fighting',
           'guard': 'On guard', 'repair': 'Repairing', 'rotate': 'Rotating machines', 'wait': 'Waiting',
           'wait_until': 'Waiting', 'drive': 'Driving', 'launch': 'Launching'}
BUILDINGS = ('burner-mining-drill', 'electric-mining-drill', 'stone-furnace', 'steel-furnace',
             'electric-furnace', 'assembling-machine-1', 'assembling-machine-2', 'assembling-machine-3',
             'lab', 'biolab', 'steam-engine', 'solar-panel', 'oil-refinery', 'chemical-plant', 'rocket-silo')
STARTUP = ('burner-mining-drill', 'stone-furnace', 'steam-engine', 'lab', 'assembling-machine-1')
PACKS = ('automation-science-pack', 'logistic-science-pack', 'chemical-science-pack',
         'production-science-pack', 'utility-science-pack', 'space-science-pack')
# Free-form public chat remains public speech, never notes, jobs, confessions or errors.
PRIVATE = re.compile(r'(?:https?://|(?:^|\s)(?:/|~/|[A-Za-z]:[\\/])|[\w.+-]+@[\w.-]+\.[a-z]{2,}|'
                     r'\b(?:token|password|secret|api[_ -]?key|operator|traceback|exception)\b|\bsk-[\w-]+)', re.I)


def obj(v):
    return v if isinstance(v, dict) else {}


def rows(v):
    return v if isinstance(v, list) else []


def number(v, default=None, lo=0, hi=1e12):
    return max(lo, min(hi, v)) if type(v) in (int, float) and math.isfinite(v) else default


def clock(tick):
    if tick is None:
        return '--:--'
    minutes, seconds = divmod(int(tick / 60), 60)
    return f'{minutes:02d}:{seconds:02d}'


def title(v):
    return (v or '').replace('-', ' ').capitalize()


def prototype(kind, value):
    return icons.key(kind, value) if isinstance(value, str) and len(value) < 100 else None


def speech(value, private_names=()):
    if not isinstance(value, str) or PRIVATE.search(value):
        return ''
    if any(re.search(r'\b' + re.escape(n) + r'\b', value, re.I) for n in private_names if n):
        return ''
    return re.sub(r'\s+', ' ', re.sub(r'\[/?[a-z-]+(?:=[^\]]*)?\]', '', value)).strip()[:300]


def grid(raw):
    """Basemap category grid only, never terrain URLs, pins, custom labels or paths."""
    raw = obj(raw)
    w, h = number(raw.get('w'), hi=256), number(raw.get('h'), hi=256)
    if not w or not h or w != raw.get('w') or h != raw.get('h'):
        return None
    w, h = int(w), int(h)
    data = rows(raw.get('rows'))
    if len(data) != h or any(not isinstance(r, str) or len(r) != w or
                             re.search(r'[^. DWROASMELIBTP]', r) for r in data):
        return None
    out = {k: number(raw.get(k), lo=-1e7) for k in ('x0', 'y0')}
    out.update(cell=number(raw.get('cell'), hi=1024), tick=number(raw.get('tick')), w=w, h=h, rows=data)
    return out if all(out[k] is not None for k in ('x0', 'y0', 'cell')) and out['cell'] > 0 else None


def read_views(op, now):
    """Reuse the operator's existing 60s read. Never serve this file itself."""
    try:
        v = json.loads((op / 'views.json').read_text())
        at = datetime.strptime(v['t'], '%Y-%m-%d %H:%M:%S').timestamp()
        return v if 0 <= now - at <= 150 else {}
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def project(team, state, agents, now, score=None):
    """Deliberate allowlist; identities come only from the launch roster, not the feed."""
    state, score = obj(state), obj(score)
    research, science, space = (obj(state.get(k)) for k in ('research', 'science', 'space'))
    current = {a.get('name'): a for a in rows(state.get('agents')) if isinstance(a, dict) and isinstance(a.get('name'), str)}
    public_names = {a['name'] for a in agents}
    private_names = [s for a in current.values() if a.get('name') not in public_names
                     for s in (a.get('name'), a.get('display_name')) if isinstance(s, str)]
    freshness = number(state.get('poll_ok') if 'poll_ok' in state else state.get('now'), 0)
    tick = number(state.get('tick'))
    done = number(research.get('done_count'))
    # Some startup feeds lag the separate force score. Do not make up a zero.
    score_done = score.get('research')
    if isinstance(score_done, (list, dict)) and (done is None or number(score.get('tick'), 0) >= (tick or 0)):
        done = len(score_done)
    tech = prototype('tech', research.get('current'))
    out_agents = []
    for a in agents:
        live = obj(current.get(a['name']))
        activity = live.get('activity') if isinstance(live.get('activity'), str) and live['activity'] in ACTIVITY else 'unknown'
        active = live.get('active') if isinstance(live.get('active'), str) else ''
        verb, _, what = active.partition(':')
        item = prototype('item', what)
        action = ACTIONS.get(verb)
        if action and item:
            action += ' ' + title(item).lower()
        action = action or {'thinking': 'Planning the next move', 'resting': 'Between turns',
                            'idle': 'Waiting for the next move', 'offline': 'Agent offline',
                            'dead': 'Waiting to respawn'}.get(activity, 'Working in the factory' if activity == 'acting' else 'Awaiting activity')
        p = obj(live.get('position'))
        pos = {k: number(p.get(k), lo=-1e7, hi=1e7) for k in ('x', 'y')}
        out_agents.append({'name': a['name'], 'display_name': a['name'].capitalize(),
                           'model': speech(a.get('model'))[:60], 'activity': activity, 'action': action,
                           'position': pos if all(v is not None for v in pos.values()) and live.get('surface', 'nauvis') == 'nauvis' else None})
    chat = []
    for m in rows(state.get('chat'))[-12:]:
        m = obj(m)
        name = m.get('name') or m.get('agent') or m.get('from')
        text = speech(m.get('text'), private_names)
        if isinstance(name, str) and name in public_names and text:
            chat.append({'name': name, 'text': text, 'tick': number(m.get('tick')), 't': number(m.get('t'))})
    entities = {k: int(number(obj(score.get('entities')).get(k), 0)) for k in BUILDINGS} if score else None
    bm = obj(state.get('basemap'))
    mini = grid(bm.get('core')) or grid(bm)
    if mini and mini['tick'] is None:
        mini['tick'] = number(bm.get('tick'))
    events = []
    for e in rows(obj(state.get('chronicle')).get('events'))[-12:]:
        e = obj(e)
        et = number(e.get('tick'))
        kind, text, icon = e.get('kind'), None, None
        if kind == 'research' and prototype('tech', e.get('name')):
            icon = prototype('tech', e['name'])
            text = title(icon) + ' completed'
        elif kind == 'rocket':
            text, icon = 'Rocket launched', 'rocket-part'
        elif kind == 'death' and isinstance(e.get('agent'), str) and e['agent'] in public_names:
            text = e['agent'].capitalize() + ' was lost'
        elif kind == 'platform_lost':
            text, icon = 'Space platform lost', 'space-platform-hub'
        if text and et is not None:
            events.append({'kind': kind, 'text': text, 'tick': et, 'icon': icon,
                           'icon_kind': 'tech' if kind == 'research' else 'item'})
    return {'team': team, 'stale': now - freshness > 25 or freshness > now + 5 or bool(state.get('poll_error')),
            'tick': tick, 'game_time': clock(tick), 'paused': bool(state.get('paused')), 'agents': out_agents,
            'research': {'current': tech, 'label': title(tech), 'progress': number(research.get('progress'), hi=1), 'done_count': done},
            'science': {'spm': number(science.get('spm')), 'series': [number(v, 0) for v in rows(science.get('series'))[-30:]],
                        'stage': int(number(science.get('stage'), 0, hi=5)),
                        'packs': [p for p in PACKS if any(obj(m).get('item') == p and number(obj(m).get('total'), 0) > 0
                                                       for m in rows(obj(science.get('made')).get('packs')))]},
            'space': {'rockets': number(space.get('rockets'), number(score.get('rockets')))},
            'entities': entities, 'score_tick': number(score.get('tick')), 'map': mini,
            'chat': chat[-3:], 'events': events}


def rank(rows_):
    """No invented overall percentage. Equal scores stay tied, stale feeds unranked."""
    valid = [r for r in rows_ if not r['stale'] and r['research']['done_count'] is not None and r['space']['rockets'] is not None]
    startup = bool(valid) and all(not r['research']['done_count'] and not r['space']['rockets'] for r in valid)
    if startup:
        valid = [r for r in valid if r['entities'] is not None]
    def key(r):
        return ((sum(r['entities'].get(k, 0) > 0 for k in STARTUP),) if startup else
                (r['space']['rockets'], r['research']['done_count']))
    ordered = sorted(valid, key=key, reverse=True)
    best = key(ordered[0]) if ordered else None
    for r in rows_:
        r.update(rank=None, leader=False, startup=startup, gap='Feed delayed' if r['stale'] else 'Awaiting score')
    for r in ordered:
        k = key(r)
        place = 1 + sum(key(o) > k for o in ordered)
        tied = sum(key(o) == k for o in ordered) > 1
        if k == best:
            gap = 'Joint lead' if tied else 'Leading'
        elif startup:
            gap = f'{best[0] - k[0]} startup steps back'
        elif best[0] != k[0]:
            gap = f'{int(best[0] - k[0])} rockets back'
        else:
            gap = f'{int(best[1] - k[1])} techs back'
        r.update(rank=place, leader=k == best, gap=gap,
                 startup_steps=sum((r['entities'] or {}).get(k, 0) > 0 for k in STARTUP))
    return 'Startup: miner · furnace · power · lab · assembler' if startup else 'Rank: rockets → technologies completed'


class Race:
    def __init__(self):
        self.previous, self.events, self.seen = {}, deque(maxlen=80), deque(maxlen=400)

    def add(self, team, kind, text, tick, now, icon=None, icon_kind='item', observed=False):
        key = (team, kind, text, tick)
        if key in self.seen:
            return
        self.seen.append(key)
        self.events.append({'team': team, 'kind': kind, 'text': text, 'tick': tick,
                            'time': clock(tick), 'at': now, 'icon': icon, 'icon_kind': icon_kind,
                            'observed': observed})

    def update(self, teams, now, contacts=()):
        for r in teams:
            if r['stale']:
                continue
            t, tick = r['team'], r['tick']
            old = self.previous.get(t)
            # Loading an older save must not create a flood of losses or carry future news.
            if old and tick is not None and old['tick'] is not None and tick < old['tick']:
                self.events = deque((e for e in self.events if e['team'] != t), maxlen=80)
                self.seen = deque((k for k in self.seen if k[0] != t), maxlen=400)
                old = None
            for e in r['events']:
                if tick is not None and 0 <= tick - e['tick'] <= 36000:
                    self.add(t, e['kind'], e['text'], e['tick'], now - (tick - e['tick']) / 60, e['icon'], e['icon_kind'])
            if old and tick is not None:
                before, after = old['research']['done_count'], r['research']['done_count']
                if before is not None and after is not None and after > before and not any(e['kind'] == 'research' and e['tick'] > (old['tick'] or 0) for e in r['events']):
                    self.add(t, 'research', f'{int(after-before)} technologies completed', tick, now, 'lab', observed=True)
                if r['space']['rockets'] is not None and old['space']['rockets'] is not None and r['space']['rockets'] > old['space']['rockets'] and not any(e['kind'] == 'rocket' and e['tick'] > (old['tick'] or 0) for e in r['events']):
                    self.add(t, 'rocket', 'First rocket launched' if old['space']['rockets'] == 0 else 'Rocket launched', tick, now, 'rocket-part', observed=True)
                if r['entities'] is not None and old['entities'] is not None:
                    for item in BUILDINGS:
                        n, b = r['entities'][item], old['entities'][item]
                        if n > b and (b == 0 or item in ('lab', 'assembling-machine-1', 'electric-mining-drill')):
                            self.add(t, 'build', ('First ' if b == 0 else f'+{n-b} ') + title(item).lower() + (' built' if b == 0 else f' · {n} total'), r['score_tick'] or tick, now, item, observed=True)
            self.previous[t] = r
        known = {r['team'] for r in teams}
        for c in contacts:
            c = obj(c)
            if isinstance(c.get('a'), str) and isinstance(c.get('b'), str) and c['a'] in known and c['b'] in known and number(c.get('tick')) is not None:
                self.add(c['a'], 'contact', 'First contact with ' + c['b'].capitalize(), c['tick'], now, 'radar')
        basis = rank(teams)
        return {'teams': teams, 'events': sorted(self.events, key=lambda e: e['tick'] or 0, reverse=True)[:12], 'ranking': basis}


class Director:
    """Minimum dwell + event interest; hard oldest-first fairness, successful cuts only."""
    def __init__(self, dwell=30):
        self.minimum = max(10, min(20, dwell / 2))
        self.dwell = dwell
        self.current, self.since = None, 0
        self.shown, self.retry, self.started = {}, {}, None

    def choose(self, teams, events, now):
        if self.started is None:
            self.started = now
        eligible = [r for r in teams if not r['stale'] and not r['paused'] and now >= self.retry.get(r['team'], 0)]
        if not eligible or (self.current and now - self.since < self.minimum):
            return None
        others = [r for r in eligible if r['team'] != self.current]
        if not others:
            return (eligible[0]['team'], 'Following the action') if self.current is None else None
        age = lambda r: now - self.shown.get(r['team'], self.started - self.dwell)
        overdue = [r for r in others if age(r) >= self.dwell * max(2, len(teams))]
        if overdue:
            return max(overdue, key=age)['team'], 'Around the teams'
        def interest(r):
            recent = [e for e in events if e['team'] == r['team'] and now - e['at'] <= 40 and e['at'] > self.shown.get(r['team'], -1)]
            weight = max(({'rocket': 10, 'death': 9, 'platform_lost': 9, 'contact': 8, 'research': 6, 'build': 4}.get(e['kind'], 0) for e in recent), default=0)
            return weight + 2 * any(a['activity'] == 'acting' for a in r['agents']), weight
        best = max(others, key=lambda r: (interest(r)[0], age(r)))
        score, event = interest(best)
        if self.current is None or now - self.since >= self.dwell or event:
            return best['team'], 'New milestone' if event else 'Following the action' if score else 'Around the teams'
        return None

    def success(self, team, now):
        self.current, self.since = team, now
        self.shown[team] = now

    def failed(self, team, now):
        self.retry[team] = now + 30
