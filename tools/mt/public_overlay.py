"""Read-only public projection of team stream services; one camera, activity-aware race director.

No Relay, viewer_say or inbox writes. HTTP writes are audio playback receipts only. The camera controller
is operator-only and reuses the stream harness and lookcam chart checks.
"""
import concurrent.futures
import copy
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
from public_race import (project, Race, Director, read_views, icons, speech, project_viewers, diplomacy,
                         subjects, broadcast, project_market, rows as list_rows, obj)
from public_feed import project_feed
from public_audio import PublicAudio, AudioRoutes

CAMERA = 'pog-director2'
# The one camera rectangle, in overlay pixels. The OBS scene item (public_stream.setup_obs) and the
# page (state.layout) both read it from here, so the video and its frame cannot drift apart.
CAMERA_RECT = (16, 188, 1408, 792)
# Game zoom by what the agent on air is doing: close for fights and building, wide for walks
# (the stream director's zoom_* x main_scale). A base shot starts wide and tightens to its chart.
ZOOMS = {'fight': 1.5, 'build': 1.4, 'work': 1.25, 'walk': 0.8, None: 1.0}
BASE_ZOOMS = (0.6, 0.9, 1.5, 3.0)
STATIC = {'/': ('public-overlay.html', 'text/html; charset=utf-8'),
          '/overlay.html': ('public-overlay.html', 'text/html; charset=utf-8'),
          '/overlay.js': ('public-overlay.js', 'text/javascript; charset=utf-8'),
          '/mapview.js': ('../../site/static/mapview.js', 'text/javascript; charset=utf-8'),
          # The main stream's own avatar generator: original pixel art, no game sprites.
          '/avatar.js': ('../stream/static/avatar.js', 'text/javascript; charset=utf-8')}
STATIC.update({f'/{name}': (f'../stream/static/{name}', 'text/javascript; charset=utf-8')
               for name in ('audio.js', 'playback-clock.js')})
FONTS = {'titillium-web-400.woff2', 'titillium-web-600.woff2', 'titillium-web-700.woff2',
         'titillium-web-600-italic.woff2', 'big-shoulders-display-var.woff2'}


def asset(path):
    """(body, mime) for one of the page's fixed files, or None. The production server and the
    offline replay share this table; nothing from a run tree is reachable through it."""
    path = path.split('?')[0]
    if path in STATIC:
        name, mime = STATIC[path]
        return (HERE / name).read_bytes(), mime
    if path.startswith('/fonts/') and path[7:] in FONTS:
        return (HERE / 'fonts' / path[7:]).read_bytes(), 'font/woff2'
    if re.fullmatch(r'/static/game/(item|tech|place)/[a-z0-9-]+\.webp', path):
        _, _, _, kind, filename = path.split('/')
        if filename[:-5] in icons.INDEX.get(kind, set()):
            return (icons.GAME / kind / filename).read_bytes(), 'image/webp'
    return None


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
    """The launch roster: name, model label and harness, plus any identity seeds the launcher
    adds after the seven fixed columns. A `# name<TAB>kind...` header names those columns
    (color, glyph or icon, display_name, persona); without one they are ignored."""
    agents, extra = [], []
    for line in (tree / 'runs' / run / team / 'team.tsv').read_text().splitlines():
        if line.startswith('#'):
            cols = [c.strip().lower() for c in line.lstrip('# ').split('\t')]
            extra = cols[7:] if cols[:1] == ['name'] else extra
        elif line:
            fields = line.split('\t')
            name, kind, route, model, effort, label, harness = fields[:7]
            agent = {'name': name, 'model': label, 'harness': harness}
            for key, value in zip(extra, fields[7:]):
                key = {'colour': 'color', 'display': 'display_name', 'emoji': 'glyph'}.get(key, key)
                if key in ('color', 'glyph', 'icon', 'display_name', 'persona') and value.strip() not in ('', '-'):
                    agent[key] = value.strip()
            agents.append(agent)
    return agents


def base_core(state):
    base = (state.get('basemap') or {}).get('core') or state.get('basemap') or {}
    if all(isinstance(base.get(k), (int, float)) for k in ('x0', 'y0', 'w', 'h', 'cell')) and base['w'] > 0 and base['h'] > 0:
        return 'nauvis', base['x0'] + base['w'] * base['cell'] / 2, base['y0'] + base['h'] * base['cell'] / 2
    return None


