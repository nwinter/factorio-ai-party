"""Public team-test state contract. Only operator-pushed, bounded display fields.

No game or local service discovery. Inputs may come from any operator collector.
"""
import math
import re
import time
import unicodedata
from build import clean, keep_line

COLORS = {'green': '#71c98c', 'yellow': '#e6c85d', 'blue': '#6cacf0', 'red': '#ed7a7a'}
ACTIVITY = {'acting', 'thinking', 'resting', 'idle', 'offline', 'dead', 'unknown'}
PRIVATE = re.compile(r'https?://|(?:^|[\s(])(?:/|~/|[A-Za-z]:[\\/])|[\w.+-]+@[\w.-]+\.[a-z]{2,}|'
                     r'\b(?:token|password|secret|api[_ -]?key|traceback|exception)\b|\bsk-[\w-]+|'
                     r'\b' + 'multi' + r'-?teams?\b|\bPOG_[A-Z_]+|\bmt/batch\d+', re.I)


def obj(v):
    return v if isinstance(v, dict) else {}


def rows(v):
    return v if isinstance(v, list) else []


def number(v, hi=1e12):
    return v if type(v) in (int, float) and math.isfinite(v) and 0 <= v <= hi else None


def text(v, limit=300):
    if not isinstance(v, str) or PRIVATE.search(v) or not keep_line(v) or clean(v) != v:
        return ''
    return re.sub(r'\s+', ' ', v).strip()[:limit]


def identity(v):
    return v if isinstance(v, str) and re.fullmatch(r'[a-z][a-z0-9_-]{0,15}', v) and text(v) else None


# Words a chosen character name may not be: a reader could take them for the site or its staff.
STAFF = {'server', 'operator', 'mod', 'moderator', 'admin', 'caster', 'system', 'host', 'viewer', 'viewers',
         'youtube', 'site', 'staff'}


def chosen_name(v):
    """A character name an agent chose: letters, digits and light punctuation, 2 to 24 characters."""
    if not isinstance(v, str) or len(v) > 200 or not text(v, 200) or re.search(r'[<>{}\[\]\\]', v):
        return ''
    kept = ''
    for c in unicodedata.normalize('NFC', v):
        if unicodedata.category(c)[0] in 'LN' or c in ".'’-&!":
            kept += c
        elif c.isspace() or c == '_':
            kept += ' '
    kept = re.sub(r'\s+', ' ', kept).strip(" .'’-&")[:24].strip(" .'’-&")
    if len(kept) < 2 or any(w in STAFF for w in re.findall(r'[a-z]+', kept.lower())):
        return ''
    return kept


def glyph(v):
    """One or two characters or an emoji shown beside a name; never spaces, markup or control characters."""
    if not isinstance(v, str) or not 1 <= len(v) <= 8:
        return ''
    for c in v:
        cat = unicodedata.category(c)
        if cat[0] in 'CZ' and c not in '\u200d\ufe0f' or c in '<>&"\'\\/':
            return ''
    return v


