"""Public race facts. Bounded, typed projection; no operator text or action payloads.

Reuses stream science, chronicle and basemap snapshots and the site's icon index.
Only this module's constructed records may cross the public HTTP boundary.

mt294: agent identities (chosen name, persona, colour, glyph, avatar parts), one
chronological speech feed across teams, and a camera director that prefers agents
doing things. `subjects()` is the director's private input and is never published.
"""
from collections import deque
from datetime import datetime
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mt_gameicons', ROOT / 'site/gameicons.py')
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)

ACTIVITY = {'thinking', 'acting', 'idle', 'resting', 'offline', 'dead'}
ACTIONS = {'mine': 'Mining', 'craft': 'Crafting', 'build': 'Building', 'build_blueprint': 'Placing a blueprint',
           'walk': 'Moving', 'move': 'Moving', 'insert': 'Supplying', 'take': 'Collecting',
           'research': 'Starting research', 'shoot': 'Fighting', 'attack': 'Fighting', 'kite': 'Fighting',
           'guard': 'On guard', 'repair': 'Repairing', 'rotate': 'Rotating machines', 'wait': 'Waiting',
           'wait_until': 'Waiting', 'drive': 'Driving', 'launch': 'Launching',
           # Kinds the 2.1 feeds actually carry (status.active.kind), seen in the t291/t292 journals.
           'move_to': 'Moving', 'path': 'Moving', 'follow': 'Moving', 'place': 'Building', 'construct': 'Building',
           'blueprint': 'Placing a blueprint', 'build_path': 'Building', 'deconstruct': 'Clearing',
           'feed': 'Supplying', 'gather': 'Collecting', 'collect': 'Collecting', 'pickup': 'Collecting',
           'fuel': 'Refuelling', 'refuel': 'Refuelling', 'transfer': 'Moving items', 'configure': 'Setting up machines'}
# The stream director's own classes (tools/stream/director.py FIGHT/BUILD/WORK/WALK), plus the 2.1 kinds above.
VERBS = {'fight': {'shoot', 'attack', 'kite'},
         'build': {'build', 'place', 'construct', 'blueprint', 'build_blueprint', 'build_path', 'rotate', 'repair',
                   'deconstruct'},
         'work': {'mine', 'craft', 'insert', 'take', 'feed', 'gather', 'research', 'fuel', 'refuel', 'transfer',
                  'collect', 'pickup', 'configure', 'launch'},
         'walk': {'walk', 'path', 'move_to', 'follow', 'move', 'drive'}}
BUILDINGS = ('burner-mining-drill', 'electric-mining-drill', 'stone-furnace', 'steel-furnace',
             'electric-furnace', 'assembling-machine-1', 'assembling-machine-2', 'assembling-machine-3',
             'lab', 'biolab', 'steam-engine', 'solar-panel', 'oil-refinery', 'chemical-plant', 'rocket-silo')
STARTUP = ('burner-mining-drill', 'stone-furnace', 'steam-engine', 'lab', 'assembling-machine-1')
PACKS = ('automation-science-pack', 'logistic-science-pack', 'chemical-science-pack',
         'production-science-pack', 'utility-science-pack', 'space-science-pack')
SURFACES = ('nauvis', 'vulcanus', 'gleba', 'fulgora', 'aquilo')
# Free-form public chat remains public speech, never notes, jobs, confessions or errors.
# A path is a slash that starts a word ("/Users/x", "~/x", "C:\x"); "0.52 / 0.48" is ordinary speech.
PRIVATE = re.compile(r'(?:https?://|(?:^|[\s("\'=])(?:~/|/(?=[\w.~])|[A-Za-z]:[\\/])|[\w.+-]+@[\w.-]+\.[a-z]{2,}|'
                     r'\b(?:token|password|secret|api[_ -]?key|operator|traceback|exception|multi-?teams?)\b|\bsk-[\w-]+)', re.I)
# Moderated audience text is addressed to the operator. That ordinary role word
# is public; keep the stricter operator/private-note exclusion for agent speech.
VIEWER_PRIVATE = re.compile(PRIVATE.pattern.replace('|operator|', '|'), PRIVATE.flags)
# Words a chosen display name may not be: staff, sources and marks a viewer could mistake for the broadcast itself.
RESERVED = {'server', 'operator', 'mod', 'moderator', 'admin', 'caster', 'system', 'host', 'viewer', 'viewers',
            'youtube', 'site', 'wube', 'factorio', 'staff'}
HEX = re.compile(r'#[0-9a-fA-F]{6}')
PRONOUNS = re.compile(r'(?:he|she|they|it|xe|ze|ey|fae)(?:/[a-z]{2,8}){0,2}')
PACT_TEXT = {'proposed': 'Pact #{id} proposed to {other}', 'active': 'Pact #{id} signed with {other}',
             'ended': 'Pact #{id} with {other} ended', 'declined': 'Pact #{id} with {other} declined',
             'withdrawn': 'Pact #{id} with {other} withdrawn', 'expired': 'Pact #{id} with {other} expired'}