def target(state):
    # Show the active builder/miner, including work outside the original base core.
    for a in state.get('agents') or []:
        p = a.get('position') or {}
        if a.get('activity') == 'acting' and a.get('surface') and all(type(p.get(k)) in (int, float) for k in ('x', 'y')):
            return a['surface'], p['x'], p['y']
    core = base_core(state)
    if core:
        return core
    for a in state.get('agents') or []:
        p = a.get('position') or {}
        if a.get('surface') and all(isinstance(p.get(k), (int, float)) for k in ('x', 'y')):
            return a['surface'], p['x'], p['y']
    raise ValueError('no base or agent position yet')


def shots(state, subject=None):
    """What to try, best first: follow the agent who is doing something; else the base while its labs
    are running (machines move even when nobody does); else the agent who moved most recently, so a
    character is on screen rather than a silent base; else the base; else any located agent."""
    out = []
    follow = lambda zooms: {'kind': 'follow', 'agent': subject['agent'], 'surface': subject['surface'],
                            'x': subject['x'], 'y': subject['y'], 'zooms': zooms}
    core = base_core(state)
    base = core and {'kind': 'base', 'agent': None, 'surface': core[0], 'x': core[1], 'y': core[2], 'zooms': BASE_ZOOMS}
    spm = obj(state.get('science')).get('spm')
    running = type(spm) in (int, float) and math.isfinite(spm) and spm > 0
    if subject and subject['score'] >= 3.0:
        first = ZOOMS.get(subject['verb'], 1.0)
        out.append(follow(tuple(z for z in sorted({first, 1.5, 2.2, 3.0}) if z >= first)))
    if base and running:
        out.append(base)
    if subject and not out:
        out.append(follow((1.0, 1.5, 2.2, 3.0)))
    if base and base not in out:
        out.append(base)
    if not out:
        surface, x, y = target(state)
        out.append({'kind': 'spot', 'agent': None, 'surface': surface, 'x': x, 'y': y, 'zooms': BASE_ZOOMS})
    return out


def cut(h, state, subject=None, smooth=False):
    plans = shots(state, subject)
    if not all(math.isfinite(n) for s in plans for n in (s['x'], s['y'])):
        raise ValueError('invalid camera target')
    player = h.lua(f"local p=game.get_player('{CAMERA}') rcon.print(helpers.table_to_json{{index=p and p.connected and p.index or false}})")
    if not player.get('index'):
        raise ValueError('public camera is not connected')
    # Tighten the frame if it is near the team's chart edge. No charting,
    # highlights, surface scans, or gameplay changes for the public camera.
    for shot in plans:
        for zoom in shot['zooms']:
            hw, hh = lookcam.frame_half(zoom, 1.0)
            chart = h.lua(lookcam.chart_lua(shot['surface'], shot['x'], shot['y'], hw, hh))
            if chart.get('center') and chart.get('charted') == chart.get('chunks'):
                body = {'player': player['index'], 'zoom': zoom, 'smooth': bool(smooth)}
                if shot['kind'] == 'follow':
                    body['follow'] = shot['agent']  # the game eases the view after a walking agent
                else:
                    body.update(surface=shot['surface'], position={'x': shot['x'], 'y': shot['y']})
                reply = h.camera(body)
                if not reply.get('ok'):
                    raise RuntimeError('camera command refused')
                return {'team': h.team, 'surface': shot['surface'], 'x': shot['x'], 'y': shot['y'], 'zoom': zoom,
                        'kind': shot['kind'], 'agent': shot['agent']}
    raise ValueError('camera frame is not fully charted by this team')


def audience(states, teams, now):
    """The single moderated operator feed; no playing-team receipts are accepted."""
    lines, deliveries, cursors = {}, {}, []
    for team, state in states.items():
        if team!='operator':continue
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
        kind = obj(by_team.get('operator')).get('status')
        kind = kind if kind in ('operator', 'expired', 'not_relayed') else 'held'
        receipts[seq] = {'s': kind, 'teams': [], 't': now}
    out = {'viewers': sorted(lines.values(), key=lambda m: m['t'])[-30:],
           'viewer_status': 'on' if states else 'waiting', 'viewer_delivery': receipts}
    if cursors:
        out['viewer_read'] = {'after': min(cursors)}
    return out