def public_state(raw, video=None, now=None, hidden=None):
    now = time.time() if now is None else now
    raw = obj(raw)
    at = number(raw.get('now'))
    out = {'schema': 1, 'mode': 'team-tests', 'now': now, 'active': False, 'teams': []}
    if at is None or not -5 <= now - at <= 30:
        return out
    for row in rows(raw.get('teams'))[:4]:
        r = obj(row)
        name = r.get('team')
        if not isinstance(name, str) or name not in COLORS or any(t['team'] == name for t in out['teams']):
            continue
        agents = []
        for a in map(obj, rows(r.get('agents'))[:12]):
            n = identity(a.get('name'))
            if not n or any(x['name'] == n for x in agents):
                continue
            agent = {'name': n, 'model': text(a.get('model'), 60),
                     'activity': a.get('activity') if isinstance(a.get('activity'), str) and a.get('activity') in ACTIVITY else 'unknown'}
            # The character the agent chose to be. The roster id above stays the stable name.
            shown, color, pronouns = chosen_name(a.get('display_name')), a.get('color'), a.get('pronouns')
            if shown and shown.lower() != n:
                agent['display_name'] = shown
            for key, value in (('persona', text(a.get('persona'), 160)), ('glyph', glyph(a.get('glyph')))):
                if value:
                    agent[key] = value
            if isinstance(color, str) and re.fullmatch(r'#[0-9a-fA-F]{6}', color):
                agent['color'] = color.lower()
            if isinstance(pronouns, str) and re.fullmatch(r'(?:he|she|they|it|xe|ze|ey|fae)(?:/[a-z]{2,8}){0,2}', pronouns):
                agent['pronouns'] = pronouns
            agents.append(agent)
        members = {a['name'] for a in agents}
        chat = []
        for m in map(obj, rows(r.get('chat'))[-12:]):
            body = text(m.get('text'), 500)
            if isinstance(m.get('name'), str) and m.get('name') in members and body:
                line = {'name': m['name'], 'text': body, 'tick': number(m.get('tick'))}
                # A line told to named teammates (or the whole team); otherwise ordinary team talk.
                to = rows(m.get('to'))
                if m.get('kind') == 'tell' and to and all(isinstance(t, str) and (t in members or t == 'team') for t in to):
                    line['to'] = list(dict.fromkeys(to))[:8]
                chat.append(line)
        board = []
        for m in map(obj, rows(r.get('board'))[:12]):
            title = text(m.get('title'))
            owner = m.get('owner')
            if title and (not owner or isinstance(owner, str) and owner in members):
                board.append({'title': title, 'owner': owner or ''})
        research = obj(r.get('research'))
        out['teams'].append({'team': name, 'color': COLORS[name], 'stale': r.get('stale') is not False,
                             'agents': agents, 'chat': chat, 'board': board, 'tick': number(r.get('tick')),
                             'research': {'label': text(research.get('label'), 80),
                                          'progress': number(research.get('progress'), 1),
                                          'done_count': number(research.get('done_count'))},
                             'spm': number(obj(r.get('science')).get('spm')),
                             'rockets': number(obj(r.get('space')).get('rockets'))})
    out['active'] = bool(out['teams']) and raw.get('active') is not False
    vid = video or obj(raw.get('stream')).get('youtube_video_id')
    if isinstance(vid, str) and re.fullmatch(r'[A-Za-z0-9_-]{11}', vid):
        out['stream'] = {'youtube_video_id': vid}
    yt = []
    for m in map(obj, rows(raw.get('viewers'))[-30:]):
        body = text(m.get('text'), 500)
        if m.get('source') != 'youtube' or not body or (hidden and hidden.hides(m.get('name'), body)):
            continue
        ident = m.get('id')
        if isinstance(ident, str) and re.fullmatch(r'[A-Za-z0-9_.:=-]{1,120}', ident) and number(m.get('t')) is not None:
            yt.append({'id': ident, 'name': text(m.get('name'), 32) or 'Viewer', 'text': body, 't': m['t']})
    out['youtube_chat'] = yt
    # Each receipt describes all launched teams, never a misleading first success.
    out['viewer_delivery'] = {}
    for seq, raw_receipt in list(obj(raw.get('viewer_delivery')).items())[-300:]:
        r = obj(raw_receipt)
        if not str(seq).isdigit() or r.get('s') not in ('relayed', 'held', 'not_relayed', 'expired', 'operator'):
            continue
        to = [t for t in rows(r.get('teams')) if isinstance(t, str) and t in COLORS]
        out['viewer_delivery'][str(seq)] = {'s': r['s'], 'to': ', '.join(to), 't': number(r.get('t')),
                                          'why': 'All teams' if r['s'] == 'relayed' else 'Waiting for all teams' if r['s'] == 'held' else r['s']}
    read = number(obj(raw.get('viewer_read')).get('after'))
    if read is not None:
        out['viewer_read'] = {'after': int(read)}
    return out
