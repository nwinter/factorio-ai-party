"""Read-only public projection of team stream services; one camera, event-aware race director.

No Relay, viewer_say, inbox writes, or HTTP mutation routes. The camera controller
is operator-only and reuses the stream harness and lookcam chart checks.
"""
import concurrent.futures
import http.server
import json
import math
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'stream'))
from harness import Harness
import lookcam
from public_race import project, Race, Director, read_views, icons, speech, project_viewers, rows as list_rows, obj

CAMERA = 'pog-director2'


def feeds(op):
    rows = []
    for line in (op / 'streams.txt').read_text().splitlines():
        if not line.strip():
            continue
        team, url = line.split()
        parsed = urllib.parse.urlsplit(url)
        if not re.fullmatch(r'[a-zA-Z0-9_-]+', team) or parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or not parsed.port:
            raise ValueError('streams.txt must contain TEAM http://127.0.0.1:PORT/')
        if team in [r[0] for r in rows]:
            raise ValueError('duplicate team in streams.txt (remove old entries before starting services)')
        rows.append((team, url.rstrip('/') + '/state.json'))
    if not rows:
        raise ValueError('no team stream services')
    return rows


def fetch(url):
    with urllib.request.urlopen(url, timeout=3) as response:
        return json.load(response)


def roster(tree, run, team):
    agents = []
    for line in (tree / 'runs' / run / team / 'team.tsv').read_text().splitlines():
        if line and not line.startswith('#'):
            name, kind, route, model, effort, label, harness = line.split('\t')
            agents.append({'name': name, 'model': label, 'harness': harness})
    return agents


def target(state):
    # Show the active builder/miner, including work outside the original base core.
    for a in state.get('agents') or []:
        p = a.get('position') or {}
        if a.get('activity') == 'acting' and a.get('surface') and all(type(p.get(k)) in (int, float) for k in ('x', 'y')):
            return a['surface'], p['x'], p['y']
    base = (state.get('basemap') or {}).get('core') or state.get('basemap') or {}
    if all(isinstance(base.get(k), (int, float)) for k in ('x0', 'y0', 'w', 'h', 'cell')) and base['w'] > 0 and base['h'] > 0:
        return 'nauvis', base['x0'] + base['w'] * base['cell'] / 2, base['y0'] + base['h'] * base['cell'] / 2
    for a in state.get('agents') or []:
        p = a.get('position') or {}
        if a.get('surface') and all(isinstance(p.get(k), (int, float)) for k in ('x', 'y')):
            return a['surface'], p['x'], p['y']
    raise ValueError('no base or agent position yet')


def cut(h, state):
    surface, x, y = target(state)
    if not all(math.isfinite(n) for n in (x, y)):
        raise ValueError('invalid camera target')
    player = h.lua(f"local p=game.get_player('{CAMERA}') rcon.print(helpers.table_to_json{{index=p and p.connected and p.index or false}})")
    if not player.get('index'):
        raise ValueError('public camera is not connected')
    # Tighten the frame if the base is near the team's chart edge. No charting,
    # highlights, surface scans, or gameplay changes for the public camera.
    for zoom in (0.6, 0.9, 1.5, 3.0):
        hw, hh = lookcam.frame_half(zoom, 1.0)
        chart = h.lua(lookcam.chart_lua(surface, x, y, hw, hh))
        if chart.get('center') and chart.get('charted') == chart.get('chunks'):
            reply = h.camera({'player': player['index'], 'surface': surface, 'position': {'x': x, 'y': y},
                              'zoom': zoom, 'smooth': False})
            if not reply.get('ok'):
                raise RuntimeError('camera command refused')
            return {'team': h.team, 'surface': surface, 'x': x, 'y': y, 'zoom': zoom}
    raise ValueError('camera frame is not fully charted by this team')


def audience(states, teams, now):
    """Only the already-filtered team feeds; no second reader or relay."""
    lines, deliveries, cursors = {}, {}, []
    for team, state in states.items():
        for m in list_rows(state.get('viewers')):
            m = obj(m)
            projected = project_viewers([m], now, teams)
            ident, stamp = m.get('id'), m.get('t')
            if (projected and isinstance(ident, str) and re.fullmatch(r'[A-Za-z0-9_.:=-]{1,120}', ident)
                    and type(stamp) in (int, float) and math.isfinite(stamp) and 0 <= now - stamp <= 180):
                lines[ident] = dict(projected[0], id=ident)
        status = obj(state.get('viewers_status'))
        cursor = obj(status.get('site')).get('after')
        if type(cursor) is int:
            cursors.append(cursor)
        for r in map(obj, list_rows(status.get('delivery'))):
            ident = r.get('id')
            if isinstance(ident, str) and re.fullmatch(r'site:[0-9]+', ident):
                deliveries.setdefault(ident[5:], {})[team] = r
    receipts = {}
    for seq, by_team in deliveries.items():
        statuses = [v if isinstance(v := obj(by_team.get(t)).get('status'), str) else None for t in teams]
        kind = statuses[0] if len(set(statuses)) == 1 and statuses[0] in ('relayed', 'operator', 'expired', 'not_relayed') else 'held'
        receipts[seq] = {'s': kind, 'teams': [t for t in teams if obj(by_team.get(t)).get('status') == 'relayed'], 't': now}
    out = {'viewers': sorted(lines.values(), key=lambda m: m['t'])[-30:],
           'viewer_status': 'on' if states else 'waiting', 'viewer_delivery': receipts}
    if len(cursors) == len(teams):
        out['viewer_read'] = {'after': min(cursors)}
    return out