def operator_audience(op, teams, now):
    try:
        data=json.loads((Path(op)/'viewers.json').read_text())
        if not isinstance(data,dict) or not 0<=now-float(data.get('now',0))<=30:raise ValueError('stale')
    except (OSError,ValueError,TypeError):data=None
    return audience({'operator':data} if data else {},teams,now)


class PublicOverlay:
    def __init__(self, op, tree, run, port=8790, dwell=30, youtube=None, camera=True, audio=False):
        self.op = op
        self.feeds = feeds(op)
        self.race, self.director = Race(), Director(dwell)
        self.rosters = {t: roster(tree, run, t) for t, _ in self.feeds}
        self.harnesses = {t: Harness('imac2', t) for t, _ in self.feeds} if camera else {}
        self.stop = threading.Event()
        self.state = {'v': 2, 'teams': [], 'camera': None, 'viewers': [], 'viewer_status': 'off', 'now': 0, 'events': [],
                      'feed': [], 'ranking': 'Awaiting scores', 'layout': {'camera': list(CAMERA_RECT)}}
        self.lock = threading.Lock()
        self.audio = PublicAudio(self.snapshot, op)
        self.audio_enabled = audio
        self.dwell = dwell
        owner = self

        class Handler(AudioRoutes, http.server.BaseHTTPRequestHandler):
            audio = owner.audio

            def do_GET(self):
                if self.audio_get():
                    return
                if self.path.split('?')[0] == '/state.json':
                    with owner.lock:
                        body = json.dumps(owner.state).encode()
                    mime = 'application/json'
                elif self.path == '/health':
                    body, mime = b'ok', 'text/plain'
                else:
                    found = asset(self.path)
                    if not found:
                        self.send_error(404)
                        return
                    body, mime = found
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
        if self.audio_enabled:
            self.audio.start()

    def snapshot(self):
        with self.lock:
            return copy.deepcopy(self.state)

    def poll(self):
        previous = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(self.feeds)) as pool:
            while not self.stop.is_set():
                now, rows, fresh = time.time(), [], {}
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
                        previous[team] = row
                    except Exception as e:
                        print(f'feed {team}: {type(e).__name__}', flush=True)
                        row = dict(previous.get(team) or project(team, {}, self.rosters[team], now), stale=True)
                    rows.append(row)
                talks = diplomacy(views.get('diplomacy'), rows)
                # The operator's ordered feed, when this run's harness keeps one (views.json.feed): every team's
                # say, tell, board note, diplomacy and identity announcement on one sequence.
                lines = broadcast(project_feed(views['feed'], rows), rows, now) if isinstance(views.get('feed'), list) else None
                with self.lock:
                    self.state.update(self.race.update(rows, now, list_rows(views.get('contacts')), list_rows(views.get('pacts')), talks, lines),
                                      now=now, diplomacy=talks, market=project_market(views.get('market'), rows),
                                      **operator_audience(self.op, self.rosters, now))
                    if self.youtube:
                        self.state['stream'] = {'youtube_video_id': self.youtube}
                # Private to the director: where each roster agent is and how much it is doing.
                scout = {t: subjects(data, {a['name'] for a in self.rosters[t]}, now) for t, data in fresh.items()}
                choice = self.director.choose(rows, self.state['events'], now, scout) if self.harnesses else None
                if choice:
                    team, reason = choice
                    try:
                        camera = cut(self.harnesses[team], fresh[team], self.director.best(scout.get(team)),
                                     smooth=team == self.director.current)
                        since = time.time()
                        self.director.success(team, since, camera['agent'])
                        with self.lock:
                            surface = camera['surface'] if camera['surface'] in ('nauvis', 'vulcanus', 'gleba', 'fulgora', 'aquilo') else 'factory'
                            self.state['camera'] = {'team': team, 'surface': surface, 'since': since, 'reason': reason,
                                                    'agent': camera['agent'], 'kind': camera['kind']}
                        print(f'camera: {team} {camera}', flush=True)
                    except Exception as e:
                        print(f'camera {team}: {type(e).__name__}', flush=True)
                        self.director.failed(team, time.time())
                self.stop.wait(5)


    def close(self):
        self.stop.set()
        self.audio.close()
        self.http.shutdown()
        self.http.server_close()
