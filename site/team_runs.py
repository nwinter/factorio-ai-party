"""Team run pages and durable, allowlisted spectator history. Never an agent input."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sqlite3
import time

import team_tests as display

_spec = importlib.util.spec_from_file_location('site_public_race', Path(__file__).resolve().parents[1] / 'tools/mt/public_race.py')
race = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(race)
PAGE_SIZE = 100


def duration(tick):
    minutes = int((tick or 0) / 3600)
    hours, minutes = divmod(minutes, 60)
    days, hours = divmod(hours, 24)
    return f"{days}d {hours}h {minutes}m"


def run_id(value):
    return value if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', value) else None


def project(raw, ident, now=None):
    """Rebuild a spectator snapshot; never copy operator dictionaries or ranking text."""
    raw = display.obj(raw)
    ident = run_id(ident)
    at = display.number(raw.get('now'))
    if not ident or at is None:
        return None
    now = time.time() if now is None else now
    base = display.public_state(raw, now=at)
    fresh = -5 <= now - at <= 30
    source = {r.get('team'): r for r in map(display.obj, display.rows(raw.get('teams')))
              if isinstance(r.get('team'), str)}
    teams = []
    known = {row['team'] for row in base['teams']}
    wallets = display.obj(display.obj(raw.get('market')).get('wallets'))
    for row in base['teams']:
        src = source[row['team']]
        wallet = display.obj(wallets.get(row['team']))
        coins, reserved = display.number(wallet.get('wallet')), display.number(wallet.get('reserved'))
        if coins is None or reserved is None or reserved > coins:
            coins = reserved = None
        entities = display.obj(src.get('entities'))
        teams.append({k: row[k] for k in ('team', 'color', 'agents', 'tick')} | {
            'stale': row['stale'] or not fresh,
            'race': race.project_race(src.get('race')),
            'entities': {k: display.number(entities.get(k)) or 0 for k in race.STARTUP} if entities else None,
            'coins': coins, 'reserved': reserved,
            'pacts': [{'id': p['id'], 'with': p['with']} for p in map(display.obj, display.rows(src.get('pacts')))
                      if type(p.get('id')) is int and p['id'] > 0 and isinstance(p.get('with'), str) and p['with'] in known and p['with'] != row['team']][:12]})
    ranking = race.rank(teams)
    result = race.project_result(raw.get('result'), teams)
    tick = max((t['tick'] or 0 for t in teams), default=0)
    if result and result['tick'] > tick:
        result = None
    known = {t['team'] for t in teams}
    events = []
    for e in map(display.obj, display.rows(raw.get('events')) + display.rows(raw.get('feed'))):
        kind = e.get('kind')
        if kind not in ('milestone', 'contact', 'pact', 'game', 'market', 'diplomacy'):
            continue
        body, et = display.text(e.get('text'), 500), display.number(e.get('tick'))
        if not body or not isinstance(e.get('team'), str) or e['team'] not in known or et is None or et > tick:
            continue
        other = e.get('other') or e.get('to_team')
        row = {'kind': kind, 'team': e['team'], 'other': other if isinstance(other, str) and other in known else None,
               'tick': et, 'text': body}
        row['id'] = hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest()[:24]
        events.append(row)
    return {'schema': 1, 'id': ident, 'now': at, 'tick': tick,
            'status': 'ended' if result else 'live' if fresh and base['active'] else 'unavailable',
            'ranking': ranking, 'teams': teams, 'result': result,
            'events': sorted(events, key=lambda e: (e['tick'], e['id']))[-100:]}


def fit_live(state, limit=240 * 1024):
    """Keep the added live history within the worker's 256 KiB state limit.

    The durable archive is saved first and retains every projected event.
    """
    if 'team_run' not in state:
        return
    state['team_run'] = dict(state['team_run'], events=list(state['team_run']['events']))
    def size():
        return len(json.dumps(state, separators=(',', ':')).encode())
    while state['team_run']['events'] and size() > limit:
        state['team_run']['events'].pop(0)
    if size() > limit:
        # An already-full legacy payload must not fail because of this addition.
        state.pop('team_run')


def restore(snapshot):
    """Saved pages pass through the same allowlist again, including final results."""
    s = display.obj(snapshot)
    raw = {'now': s.get('now'), 'teams': s.get('teams'), 'result': s.get('result'), 'events': s.get('events'),
           'market': {'wallets': {t['team']: {'wallet': t.get('coins'), 'reserved': t.get('reserved')}
                                 for t in map(display.obj, display.rows(s.get('teams'))) if isinstance(t.get('team'), str)}}}
    out = project(raw, s.get('id'), now=s.get('now'))
    if out:
        out['status'] = 'ended' if out['result'] else 'archived'
    return out


class Archive:
    """SQLite deduplicates event history across restarts; only constructed public fields are written."""
    def __init__(self, folder, ident):
        if not run_id(ident):
            raise ValueError('invalid team run id')
        self.folder, self.ident = Path(folder), ident
        self.folder.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.folder / 'events.sqlite')
        self.db.execute('CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, tick REAL, body TEXT)')
        self.db.execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)')
        self.db.commit()

    def save(self, state):
        state = restore(state)
        if not state or state['id'] != self.ident:
            raise ValueError('invalid public team snapshot')
        with self.db:
            meta = dict(self.db.execute('SELECT key, value FROM meta'))
            epoch = int(meta.get('epoch', 0))
            if state['tick'] < float(meta.get('tick', 0)):
                epoch += 1
                self.db.execute('INSERT OR IGNORE INTO events VALUES (?, ?, ?)',
                    (f'restore:{epoch}', state['tick'], json.dumps({'id': f'restore:{epoch}', 'kind': 'restore',
                     'tick': state['tick'], 'team': '', 'text': 'A saved world was restored. Earlier events remain in the archive.'})))
            for row in state['events']:
                self.db.execute('INSERT OR IGNORE INTO events VALUES (?, ?, ?)',
                                (f'{epoch}:{row["id"]}', row['tick'], json.dumps(row)))
            for k, v in {'epoch': epoch, 'tick': state['tick']}.items():
                self.db.execute('INSERT OR REPLACE INTO meta VALUES (?, ?)', (k, str(v)))
        tmp = self.folder / 'state.tmp'
        tmp.write_text(json.dumps(state, allow_nan=False) + '\n')
        tmp.replace(self.folder / 'state.json')

    def close(self):
        self.db.close()


def load(runs_dir):
    found = []
    for p in sorted(Path(runs_dir).glob('*/op/public-site/state.json')):
        try:
            row = restore(json.loads(p.read_text()))
        except (OSError, ValueError, TypeError):
            continue
        if row and row['id'] == p.parents[2].name:
            found.append((row, p.parent))
    return sorted(found, key=lambda r: r[0]['now'], reverse=True)


def event_pages(folder, state):
    """Stream fixed-size archive pages; never load a days-long log into a browser."""
    path = Path(folder) / 'events.sqlite'
    if not path.exists():
        yield sorted(state['events'], key=lambda e: (e['tick'], e['id']), reverse=True)
        return
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
    try:
        batch = []
        # IDs carry the save-restore epoch. Within each epoch, late-observed facts
        # belong at their game tick, rather than at the end of the observation log.
        order = "CASE WHEN id LIKE 'restore:%' THEN CAST(substr(id, 9) AS INTEGER) ELSE CAST(id AS INTEGER) END"
        for (body,) in db.execute(f'SELECT body FROM events ORDER BY {order} DESC, tick DESC, rowid DESC'):
            try:
                row = json.loads(body)
                if row.get('kind') == 'restore':
                    row = {'kind': 'restore', 'team': '', 'tick': display.number(row.get('tick')),
                           'text': 'A saved world was restored. Earlier events remain in the archive.'}
                else:
                    raw = {'now': state['now'], 'teams': state['teams'], 'events': [row]}
                    # Past timelines may contain ticks beyond the restored world's current tick.
                    raw['teams'] = [dict(t, tick=max(t['tick'] or 0, display.number(row.get('tick')) or 0)) for t in state['teams']]
                    rows = project(raw, state['id'], now=state['now'])['events']
                    if not rows:
                        continue
                    row = rows[0]
            except (ValueError, TypeError, AttributeError):
                continue
            batch.append(row)
            if len(batch) == PAGE_SIZE:
                yield batch
                batch = []
        if batch:
            yield batch
    finally:
        db.close()


def shell(api, esc, ident=None, archive=False):
    title = 'Team run ' + ident if ident else 'Team runs'
    return (f'<h1>{esc(title)}</h1><p class="lede">The race to the solar system’s edge.</p>'
            f'<section id="team-run" data-api="{esc(api)}" data-run="{esc(ident or "")}" '
            f'data-archive="{str(archive).lower()}" aria-label="Team run progress">'
            '<p id="team-run-status" role="status">Waiting for a team run snapshot.</p><div id="team-run-result"></div>'
            '<p>Places follow milestones toward the edge, then who reached them first. Coin is shown separately.</p>'
            '<div id="team-run-teams" class="team-run-grid"></div>'
            '<h2>Contacts, pacts and trades</h2><div id="team-run-events"></div></section>')


def build(runs_dir, write, page, esc, api):
    bundled = Path(__file__).resolve().parent / 'content/team-runs'
    by_id = {s['id']: (s, folder) for s, folder in load(bundled) + load(runs_dir)}
    archives = sorted(by_id.values(), key=lambda pair: pair[0]['now'], reverse=True)
    links = ''.join(f'<li><a href="/teams/{esc(s["id"])}/">{esc(s["id"])}</a> · '
                    f'{"Game over" if s["result"] else "Archived snapshot; no recorded result"} · '
                    f'{esc(duration(s["tick"]))} game time</li>' for s, _ in archives)
    head = '<link rel="stylesheet" href="/static/team-runs.css"><script src="/static/team-runs.js" defer></script>'
    body = shell(api, esc) + '<h2>Past team runs and tests</h2><ul>' + (links or '<li>No archived team tests yet.</li>') + '</ul>'
    write('teams/index.html', page('Team runs', body, '/teams/', extra_head=head, path='/teams/'))
    for state, folder in archives:
        ident = state['id']
        write(f'teams/{ident}/state.json', json.dumps(state, allow_nan=False))
        body = shell(api, esc, ident, archive=True) + '<p>Historical test snapshots reflect the rules and records available at the time. Events outside the retained history may be missing.</p><p><a href="/teams/">All team runs</a></p>'
        pages = 0
        for pages, rows in enumerate(event_pages(folder, state), 1):
            write(f'teams/{ident}/events-{pages}.json', json.dumps(rows, allow_nan=False))
        write(f'teams/{ident}/history.json', json.dumps({'pages': pages}))
        body += '<p id="team-run-pagination"><button id="team-run-older" type="button" hidden>Older events</button></p>'
        write(f'teams/{ident}/index.html', page('Team run ' + ident, body, '/teams/', extra_head=head, path=f'/teams/{ident}/'))
