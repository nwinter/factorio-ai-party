"""A restrained caster over the public projection; no game or viewer input.

Reuses the main stream's spoken-text picker, TTS, AudioHub and audio.js. Only
overlay events and roster-authenticated radio rows are candidates. Synthesis is
off the polling thread; no arbitrary speech submission endpoint is exposed.
"""
import collections
import json
import math
import os
from pathlib import Path
import re
import sys
import threading
import time
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'stream'))
from caster import spoken, talk_pick, near_same
from serve import AudioHub
import voices
from public_race import speech, label, rows, obj, agent_label

PRIORITY = {'death': 9, 'platform_lost': 9, 'fight': 9, 'rocket': 8,
            'contact': 7, 'pact': 7, 'market': 6, 'research': 5, 'tour': 4, 'build': 3, 'radio': 1}


def fresh(stamp, now, seconds):
    return type(stamp) in (int, float) and math.isfinite(stamp) and 0 <= now - stamp <= seconds


def candidates(state, now):
    """Read just the same public facts the canvas renders. Viewer data is never traversed."""
    if not fresh(state.get('now'), now, 20):
        return []
    teams = {t['team']: t for t in map(obj, rows(state.get('teams')))
             if t.get('team') in ('green', 'yellow', 'blue', 'red') and not t.get('stale')}
    out, contact_pairs = [], set()
    tour=obj(state.get('tour'))
    if (tour.get('team') in teams and tour.get('team') == obj(state.get('camera')).get('team')
            and fresh(tour.get('at'), now, 40) and isinstance(tour.get('id'),str)):
        text=speech(tour.get('text'),('Nick','Winter'),500)
        if text:
            out.append(dict(id=tour['id'],kind='tour',team=tour['team'],text=text,at=tour['at']))
    for e in map(obj, rows(state.get('events'))):
        team, kind = e.get('team'), e.get('kind')
        text = speech(e.get('text'), ('Nick', 'Winter'), 220)
        if (team not in teams or kind not in PRIORITY or kind in ('radio', 'market', 'fight')
                or not text or not fresh(e.get('at'), now, 45) or not isinstance(e.get('id'), str)):
            continue
        if kind == 'build' and not text.startswith('First '):
            continue
        if kind == 'contact':
            key = (tuple(sorted((team, str(e.get('other'))))), e.get('tick'))
            if key in contact_pairs:
                continue
            contact_pairs.add(key)
        out.append(dict(id='event:' + e['id'], kind=kind, team=team,
                        text=f'{team.capitalize()}. {spoken(text)}.', at=e['at']))
    for m in map(obj, rows(state.get('feed'))):
        team, kind = m.get('team'), m.get('kind')
        if (team not in teams or kind not in ('talk', 'tell', 'board', 'diplomacy', 'market')
                or m.get('viewer') or m.get('source') in ('site', 'youtube') or m.get('reply')
                or not isinstance(m.get('id'), str) or not fresh(m.get('at'), now, 35)):
            continue
        text = speech(m.get('text'), ('Nick', 'Winter'), 220)
        if not text:
            continue
        if kind == 'market':
            event = m.get('event', 'fill')
            if (m.get('system') is not True or m.get('name') != 'Trading Post'
                    or event not in ('fill', 'coinage', 'raid', 'embargo', 'shipment_loss')
                    or type(m.get('source_seq')) is not int or m['source_seq'] <= 0):
                continue
            other = m.get('to_team')
            if (event in ('fill', 'embargo', 'shipment_loss') and (other not in teams or other == team)
                    or event in ('coinage', 'raid') and other):
                continue
            text = 'Trading Post. ' + spoken(text)
        else:
            agent = next((a for a in map(obj, rows(teams[team].get('agents'))) if a.get('name') == m.get('name')), None)
            if not agent:
                continue
            ok, _, picked = talk_pick({'text': text, 'agent': m['name']}, limit=200)
            if not ok:
                continue
            who = agent_label(agent)
            if not who:
                continue
            text = f'{team.capitalize()} radio. {who} says, {spoken(picked)}'
            kind = 'radio'
        out.append(dict(id='feed:' + m['id'], kind=kind, team=team, text=text, at=m['at']))
    for team, t in teams.items():
        for a in map(obj, rows(t.get('agents'))):
            if a.get('verb') == 'fight' and a.get('activity') == 'acting':
                who = agent_label(a)
                if who:
                    out.append(dict(id=f'fight:{team}:{a.get("name")}', kind='fight', team=team,
                                    text=f'{team.capitalize()}. {who} is fighting.', at=now))
    return out


