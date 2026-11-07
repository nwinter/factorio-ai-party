"""Source provenance for transient commentary. Uses snapshots already read by the stream; no game reads."""
import hashlib
import json
import re
import time

TTL = 300
TRANSIENT = ('headline', 'next', 'corrections', 'judgement', 'storylines', 'segments')


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, default=str).encode()).hexdigest()[:20]


def revisions(s):
    s = s or {}
    board = s.get('board') or {}
    plan = board.get('plan') or {}
    out = {'plan': fingerprint(plan.get('goals'))}
    for row in plan.get('doing') or []:
        out['plan:' + str(row.get('name') or row.get('agent'))] = fingerprint(row.get('text'))
    research = s.get('research') or {}
    out['research'] = fingerprint({k: research.get(k) for k in ('current', 'name', 'level', 'queue')})
    for a in s.get('agents') or []:
        out['agent:' + str(a.get('name'))] = fingerprint({
            **{k: a.get(k) for k in ('alive', 'surface', 'plan', 'working_on', 'task', 'intent')},
            'said': (a.get('last_said') or {}).get('text')})
    for p in s.get('platforms') or []:
        out['platform:' + str(p.get('name'))] = fingerprint({k: p.get(k) for k in
            ('state', 'location', 'destination', 'route', 'status', 'diagnosis', 'revision')})
    return out


def stamp(s, now=None, ttl=TTL):
    now = time.time() if now is None else now
    return {'source_tick': (s or {}).get('tick'), 'source_t': now,
            'subject_revision': revisions(s), 'news': news(s), 'expires': now + ttl}


def scoped(source, text, agents=()):
    """Bind only the subjects this claim actually names; another agent's new message is not a retraction."""
    text = str(text).lower()
    names = {str(a.get('name') if isinstance(a, dict) else a).lower() for a in agents or []}
    revisions = source.get('subject_revision') or {}
    selected = {k: v for k, v in revisions.items() if ':' not in k or k.split(':', 1)[1].lower() in names
                or re.search(r'(?<!\w)' + re.escape(k.split(':', 1)[1].lower()) + r'(?!\w)', text)}
    return dict(source, subject_revision=selected)


def news(s):
    rows = list((s or {}).get('alerts') or []) + list(((s or {}).get('board') or {}).get('events') or [])
    return sorted({str(r.get('id') or r.get('key') or fingerprint(r)) for r in rows
                   if r.get('kind') in ('loss', 'death', 'retreat', 'correction')})


def invalid(source, current, now=None):
    """Return why this claim must be cancelled. Intentional dated history is handled at prompt construction."""
    now = time.time() if now is None else now
    if source.get('expires') is not None and now >= source['expires']:
        return 'source expired'
    if source.get('source_t') is not None and now - source['source_t'] >= TTL:
        return 'source too old'
    tick, latest = source.get('source_tick'), (current or {}).get('tick')
    if isinstance(tick, (int, float)) and isinstance(latest, (int, float)):
        if latest < tick or latest - tick > TTL * 60:
            return 'source tick expired or run changed'
    revision = revisions(current)
    if any(revision.get(k) != v for k, v in (source.get('subject_revision') or {}).items()):
        return 'subject or plan revised'
    if 'news' in source and set(news(current)) - set(source['news']):
        return 'superseded by loss, retreat or correction'
    return None


def current_analyst(analyst, snapshot=None, now=None):
    an = dict(analyst or {})
    now = time.time() if now is None else now
    # Old producers still expire from the board's receive time; new producers date their original read.
    expired = (an.get('expires') is not None and now >= an['expires']) or an.get('age_s', 0) >= TTL
    if snapshot is not None and invalid(an, snapshot, now):
        expired = True
    if expired:
        for key in TRANSIENT:
            an.pop(key, None)
    return an