def _avatar_options():
    """The part lists of the main stream's avatar generator (strict JSON between its markers)."""
    try:
        text = (ROOT / 'tools/stream/static/avatar.js').read_text(encoding='utf-8')
        body = text.split('/*@parts*/', 1)[1].split('/*@end*/', 1)[0]
        return json.loads(body[body.index('{'): body.rindex('}') + 1])['options']
    except (OSError, ValueError, KeyError, IndexError):
        return {}


AVATAR = _avatar_options()


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


def speech(value, private_names=(), limit=300, *, viewer=False):
    if not isinstance(value, str) or (VIEWER_PRIVATE if viewer else PRIVATE).search(value):
        return ''
    if any(re.search(r'\b' + re.escape(n) + r'\b', value, re.I) for n in private_names if n):
        return ''
    text = re.sub(r'\s+', ' ', re.sub(r'\[/?[a-z-]+(?:=[^\]]*)?\]', '', value)).strip()
    if len(text) <= limit:
        return text
    cut = text[:limit - 1]
    space = cut.rfind(' ')
    return (cut[:space] if space >= limit // 2 else cut).rstrip(' ,;:-') + '…'


def label(value, private_names=(), limit=24):
    """A chosen display name: letters, digits and light punctuation only. '' when unusable."""
    if not isinstance(value, str) or len(value) > 200 or PRIVATE.search(value) or re.search(r'[<>{}\[\]\\]', value):
        return ''
    kept = ''
    for c in unicodedata.normalize('NFC', value):
        cat = unicodedata.category(c)
        if cat[0] in 'LN' or c in ".'’-&!" or (cat[0] == 'M' and c != '\ufe0f' and kept and unicodedata.category(kept[-1])[0] in 'LM'):
            kept += c
        elif cat == 'Zs' or c == '_':
            kept += ' '
    kept = re.sub(r'\s+', ' ', kept).strip(" .'’-&")[:limit].strip(" .'’-&")
    if len(kept) < 2 or speech(kept, private_names) != kept:
        return ''
    return '' if any(w in RESERVED for w in re.findall(r'[a-z]+', kept.lower())) else kept


def glyph(value):
    """One or two characters or an emoji beside a name. Never markup, spaces or control characters."""
    if not isinstance(value, str):
        return None
    value = unicodedata.normalize('NFC', value).strip()
    if not value or len(value) > 8:
        return None
    for c in value:
        cat = unicodedata.category(c)
        if cat in ('Cc', 'Cs', 'Co', 'Cn', 'Zl', 'Zp', 'Zs') or (cat == 'Cf' and c not in '\u200d\ufe0f') or c in '<>&"\'\\/':
            return None
    return value


def avatar_spec(value):
    """Only the avatar generator's own part names; anything else follows from the agent's name."""
    out = {}
    for k, v in obj(value).items():
        if k == 'accent' and isinstance(v, str) and HEX.fullmatch(v):
            out[k] = v.lower()
        elif isinstance(k, str) and isinstance(v, str) and v in AVATAR.get(k, ()):
            out[k] = v
    return out or None


def verb_class(kind):
    return next((name for name, kinds in VERBS.items() if kind in kinds), None)


def identity(agent, live, private_names=()):
    """Who an agent is on air. The roster names the agent and seeds colour and icon; the agent's own
    profile (the harness `profile` action, carried by its team's feed) supplies its chosen name,
    persona, pronouns and avatar parts. Every field is rebuilt here; nothing is copied through."""
    live = obj(live)
    chosen = label(live.get('display_name'), private_names)
    seeded = label(agent.get('display_name'), private_names)
    plain = agent['name'].capitalize()
    pronouns = live.get('pronouns').strip().lower() if isinstance(live.get('pronouns'), str) else ''
    icon = prototype('item', agent.get('icon'))
    return {'display_name': chosen or seeded or plain,
            # True only when the name is the agent's own choice, not the roster default.
            'named': bool(chosen and chosen.lower() != plain.lower()),
            'color': next((c.lower() for c in (live.get('color'), agent.get('color'))
                           if isinstance(c, str) and HEX.fullmatch(c)), None),
            # A roster icon is a game item when the icon manifest knows it, otherwise a glyph.
            'glyph': glyph(live.get('glyph')) or glyph(agent.get('glyph')) or (None if icon else glyph(agent.get('icon'))),
            'icon': icon,
            # The agent's own words first (a persona, else its motto), then a roster seed.
            'persona': (speech(live.get('persona'), private_names, 160) or speech(live.get('motto'), private_names, 80)
                        or speech(agent.get('persona'), private_names, 160)),
            'pronouns': pronouns if PRONOUNS.fullmatch(pronouns) else None,
            'avatar': avatar_spec(live.get('avatar')) or avatar_spec(agent.get('avatar'))}


def team_chat(team, messages, names, private_names=(), now=None, tick=None, keep=12):
    """Team talk and internal tells only. Never a global feed or relay input.

    Main stream tells use {agent, from, lane: tell, to: [...], body, text};
    text/to_shown contain presentation names and are deliberately ignored.
    Lane `log` is the same team talk restored at a service start. `at` is the wall
    time a line was said (the feed's own stamp for a live line, else from its tick),
    so the overlay can order lines from every team on one clock.
    """
    aliases = {alias: n for n in names for alias in (n, 'pog-' + n)}
    out = []
    for m in map(obj, rows(messages)[-80:]):
        if m.get('kind') == 'diplomacy' or m.get('from_team') or m.get('to_team'):
            continue
        if any(m.get(k) for k in ('operator', 'confess', 'notice', 'viewer', 'source')):
            continue
        if any(m.get(k) not in (None, team) for k in ('team', 'force')):
            continue
        speakers = [m[k] for k in ('agent', 'from', 'name') if m.get(k) is not None]
        if not speakers or any(not isinstance(n, str) or n not in aliases for n in speakers):
            continue
        sender = aliases[speakers[0]]
        if any(aliases[n] != sender for n in speakers):
            continue
        lane = m.get('lane')
        if lane == 'tell' or m.get('tell'):
            if lane not in (None, 'tell'):
                continue
            recipients = [m['to']] if isinstance(m.get('to'), str) else rows(m.get('to'))
            if not recipients or any(not isinstance(n, str) or n not in aliases and n != 'team' for n in recipients):
                continue
            to = sorted({aliases.get(n, 'team') for n in recipients})
            text = speech(m.get('body'), private_names)
            kind = 'tell'
        elif lane in (None, 'talk', 'log') and not m.get('to'):
            to, text, kind = [], speech(m.get('text'), private_names), 'talk'
        else:
            continue
        if not text:
            continue
        said, stamp, seq = number(m.get('tick')), number(m.get('t')), m.get('seq')
        if type(seq) is int and 0 <= seq < 1e12 or isinstance(seq, str) and re.fullmatch(r't?[0-9]{1,12}', seq):
            ident = f'{team}:{seq}'
        else:
            ident = f'{team}:' + hashlib.sha1(f'{sender}|{kind}|{said}|{text}'.encode()).hexdigest()[:12]
        if stamp is not None and lane != 'log' and now is not None and -5 <= now - stamp <= 6 * 3600:
            at = stamp
        elif said is not None and tick is not None and now is not None:
            at = now - max(0, tick - said) / 60
        else:
            at = stamp
        out.append({'id': ident, 'team': team, 'name': sender, 'to': to, 'kind': kind, 'text': text,
                    'tick': said, 't': stamp, 'at': at, 'reply': False})
    return out[-keep:]


def diplomacy(messages, teams):
    """Only explicitly sent diplomacy. Never derive this lane from private team chat."""
    rosters = {t['team']: {a['name'] for a in t['agents']} for t in teams}
    latest = max((t.get('tick') or 0 for t in teams), default=0)
    out = []
    for m in map(obj, rows(messages)[-100:]):
        sender, recipient, agent = m.get('from_team'), m.get('to_team'), m.get('agent')
        if not (m.get('kind') == 'diplomacy' and isinstance(sender, str) and isinstance(recipient, str) and sender != recipient
                and sender in rosters and recipient in rosters and isinstance(agent, str) and agent in rosters[sender]):
            continue
        if any(m.get(k) for k in ('operator', 'tell', 'viewer', 'source', 'confess')):
            continue
        tick, body = number(m.get('tick')), speech(m.get('text'), ('Nick', 'Winter'))
        if tick is not None and 0 <= latest - tick <= 36000 and body and type(m.get('seq')) is int:
            out.append({'from_team':sender, 'to_team':recipient, 'agent':agent, 'text':body,
                        'seq':m['seq'], 'tick':tick, 'time':clock(tick)})
    return out[-12:]


KINDS = {'say': 'talk', 'tell': 'tell', 'diplomacy': 'diplomacy', 'board': 'board', 'identity': 'identity', 'market': 'market'}


def broadcast(lines, teams, now):
    """Feed rows from the operator's ordered feed, after public_feed.project_feed has checked each line's
    team, roster sender, scope and recipients. One global sequence orders every team's speech; a tell
    names teammates, diplomacy one other team, a board note and an identity announcement nobody.
    The text passes this module's speech() as well; an identity line is rebuilt from label() and speech()."""
    latest = max((t.get('tick') or 0 for t in teams), default=0)
    known = {t['team'] for t in teams}
    out = []
    for m in map(obj, rows(lines)):
        kind, seq, tick, team, to = KINDS.get(m.get('kind')), m.get('seq'), number(m.get('tick')), m.get('team'), rows(m.get('to'))
        text = speech(m.get('text'), ('Nick', 'Winter'))
        if not kind or type(seq) is not int or tick is None or team not in known or not isinstance(m.get('agent'), str) or not text:
            continue
        row = {'id': f'f:{seq}', 'team': team, 'name': m['agent'], 'to': [n for n in to if isinstance(n, str)] if kind == 'tell' else [],
               'kind': kind, 'text': text, 'tick': tick, 'at': now - max(0, latest - tick) / 60, 'reply': False}
        if kind == 'market':
            event = m.get('event', 'fill')
            if (m.get('system') is not True or m['agent'] != 'Trading Post' or m.get('scope') != 'market'
                    or event not in ('fill', 'coinage', 'raid', 'embargo')
                    or type(m.get('source_seq')) is not int or m['source_seq'] < 1):
                continue
            if event in ('fill', 'embargo'):
                if len(to) != 1 or to[0] not in known or to[0] == team: continue
                row['to_team'] = to[0]
            elif to: continue
            row.update(system=True, event=event, source_seq=m['source_seq'])
        elif kind == 'diplomacy':
            if len(to) != 1 or to[0] not in known or to[0] == team:
                continue
            row['to_team'] = to[0]
        elif kind == 'identity':
            who = obj(m.get('identity'))
            name, persona = label(who.get('display_name'), ('Nick', 'Winter')), speech(who.get('persona'), ('Nick', 'Winter'), 160)
            # An announcement needs something chosen: a name that is not the roster default, or a persona.
            if not name or (name.lower() == m['agent'].lower() and not persona):
                continue
            row.update(title=name, text=persona)
        elif kind == 'board':
            row['text'] = re.sub(r'^#\d+\s+', '', text)
        out.append(row)
    return out


def project_market(raw, teams):
    """Operator shipment/print facts only. Never export balances, orders or audit state."""
    raw = obj(raw)
    known = {t['team'] for t in teams}
    latest = max((t.get('tick') or 0 for t in teams), default=0)
    out = {'markers': [], 'last_prices': []}
    def finite(v, lo=0, hi=1e12, integer=False):
        return type(v) in (int, float) and math.isfinite(v) and lo <= v <= hi and (not integer or v == int(v))
    def pair(a, b):
        return isinstance(a, str) and isinstance(b, str) and a in known and b in known and a != b
    def item(v):
        return 'coin' if v == 'mt-coin' else prototype('item', v)
    tick = raw.get('tick')
    if not finite(tick, integer=True) or not -300 <= latest - tick <= 900:
        return out
    out['tick'] = tick
    seen = set()
    for m in map(obj, rows(raw.get('markers'))[-120:]):
        a, b, name = m.get('from'), m.get('to'), item(m.get('item'))
        if (not pair(a, b) or not name or not finite(m.get('id'), 1, integer=True)
            or not finite(m.get('count'), 1, integer=True) or not finite(m.get('arrival_tick'), integer=True)
            or not all(finite(m.get(k), -1e7, 1e7) for k in ('x', 'y'))
            or m.get('surface') not in ('nauvis', 'vulcanus', 'gleba', 'fulgora', 'aquilo')
            or m.get('state') not in ('in_transit', 'waiting', 'quarantined')):
            continue
        key = (a, b, m['id'], name)  # Fill ids are pair-local; swaps have two legs.
        if key in seen: continue
        seen.add(key)
        out['markers'].append({**{k: m[k] for k in ('id', 'from', 'to', 'count', 'x', 'y', 'surface', 'state', 'arrival_tick')}, 'item': name})
    seen = set()
    for p in sorted(rows(raw.get('last_prices')), key=lambda v: obj(v).get('tick') if finite(obj(v).get('tick')) else -1, reverse=True):
        p = obj(p); a, b, name = p.get('a'), p.get('b'), item(p.get('item'))
        if (not pair(a, b) or not name or not finite(p.get('price'), 1, integer=True)
            or not finite(p.get('count'), 1, integer=True) or not finite(p.get('prints'), 1, integer=True)
            or not finite(p.get('tick'), 0, tick, integer=True) or type(p.get('thin')) is not bool):
            continue
        key = (*sorted((a, b)), name)
        if key in seen: continue
        seen.add(key)
        out['last_prices'].append({**{k: p[k] for k in ('a', 'b', 'price', 'count', 'tick', 'prints')},
                                   'item': name, 'thin': p['prints'] == 1})
        if len(out['last_prices']) == 30: break
    return out


def project_viewers(messages, now, teams=()):
    """Already-moderated viewer rows, never team chat or raw delivery explanations.

    The relay owns moderation/routing. An explicit source and recent timestamp are
    required; targets and delivery are receipts, not inferred from the message text.
    Replacement semantics let the producer remove moderated/deleted messages.
    """
    out = []
    for m in map(obj, rows(messages)[-32:]):
        source = m.get('source')
        if source not in ('site', 'youtube') or m.get('lane') not in (None, 'viewer') or m.get('kind') not in (None, 'viewer'):
            continue
        if any(m.get(k) for k in ('agent', 'from', 'tell', 'operator', 'confess', 'team', 'force')):
            continue
        stamp, text = number(m.get('t')), speech(m.get('text'), ('Nick', 'Winter'), viewer=True)
        if not text or stamp is None or stamp != m.get('t') or not -5 <= now - stamp <= 600:
            continue
        targets = []
        delivery = m.get('delivery') if m.get('delivery') in ('operator', 'held', 'not_relayed') else None
        out.append({'name': 'Viewer', 'source': source, 'text': text, 't': stamp,
                    'targets': targets, 'delivery': delivery})
        if source == 'site' and isinstance(m.get('id'), str) and re.fullmatch(r'site:[0-9]{1,20}', m['id']):
            out[-1]['id'] = m['id']  # public site sequence, for mt290's separate receipt map
    return out[-8:]


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
    """Deliberate allowlist. The roster decides who is on a team; names, colours and personas the
    agents chose are rebuilt by identity(), never copied from the feed."""
    state, score = obj(state), obj(score)
    research, science, space = (obj(state.get(k)) for k in ('research', 'science', 'space'))
    current = {a.get('name'): a for a in rows(state.get('agents')) if isinstance(a, dict) and isinstance(a.get('name'), str)}
    public_names = {a['name'] for a in agents}
    private_names = [n for n in ('Nick', 'Winter') if n.lower() not in public_names] + [s for a in current.values() if a.get('name') not in public_names
                     for s in (a.get('name'), a.get('display_name')) if isinstance(s, str)]
    freshness = number(state.get('poll_ok') if 'poll_ok' in state else state.get('now'), 0)
    tick = number(state.get('tick'))
    done = number(research.get('done_count'))
    # Some startup feeds lag the separate force score. Do not make up a zero.
    score_done = score.get('research')
    if isinstance(score_done, (list, dict)) and (done is None or number(score.get('tick'), 0) >= (tick or 0)):
        done = len(score_done)
    tech = prototype('tech', research.get('current'))
    board, tasks = [], {}
    b = obj(state.get('board'))
    for m in map(obj, rows(b.get('doing_items')) + rows(b.get('open_items')) + rows(b.get('claims'))):
        owner, title_text = m.get('owner'), speech(m.get('title'), private_names)
        if title_text and (owner is None or owner == '' or isinstance(owner, str) and owner in public_names):
            board.append({'title': title_text, 'owner': owner or '', 'id': number(m.get('id'))})
            if owner:
                tasks.setdefault(owner, title_text[:80])
    out_agents = []
    for a in agents:
        live = obj(current.get(a['name']))
        activity = live.get('activity') if isinstance(live.get('activity'), str) and live['activity'] in ACTIVITY else None
        active = live.get('active') if isinstance(live.get('active'), str) else ''
        verb, _, what = active.partition(':')
        item = prototype('item', what)
        action = ACTIONS.get(verb) if activity == 'acting' else None
        if action and item:
            action += ' ' + title(item).lower()
        action = action or {'thinking': 'Planning the next move', 'resting': 'Between turns',
                            'idle': 'Waiting for the next move', 'offline': 'Agent offline',
                            'dead': 'Waiting to respawn'}.get(activity, 'Working in the factory' if activity == 'acting' else None)
        p = obj(live.get('position'))
        pos = {k: number(p.get(k), lo=-1e7, hi=1e7) for k in ('x', 'y')}
        idle = number(live.get('idle_s'), hi=86400)
        row = {'name': a['name'], 'model': speech(a.get('model'))[:60], 'activity': activity, 'action': action,
               # What kind of action is running (fight, build, work, walk): an icon and the camera's interest.
               'verb': verb_class(verb) if activity == 'acting' else None,
               'item': item if activity == 'acting' else None,
               'idle_s': None if idle is None else int(idle),
               'task': tasks.get(a['name']),
               'surface': live.get('surface') if live.get('surface') in SURFACES else 'platform' if live.get('on_platform') is True else None,
               'position': pos if all(v is not None for v in pos.values()) and live.get('surface', 'nauvis') == 'nauvis' else None}
        row.update(identity(a, live, private_names))
        out_agents.append(row)
    chat = team_chat(team, state.get('chat'), public_names, private_names, now, tick)

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
            text = next(a['display_name'] for a in out_agents if a['name'] == e['agent']) + ' was lost'
        elif kind == 'platform_lost':
            text, icon = 'Space platform lost', 'space-platform-hub'
        if text and et is not None:
            events.append({'kind': kind, 'text': text, 'tick': et, 'icon': icon,
                           'icon_kind': 'tech' if kind == 'research' else 'item', 'observed': False})
    # The stream's chronicle snapshot intentionally omits research.name. Its
    # research.recent rows carry the safe prototype plus finish/observation tick.
    for r in rows(research.get('recent'))[:4]:
        r = obj(r)
        name, et = prototype('tech', r.get('name')), number(r.get('tick'))
        if name and et is not None:
            events.append({'kind': 'research', 'text': title(name) + ' completed', 'tick': et,
                           'icon': name, 'icon_kind': 'tech', 'observed': True})
    completed = [p for name in list(score_done)[:512] if (p := prototype('tech', name))] if isinstance(score_done, (list, dict)) else None
    return {'team': team, 'stale': now - freshness > 25 or freshness > now + 5 or bool(state.get('poll_error')),
            'tick': tick, 'game_time': clock(tick), 'paused': bool(state.get('paused')), 'agents': out_agents,
            'research': {'current': tech, 'label': title(tech), 'progress': number(research.get('progress'), hi=1), 'done_count': done,
                         'completed': completed},
            'science': {'spm': number(science.get('spm')), 'series': [number(v, 0) for v in rows(science.get('series'))[-30:]],
                        'stage': int(number(science.get('stage'), 0, hi=5)),
                        'packs': [p for p in PACKS if any(obj(m).get('item') == p and number(obj(m).get('total'), 0) > 0
                                                       for m in rows(obj(science.get('made')).get('packs')))]},
            'space': {'rockets': number(space.get('rockets'), number(score.get('rockets')))},
            'entities': entities, 'score_tick': number(score.get('tick')), 'map': mini,
            'chat': chat, 'board': board[:12], 'events': events}


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
            delta = best[0] - k[0]
            gap = f'{delta} startup step' + ('s' if delta != 1 else '') + ' back'
        elif best[0] != k[0]:
            delta = int(best[0] - k[0])
            gap = f'{delta} rocket' + ('s' if delta != 1 else '') + ' back'
        else:
            delta = int(best[1] - k[1])
            gap = f'{delta} tech' + ('s' if delta != 1 else '') + ' back'
        r.update(rank=place, leader=k == best, gap=gap,
                 startup_steps=sum((r['entities'] or {}).get(k, 0) > 0 for k in STARTUP))
    return 'Startup: miner · furnace · engine · lab · assembler' if startup else 'Rank: rockets → technologies completed'


class Race:
    def __init__(self):
        self.previous, self.events, self.seen = {}, deque(maxlen=80), deque(maxlen=400)
        self.built = {}
        self.said = {}  # feed id -> line, in arrival order: speech outlives the team services' short chat windows
        self.ordered = False  # the operator's ordered feed has been seen: it is the only source from then on

    def add(self, team, kind, text, tick, now, icon=None, icon_kind='item', observed=False, other=None):
        key = (team, kind, text, tick)
        if key in self.seen:
            return
        self.seen.append(key)
        ident = hashlib.sha1(f'{team}|{kind}|{text}|{tick}'.encode()).hexdigest()[:12]
        self.events.append({'id': ident, 'team': team, 'kind': kind, 'text': text, 'tick': tick,
                            'time': clock(tick), 'at': now, 'icon': icon, 'icon_kind': icon_kind,
                            'observed': observed, 'other': other})

    def say(self, line):
        if line['id'] not in self.said:
            self.said[line['id']] = line
            while len(self.said) > 240:
                self.said.pop(next(iter(self.said)))

    def update(self, teams, now, contacts=(), pacts=(), diplomacy=(), lines=None):
        """lines: broadcast() rows from the operator's ordered feed, or None when this run has none
        (then speech comes from each team's own chat window and the diplomacy lane)."""
        self.ordered = self.ordered or lines is not None
        for r in teams:
            if r['stale']:
                continue
            t, tick = r['team'], r['tick']
            old = self.previous.get(t)
            # Loading an older save must not create a flood of losses or carry future news.
            if old and tick is not None and old['tick'] is not None and tick < old['tick']:
                self.events = deque((e for e in self.events if e['team'] != t), maxlen=80)
                self.seen = deque((k for k in self.seen if k[0] != t), maxlen=400)
                self.said = {k: m for k, m in self.said.items() if m['team'] != t}
                self.built.pop(t, None)
                old = None
            built = self.built.setdefault(t, set())
            if old is None and r['entities']:
                built.update(k for k, n in r['entities'].items() if n)
            for e in r['events']:
                if tick is not None and 0 <= tick - e['tick'] <= 36000:
                    self.add(t, e['kind'], e['text'], e['tick'], now - (tick - e['tick']) / 60, e['icon'], e['icon_kind'], e['observed'])
            for m in r['chat']:
                # Scoped team lines only; each carries its own team tag and was rebuilt by team_chat().
                if m.get('team') == t and m.get('kind') in ('talk', 'tell') and not self.ordered:
                    self.say({k: m.get(k) for k in ('id', 'team', 'name', 'to', 'kind', 'text', 'tick', 'at', 'reply')})
            if old and tick is not None:
                before, after = old['research']['done_count'], r['research']['done_count']
                if before is not None and after is not None and after > before and not any(e['kind'] == 'research' and e['tick'] > (old['tick'] or 0) for e in r['events']):
                    was, done = old['research']['completed'], r['research']['completed']
                    names = sorted(set(done) - set(was)) if was is not None and done is not None else []
                    if names:
                        for name in names[-4:]:
                            self.add(t, 'research', title(name) + ' completed', r['score_tick'] or tick, now, name, 'tech', observed=True)
                    else:
                        count = int(after-before)
                        self.add(t, 'research', f'{count} ' + ('technology' if count == 1 else 'technologies') + ' completed', tick, now, 'lab', observed=True)
                if r['space']['rockets'] is not None and old['space']['rockets'] is not None and r['space']['rockets'] > old['space']['rockets'] and not any(e['kind'] == 'rocket' and e['tick'] > (old['tick'] or 0) for e in r['events']):
                    self.add(t, 'rocket', 'First rocket launched' if old['space']['rockets'] == 0 else 'Rocket launched', tick, now, 'rocket-part', observed=True)
                if r['entities'] is not None and old['entities'] is not None:
                    for item in BUILDINGS:
                        n, b = r['entities'][item], old['entities'][item]
                        if n > b and (b == 0 or item in ('lab', 'assembling-machine-1', 'electric-mining-drill')):
                            first = item not in built
                            self.add(t, 'build', ('First ' if first else f'+{n-b} ') + title(item).lower() + (' built' if first else f' · {n} total'), r['score_tick'] or tick, now, item, observed=True)
                        if n:
                            built.add(item)
            self.previous[t] = r
        known = {r['team'] for r in teams}
        latest = max((r['tick'] or 0 for r in teams), default=0)
        for c in contacts:
            c = obj(c)
            team, other = c.get('team'), c.get('other')
            if isinstance(team, str) and isinstance(other, str) and team in known and other in known and number(c.get('tick')) is not None and c.get('kind') in ('chart', 'shot'):
                text = ('First shots at ' if c['kind'] == 'shot' else 'First contact with ') + other.capitalize()
                if c['tick'] <= latest:
                    self.add(team, 'contact', text, c['tick'], now - (latest - c['tick']) / 60, 'radar', other=other)
        for r in teams:
            r['pacts'] = []
        for p in pacts:
            p = obj(p)
            a, b, status, ident = p.get('a'), p.get('b'), p.get('status'), p.get('id')
            if not (isinstance(a, str) and isinstance(b, str) and a in known and b in known and a != b
                    and type(ident) is int and ident > 0 and status in PACT_TEXT):
                continue
            key = 'accepted_tick' if status == 'active' else 'proposed_tick' if status == 'proposed' else 'ended_tick'
            tick = number(p.get(key))
            if tick is not None and 0 <= tick <= latest:
                self.add(a, 'pact', PACT_TEXT[status].format(id=ident, other=b.capitalize()), tick,
                         now - (latest - tick) / 60, 'steel-chest', other=b)
            if status == 'active':
                for r in teams:
                    if r['team'] in (a, b):
                        r['pacts'].append({'id':ident, 'with': b if r['team'] == a else a})
        for m in lines or ():
            event = m.get('event', 'fill')
            system = (m.get('kind') == 'market' and m.get('system') is True and m.get('name') == 'Trading Post'
                      and ((event in ('fill', 'embargo') and m.get('to_team') in known and m['to_team'] != m['team'])
                           or (event in ('coinage', 'raid') and not m.get('to_team'))))
            if m['team'] in known and (system or any(a['name'] == m['name'] for r in teams if r['team'] == m['team'] for a in r['agents'])):
                self.say(dict(m, reply=False))
        for m in () if self.ordered else diplomacy:
            # Already rebuilt by diplomacy(): explicit cross-team messages, one pair-local sequence each.
            pair = '-'.join(sorted((m['from_team'], m['to_team'])))
            self.say({'id': f"dip:{pair}:{m['seq']}", 'team': m['from_team'], 'name': m['agent'], 'to': [],
                      'to_team': m['to_team'], 'kind': 'diplomacy', 'text': m['text'], 'tick': m['tick'],
                      'at': now - max(0, latest - m['tick']) / 60, 'reply': False})
        basis = rank(teams)
        feed = sorted(self.said.values(), key=lambda m: (m['at'] or 0, m['tick'] or 0))[-40:]
        return {'teams': teams, 'events': sorted(self.events, key=lambda e: e['tick'] or 0, reverse=True)[:12],
                'ranking': basis, 'feed': feed}


# ---- camera -------------------------------------------------------------------------------------------------------
ACTION, WARM = 3.0, 1.5  # a subject at ACTION is doing something now; under WARM it has stood for a while
DOING = {'fight': 10.0, 'build': 8.0, 'work': 5.0, 'walk': 3.0}
NEWS = {'rocket': 10, 'death': 9, 'platform_lost': 9, 'contact': 8, 'pact': 8, 'research': 6, 'build': 4}


def subjects(state, names, now):
    """The director's private view of one team's raw feed: where each roster agent is and how much
    it is doing. Never published; only the chosen agent's name reaches the camera label.

    A running action counts most (the stream director's own classes); a request that just changed
    the map (`did`) and the stream's decaying `interest` keep a builder in view between calls; an
    agent whose character has stood idle (`idle_s`), rests or is offline counts for almost nothing.
    """
    out = []
    for a in map(obj, rows(obj(state).get('agents'))):
        name, surface, p = a.get('name'), a.get('surface'), obj(a.get('position'))
        x, y = (number(p.get(k), lo=-1e7, hi=1e7) for k in ('x', 'y'))
        if (not isinstance(name, str) or name not in names or a.get('alive') is False or x is None or y is None
                or not isinstance(surface, str) or not re.fullmatch(r'[a-z0-9_-]{1,40}', surface)):
            continue
        activity = a.get('activity') if a.get('activity') in ACTIVITY else None
        kind = verb_class(str(a.get('active') or '').partition(':')[0]) if isinstance(a.get('active'), str) else None
        if a.get('combat') is True:
            kind = 'fight'
        doing = DOING.get(kind, 3.0 if activity == 'acting' else 0.0) if activity in ('acting', None) or kind == 'fight' else 0.0
        did = obj(a.get('did'))
        age = now - did['t'] if number(did.get('t')) is not None else None
        fresh = 6.0 * 0.5 ** (age / 20) if age is not None and 0 <= age <= 90 else 0.0
        idle = number(a.get('idle_s'), hi=86400)
        still = activity in ('idle', 'resting', 'offline', 'dead') or (idle is not None and idle >= 20 and not doing)
        warm = min(number(a.get('interest'), 0.0, hi=30), 15.0) * 0.3 * (0.25 if still else 1.0)
        out.append({'agent': name, 'surface': surface, 'x': x, 'y': y, 'verb': kind,
                    'score': round(doing + fresh + warm, 3), 'idle': idle})
    return out


class Director:
    """Minimum dwell, then where agents are doing things; oldest-first fairness, successful cuts only.

    Order of rules, after the minimum dwell: (1) a team unseen for dwell x max(2, teams) gets the
    camera, oldest first; (2) fresh news elsewhere; (3) leave a shot where nobody is acting for a team
    where someone is; (4) at the ordinary dwell move to another acting team, or stay with the only one
    acting, or rotate when nobody is; (5) within the team on air, turn to the agent who is acting.
    A team where nobody has moved for a while still gets its turn, at twice the interval while other
    teams are working, and that visit is a glance: it ends at the minimum dwell.
    """
    def __init__(self, dwell=30):
        self.minimum = max(10, min(20, dwell / 2))
        self.dwell = dwell
        self.current, self.since = None, 0
        self.shown, self.retry, self.started = {}, {}, None
        self.subject, self.glance, self.pending = None, False, None

    @staticmethod
    def best(subs):
        return max(subs, key=lambda s: s['score']) if subs else None

    @staticmethod
    def heat(row, subs=None):
        if subs is not None:
            return max((s['score'] for s in subs), default=0.0)
        return max((DOING.get(a.get('verb'), 3.0) if a['activity'] == 'acting' else 0.0 for a in row['agents']), default=0.0)

    def retarget(self, scout):
        subs = scout.get(self.current) or []
        top = self.best(subs)
        if not top or top['agent'] == self.subject or top['score'] < ACTION:
            return None
        on_air = next((s for s in subs if s['agent'] == self.subject), None)
        if on_air and on_air['score'] >= WARM:
            return None  # the agent on air is still at it
        return self.current, 'Following the action'

    def choose(self, teams, events, now, scout=None):
        if self.started is None:
            self.started = now
        scout = scout or {}
        eligible = [r for r in teams if not r['stale'] and not r['paused'] and now >= self.retry.get(r['team'], 0)]
        if not eligible or (self.current and now - self.since < self.minimum):
            return None
        heat = {r['team']: self.heat(r, scout.get(r['team'])) for r in eligible}
        hot = lambda r: heat[r['team']]
        why = lambda r: 'Following the action' if hot(r) >= ACTION else 'Around the teams'
        others = [r for r in eligible if r['team'] != self.current]
        self.pending = None
        if not others:
            return (eligible[0]['team'], why(eligible[0])) if self.current is None else self.retarget(scout)
        age = lambda r: now - self.shown.get(r['team'], self.started - self.dwell)
        busy = any(v >= ACTION for v in heat.values())
        # Standing teams wait twice as long for their turn while someone else is at work.
        overdue = [r for r in others if age(r) >= self.dwell * max(2, len(teams)) * (2 if busy and hot(r) < WARM else 1)]
        if overdue:
            pick = max(overdue, key=age)
            self.pending = (pick['team'], hot(pick) < WARM and busy)
            return pick['team'], why(pick)
        def news(r):
            recent = [e for e in events if e['team'] == r['team'] and now - e['at'] <= 40 and e['at'] > self.shown.get(r['team'], -1)]
            return max((NEWS.get(e['kind'], 0) for e in recent), default=0)
        newsy = max(others, key=lambda r: (news(r), hot(r), age(r)))
        if news(newsy):
            return newsy['team'], 'New milestone'
        hottest = max(others, key=lambda r: (hot(r), age(r)))
        if self.current is None:
            return hottest['team'], why(hottest)
        here, held = heat.get(self.current), now - self.since
        if hot(hottest) >= ACTION and (self.glance or here is None or here < ACTION or held >= self.dwell):
            return hottest['team'], 'Following the action'
        if held >= self.dwell and (here is None or here < ACTION):
            # Nobody is clearly at work: keep moving, warmer teams first, then the longest unseen.
            pick = max(others, key=lambda r: (hot(r) >= WARM, age(r)))
            return pick['team'], 'Around the teams'
        return self.retarget(scout)

    def success(self, team, now, agent=None):
        self.glance = bool(self.pending and self.pending[0] == team and self.pending[1])
        self.pending = None
        self.current, self.since, self.subject = team, now, agent
        self.shown[team] = now

    def failed(self, team, now):
        self.retry[team] = now + 30
