#!/usr/bin/env python3
"""Archive an existing team test's last operator snapshot for the site, offline.

  python3 tools/mt/archive_site.py RUN_DIRECTORY
Only typed public fields are kept; no raw operator files are published.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'site'))
import team_runs
from public_feed import project_feed
from public_race import broadcast, project_market


def snapshot(view, ident):
    at = datetime.strptime(view['t'], '%Y-%m-%d %H:%M:%S').timestamp()
    game = team_runs.display.obj(view.get('game'))
    standings = {r['team']: r for r in team_runs.display.rows(game.get('standings')) if isinstance(r, dict) and isinstance(r.get('team'), str)}
    teams = []
    for row in view.get('teams', []):
        if not isinstance(row, dict) or row.get('team') not in team_runs.display.COLORS:
            continue
        score = team_runs.display.obj(row.get('score'))
        teams.append({'team': row['team'], 'agents': row.get('agents'), 'stale': bool(row.get('errors')),
                      'tick': score.get('tick'), 'race': standings.get(row['team']), 'entities': score.get('entities'), 'pacts': []})
    known = {t['team'] for t in teams}
    events = []
    for c in team_runs.display.rows(view.get('contacts')):
        if isinstance(c, dict) and isinstance(c.get('other'), str) and c['other'] in known and c.get('kind') in ('chart', 'shot'):
            events.append({'team': c.get('team'), 'other': c['other'], 'kind': 'contact', 'tick': c.get('tick'),
                           'text': ('First shots at ' if c['kind'] == 'shot' else 'First contact with ') + c['other'].capitalize()})
    for p in team_runs.display.rows(view.get('pacts')):
        if not isinstance(p, dict) or type(p.get('id')) is not int or not all(isinstance(p.get(k), str) and p[k] in known for k in ('a','b')):
            continue
        status = p.get('status')
        key = {'active': 'accepted_tick', 'proposed': 'proposed_tick', 'ended': 'ended_tick', 'cancelled': 'ended_tick', 'rejected': 'ended_tick'}.get(status)
        if not key:
            continue
        events.append({'team': p['a'], 'other': p['b'], 'kind': 'pact', 'tick': p.get(key),
                       'text': f"Pact #{p['id']} with {p['b'].capitalize()}: {status}"})
        if status == 'active':
            for t in teams:
                if t['team'] in (p['a'], p['b']):
                    t['pacts'].append({'id': p['id'], 'with': p['b'] if t['team'] == p['a'] else p['a']})
    raw = {'now': at, 'teams': teams, 'result': game.get('result'), 'events': events,
           'market': project_market(view.get('market'), teams),
           'feed': broadcast(project_feed(view.get('feed'), teams), teams, at)}
    return team_runs.project(raw, ident, now=at)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run', type=Path)
    args = ap.parse_args()
    if not team_runs.run_id(args.run.name):
        ap.error('invalid run directory name')
    state = snapshot(json.loads((args.run / 'op/views.json').read_text()), args.run.name)
    if not state or not state['teams']:
        ap.error('no recorded teams')
    folder = args.run / 'op/public-site'
    if (folder / 'state.json').exists():
        ap.error('public history already exists; keep the recorded history')
    archive = team_runs.Archive(folder, args.run.name)
    archive.save(state)
    archive.close()
    print(folder)


if __name__ == '__main__':
    main()