class Picker:
    """No startup recap; bounded pending queue, one line at a time and sparse radio."""
    def __init__(self):
        self.seen = collections.deque(maxlen=2000)
        self.pending = {}
        self.initial = True
        self.next_at = 0
        self.radio_at = 0
        self.aired = collections.deque(maxlen=30)

    def observe(self, state, now):
        available = {c['id']: c for c in candidates(state, now)}
        for ident, c in available.items():
            if ident not in self.seen:
                self.seen.append(ident)
                if not self.initial:
                    self.pending[ident] = c
        if fresh(state.get('now'), now, 20) and state.get('teams'):
            self.initial = False
        self.pending = {k: v for k, v in self.pending.items() if k in available}
        self.pending = dict(sorted(self.pending.items(), key=lambda kv: kv[1]['at'])[-20:])

    def choose(self, now):
        eligible = [c for c in self.pending.values() if now >= self.next_at
                    and (c['kind'] != 'radio' or now >= self.radio_at)
                    and not any(now - at < 180 and (c['kind'] != 'tour' or c.get('team') == team)
                                and near_same(c['text'], text, .8) for at, text, team in self.aired)]
        return max(eligible, key=lambda c: (PRIORITY[c['kind']], c['at']), default=None)

    def sent(self, c, now, duration):
        self.pending.pop(c['id'], None)
        self.aired.append((now, c['text'], c.get('team')))
        self.next_at = now + duration + (5 if PRIORITY[c['kind']] >= 7 else 15)
        if c['kind'] == 'radio':
            self.radio_at = now + duration + 40


class PublicAudio:
    def __init__(self, snapshot, op, backend=None):
        self.snapshot, self.op = snapshot, Path(op)
        self.hub = AudioHub(log_path=str(self.op / 'audio-played.jsonl'), require_capture=True)
        self.picker = Picker()
        self.stop = threading.Event()
        self.backend = backend or os.environ.get('POG_MT_TTS', 'eleven-fast')
        self.thread = None

    def start(self):
        self.thread = threading.Thread(target=self.run, daemon=True, name='public-caster')
        self.thread.start()

    def record(self, **data):
        with (self.op / 'caster.jsonl').open('a') as f:
            f.write(json.dumps(dict(t=time.time(), **data), ensure_ascii=False) + '\n')

    def run(self):
        tts, retry_at = None, 0
        while not self.stop.wait(1):
            state = self.snapshot()
            now = time.time()
            self.picker.observe(state, now)
            status = self.hub.status()
            if now < retry_at or not status['listeners'] or status['playing'] or status['queued']:
                continue
            c = self.picker.choose(now)
            if not c:
                continue
            try:
                tts = tts or voices.TTS(self.backend, target=-18.0)
                audio, ctype, duration, latency = tts.speak(c['text'], tts.caster_voice('pbp'), caster='pbp', plain=True)
                if tts.backend == 'say':
                    audio, ctype = voices.normalize(audio, ctype, -18.0)
                # Provider latency must not turn an old or removed fact into a fresh announcement.
                valid = {v['id'] for v in candidates(self.snapshot(), time.time())}
                if self.stop.is_set() or c['id'] not in valid or not self.hub.status()['listeners']:
                    self.picker.pending.pop(c['id'], None)
                    self.record(event=c['id'], text=c['text'], pushed=False, reason='no longer current')
                    continue
                clip = self.hub.push(dict(channel='caster', speaker='Caster', text=c['text'], duration=duration,
                                         rank='urgent' if PRIORITY[c['kind']] >= 7 else 'banter',
                                         expires_in=15, event=c['kind']), audio, ctype)
                self.picker.sent(c, time.time(), duration)
                self.record(event=c['id'], text=c['text'], pushed=True, clip=clip['id'],
                            duration=duration, latency=latency, voice=tts.last_here())
            except Exception as e:
                # A failed cloud voice does not silently remove commentary for the run.
                # Main's local voice is the bounded, same-machine fallback, logged explicitly.
                fallback = self.backend != 'say'
                retry_at = time.time() + (1 if fallback else 60)
                self.record(event=c['id'], pushed=False, error=type(e).__name__,
                            fallback='say' if fallback else None, retry_after=1 if fallback else 60)
                if fallback:
                    self.backend, tts = 'say', None

    def close(self):
        self.stop.set()
        for cid in list(self.hub.order):
            self.hub.cancel(cid)
        if self.thread:
            self.thread.join(timeout=2)


class AudioRoutes:
    """HTTP mixin for the main AudioHub/player protocol; playback receipts are the only writes."""
    def audio_send(self, code, body, mime='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', mime)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def audio_get(self):
        path = urllib.parse.urlsplit(self.path).path
        hub = self.audio.hub
        if path == '/audio/status':
            self.audio_send(200, json.dumps(hub.status()).encode())
        elif path.startswith('/audio/clip/'):
            with hub.cond:
                clip = hub.clips.get(path.rsplit('/', 1)[-1])
            self.audio_send(200, clip[0], clip[1]) if clip else self.send_error(404)
        elif path == '/events':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            seq, initial = hub.subscription()
            with hub.cond:
                hub.listeners += 1
            try:
                while not self.audio.stop.is_set():
                    for c in initial:
                        self.wfile.write(b'event: audio\ndata: ' + json.dumps(c).encode() + b'\n\n')
                    self.wfile.write(b': heartbeat\n\n')
                    self.wfile.flush()
                    seq, initial = hub.wait(seq, 2)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                with hub.cond:
                    hub.listeners -= 1
        else:
            return False
        return True

    def do_POST(self):
        if self.path != '/audio/played':
            self.send_error(404)
            return
        try:
            n = int(self.headers.get('Content-Length', '0'))
            if not 0 < n <= 4096:
                raise ValueError()
            report = json.loads(self.rfile.read(n))
            if not isinstance(report, dict):
                raise ValueError()
            self.audio.hub.played(report)
        except (ValueError, TypeError):
            self.close_connection = True
            self.send_error(400)
            return
        self.audio_send(200, b'{}')
