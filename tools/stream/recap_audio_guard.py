#!/usr/bin/env python3
"""Operator-run voice-only recap audio guard; dry run by default, durable undo.

No scene, source creation, stream or recording control. The overlay is the sole audible
program input during narration; track-2-only clean game audio keeps recording. Run at
normal deployment, never from a test. --apply watches the existing service state; Ctrl-C,
service loss, completed narration and --undo restore the saved input mute states.
"""
import argparse
import fcntl
import json
from pathlib import Path
import time
import urllib.request

from obsws import OBS, OBSError
from shift_recap import save_json, read_json


class Guard:
    def __init__(self, obs, receipt, overlay='stream overlay'):
        self.obs, self.receipt, self.overlay = obs, Path(receipt), overlay

    def plan(self):
        out = []
        for row in self.obs.call('GetInputList')['inputs']:
            name = row['inputName']
            if name == self.overlay:
                continue
            if not self.obs.call('GetSourceActive', {'sourceName': name}).get('videoActive'):
                continue
            try:
                tracks = self.obs.call('GetInputAudioTracks', {'inputName': name})['inputAudioTracks']
                if not tracks.get('1'):
                    continue
                muted = self.obs.call('GetInputMute', {'inputName': name})['inputMuted']
            except OBSError as exc:
                # Visual inputs have no audio. Unknown audio capabilities are not guessed.
                if '604' in str(exc) and 'does not support audio' in str(exc):
                    continue
                raise
            if not muted:
                out.append({'inputName': name, 'inputMuted': muted})
        return out

    def enter(self):
        if self.receipt.exists():
            raise ValueError('undo receipt already exists; run --undo before starting another guard')
        rows = self.plan()
        save_json(self.receipt, {'restore': rows})  # durable BEFORE any mutation, even partial failure
        for row in rows:
            self.obs.call('SetInputMute', dict(row, inputMuted=True), retry=False)
        return rows

    def restore(self):
        saved = read_json(self.receipt)
        if saved is None:
            return
        for row in saved['restore']:
            self.obs.call('SetInputMute', row, retry=False)
        self.receipt.unlink()  # failures retain the complete undo receipt


def active(state):
    recap = state.get('shift_recap') or {}
    return bool(recap.get('active') and not recap.get('holding'))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--state-url', default='http://127.0.0.1:8788/state.json')
    p.add_argument('--receipt', type=Path, required=True)
    p.add_argument('--obs', default='127.0.0.1:4455')
    p.add_argument('--overlay', default='stream overlay')
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true')
    mode.add_argument('--undo', action='store_true')
    a = p.parse_args()
    import os
    if os.environ.get('POG_TEST') == '1':
        raise SystemExit('POG_TEST=1: no live OBS connection')
    host, port = a.obs.rsplit(':', 1)
    obs = OBS(host, int(port))
    guard = Guard(obs, a.receipt, a.overlay)
    process_lock = None
    try:
        if a.apply or a.undo:
            a.receipt.parent.mkdir(parents=True, exist_ok=True)
            process_lock = a.receipt.with_suffix('.guard.lock').open('w')
            try:
                fcntl.flock(process_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SystemExit('audio guard is running; stop it before applying or undoing')
        if a.undo:
            guard.restore()
        elif not a.apply:
            print(json.dumps({'dry_run': True, 'mute_during_recap': guard.plan(),
                              'undo': str(a.receipt)}, indent=2))
        else:
            if a.receipt.exists():
                raise SystemExit('existing receipt: run --undo first')
            try:
                while True:
                    with urllib.request.urlopen(a.state_url, timeout=3) as f:
                        state = json.load(f)
                    state = state.get('state', state)
                    if not -1 <= time.time() - state.get('now', 0) <= 10:
                        raise ValueError('stale service state; restoring audio')
                    if active(state):
                        if not a.receipt.exists():
                            print(json.dumps({'muted': guard.enter()}), flush=True)
                    elif a.receipt.exists():
                        guard.restore()
                        print('recap ended: restored', flush=True)
                    time.sleep(.5)
            finally:
                guard.restore()
    finally:
        obs.close()
        if process_lock:
            process_lock.close()


if __name__ == '__main__':
    main()
