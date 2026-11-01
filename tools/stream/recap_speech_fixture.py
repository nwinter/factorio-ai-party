#!/usr/bin/env python3
"""Isolated real-overlay audio fixture for recap_speech_browser.mjs; never starts stream workers.

Reads prepared speech from --source; writes only --out. No OBS, game, TTS or live-service calls.
"""
import argparse
import io
import json
import math
import socket
from pathlib import Path
import threading
import time
import struct
import wave
from http.server import ThreadingHTTPServer

from serve import AudioHub, Hub, Model, make_handler
from shift_recap_air import Player
from shift_recap_camera import cue
from test_onecam import world, agent, snap as director_snapshot


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--delay-first', type=float, default=0)
    ap.add_argument('--backdrop', type=Path)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    source = a.out / a.source.name
    root = source / 'shift-recap'
    root.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((a.source / 'shift-recap/manifest.json').read_text())
    manifest['lines'] = manifest['lines'][:2]  # two whole real lines, unchanged audio and validation
    (root / 'manifest.json').write_text(json.dumps(manifest))
    (root / 'assets').symlink_to((a.source / 'shift-recap/assets').resolve(), target_is_directory=True)
    run = a.out / 'fixture-run'
    run.mkdir()
    audio = AudioHub(str(a.out / 'audio-played.jsonl'))  # browser preview receipts allowed ONLY here
    hub = Hub()
    model = Model({'agents': {}})
    player = None
    lock = threading.RLock()
    commands = []
    connections = set()
    first = manifest['lines'][0]
    director, sent = world()
    scene_key = None
    dstate = director_snapshot([dict(agent('luna', 0, 0, 5), surface='nauvis')])
    dstate['space'] = {'platforms': [{'name': 'Asterion', 'view': {
        'surface': 'platform-16', 'hub': {'x': 10, 'y': 20}}}]}
    delayed = False

    base = make_handler(hub, lambda: [], audio=audio)

    class Handler(base):
        def do_GET(self):
            nonlocal delayed
            if self.path == '/__backdrop' and a.backdrop:
                return self.send(200, a.backdrop.read_bytes(), 'video/mp4')
            if self.path.startswith('/audio/clip/') and a.delay_first and not delayed:
                delayed = True
                time.sleep(a.delay_first)
            return super().do_GET()

        def events(self):
            with lock:
                connections.add(self.connection)
            try:
                return super().events()
            finally:
                with lock:
                    connections.discard(self.connection)

        def do_POST(self):
            nonlocal player
            if self.path != '/__fixture':
                return super().do_POST()
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            with lock:
                commands.append(dict(body, t=time.time()))
                action = body['action']
                if action == 'start':
                    player = Player(run, source, audio)
                    result = {'owner': player.segment}
                elif action == 'interrupt':
                    player.finish('fixture interruption')
                    result = {'interrupted': True}
                elif action == 'agents-started':
                    (run / 'start.log').write_text('started: 9/9 agents\n')
                    result = {'started': True}
                elif action == 'disconnect':
                    for connection in list(connections):
                        connection.shutdown(socket.SHUT_RDWR)
                    result = {'disconnected': len(connections)}
                elif action == 'push':
                    seconds = body.get('seconds', 0.6)
                    buf = io.BytesIO()
                    with wave.open(buf, 'wb') as wav:
                        wav.setparams((1, 2, 24000, 0, 'NONE', 'not compressed'))
                        wav.writeframes(b''.join(struct.pack('<h', int(4000 * math.sin(i * 2 * math.pi * 440 / 24000)))
                                                for i in range(int(seconds * 24000))))
                    meta = {'channel': body.get('channel', 'operator'), 'speaker': body.get('speaker', 'Operator'),
                            'text': 'Audio arbitration probe.', 'duration': seconds, 'expires_in': body.get('ttl', 120),
                            'rank': body.get('rank', 'agent')}
                    if body.get('timed'):
                        meta.update(at=time.time() + 0.3, segment={'id': 'fixture-tour', 'part': 1, 'parts': 1})
                    result = audio.push(meta, buf.getvalue(), 'audio/wav')
                else:
                    return self.send(400, b'unknown fixture command', 'text/plain')
                (a.out / 'commands.json').write_text(json.dumps(commands, indent=2))
            self.send(200, json.dumps(result).encode(), 'application/json')

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)

    def tick():
        nonlocal scene_key
        while True:
            with lock:
                now = time.time()
                public = player.step(now) if player else None
                cameras = director.step(dstate, now, cue(public, dstate, now))
                snap = model.snapshot(now)
                shot = director.state.get(director.onair) or {}
                snap.update(now=now, shift_recap=public, speech_owner=audio.speech_owner,
                            cameras=cameras, fixture_camera=dict(slot=director.onair, subject=shot.get('subject'),
                                                                segment=shot.get('seg')))
                key = (json.dumps(public and {k:public.get(k) for k in ('id','clip','holding')}),
                       json.dumps(snap['fixture_camera']))
                if key != scene_key:
                    scene_key = key
                    with (a.out / 'scenes.jsonl').open('a') as f:
                        f.write(json.dumps(dict(t=now, recap=public, camera=snap['fixture_camera']))+'\n')
                hub.publish(snap)
            time.sleep(0.1)

    threading.Thread(target=tick, daemon=True).start()
    print(json.dumps({'url': f'http://127.0.0.1:{server.server_port}'}), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