class PublicOverlay:
    def __init__(self, op, tree, run, port=8790, dwell=30, youtube=None, camera=True):
        self.op = op
        self.feeds = feeds(op)
        self.race, self.director = Race(), Director(dwell)
        self.rosters = {t: roster(tree, run, t) for t, _ in self.feeds}
        self.harnesses = {t: Harness('imac2', t) for t, _ in self.feeds} if camera else {}
        self.stop = threading.Event()
        self.state = {'teams': [], 'camera': None, 'viewers': [], 'viewer_status': 'off', 'now': 0, 'events': [], 'ranking': 'Awaiting scores'}
        self.lock = threading.Lock()
        self.dwell = dwell
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.split('?')[0] == '/state.json':
                    with owner.lock:
                        body = json.dumps(owner.state).encode()
                    mime = 'application/json'
                elif self.path.split('?')[0] in ('/', '/overlay.html'):
                    body = (HERE / 'public-overlay.html').read_bytes()
                    mime = 'text/html; charset=utf-8'
                elif self.path.split('?')[0] == '/mapview.js':
                    body = (HERE.parents[1] / 'site/static/mapview.js').read_bytes()
                    mime = 'text/javascript; charset=utf-8'
                elif re.fullmatch(r'/static/game/(item|tech|place)/[a-z0-9-]+\.webp', self.path.split('?')[0]):
                    _, _, _, kind, filename = self.path.split('?')[0].split('/')
                    name = filename[:-5]
                    if name not in icons.INDEX.get(kind, set()):
                        self.send_error(404)
                        return
                    body = (icons.GAME / kind / filename).read_bytes()
                    mime = 'image/webp'
                elif self.path == '/health':
                    body, mime = b'ok', 'text/plain'
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', mime)
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        self.http = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
        self.youtube = youtube

    def start(self):
        for fn in (self.http.serve_forever, self.poll):
            threading.Thread(target=fn, daemon=True).start()

    def poll(self):
        previous = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(self.feeds)) as pool:
            while not self.stop.is_set():
                now, rows, fresh, audience_states = time.time(), [], {}, {}
                views = read_views(self.op, now)
                scores = {r['team']: r.get('score') for r in map(obj, list_rows(views.get('teams')))
                          if isinstance(r.get('team'), str) and r['team'] in self.rosters and not obj(r.get('errors')).get('score')}
                pending = [(t, pool.submit(fetch, u)) for t, u in self.feeds]
                for team, job in pending:
                    try:
                        data = job.result()
                        row = project(team, data, self.rosters[team], now, scores.get(team))
                        if not row['stale']:
                            fresh[team] = data
                        if not row['stale']:
                            audience_states[team] = data
                        previous[team] = row
                    except Exception as e:
                        print(f'feed {team}: {type(e).__name__}', flush=True)
                        row = dict(previous.get(team) or project(team, {}, self.rosters[team], now), stale=True)
                    rows.append(row)
                with self.lock:
                    self.state.update(self.race.update(rows, now, list_rows(views.get('contacts'))), now=now,
                                      **audience(audience_states, self.rosters, now))
                    if self.youtube:
                        self.state['stream'] = {'youtube_video_id': self.youtube}
                choice = self.director.choose(rows, self.state['events'], now) if self.harnesses else None
                if choice:
                    team, reason = choice
                    try:
                        camera = cut(self.harnesses[team], fresh[team])
                        since = time.time()
                        self.director.success(team, since)
                        with self.lock:
                            surface = camera['surface'] if camera['surface'] in ('nauvis', 'vulcanus', 'gleba', 'fulgora', 'aquilo') else 'factory'
                            self.state['camera'] = {'team': team, 'surface': surface, 'since': since, 'reason': reason}
                        print(f'camera: {team} {camera}', flush=True)
                    except Exception as e:
                        print(f'camera {team}: {type(e).__name__}', flush=True)
                        self.director.failed(team, time.time())
                self.stop.wait(5)


    def close(self):
        self.stop.set()
        self.http.shutdown()
        self.http.server_close()
