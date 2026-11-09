#!/usr/bin/env python3
"""Offline real service fixture: no workers, OBS, game, live run, or external services."""
import argparse
import io
import json
import math
from pathlib import Path
import struct
import threading
import time
import wave
from http.server import ThreadingHTTPServer
from serve import AudioHub, Hub, Model, make_handler
from target_countdown import facts as target_facts


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--target-run', type=Path, help='optional offline target.json directory')
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    hub, model = Hub(), Model({'agents': {}})
    audio = AudioHub(str(a.out / 'audio-played.jsonl'))
    changes = {}
    lock = threading.Lock()
    base = make_handler(hub, lambda: [], audio=audio)

    class Handler(base):
        def do_POST(self):
            if self.path != '/__fixture':
                return super().do_POST()
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if body['action'] == 'state':
                with lock:
                    changes.clear()
                    changes.update(body['value'])
                result = {}
            elif body['action'] == 'speech':
                seconds = body.get('seconds', 6)
                b = io.BytesIO()
                with wave.open(b, 'wb') as w:
                    w.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                    w.writeframes(b''.join(struct.pack('<h', int(1000 * math.sin(i * 2 * math.pi * 440 / 16000)))
                                          for i in range(int(16000 * seconds))))
                result = audio.push(dict(channel='caster', speaker='Rook', text=body.get('text', 'Recovery speech caption'),
                    duration=seconds, expires_in=120, **body.get('meta', {})), b.getvalue(), 'audio/wav')
            else:
                return self.send(400, b'unknown action', 'text/plain')
            self.send(200, json.dumps(result).encode(), 'application/json')

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    def tick():
        while True:
            s = model.snapshot(time.time())
            s.update(program={'layout': 'onecam'}, cameras={'main': {'agents': [], 'map': 'Nauvis recovery camera'}},
                     shift_recap=None, tour=[])
            s['run_target'] = target_facts(a.target_run)
            with lock:
                s.update(changes)
            hub.publish(s)
            time.sleep(.25)
    threading.Thread(target=tick, daemon=True).start()
    print(json.dumps({'port': server.server_port}), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
