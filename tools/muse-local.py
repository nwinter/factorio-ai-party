#!/usr/bin/env python3
"""Scoped headless Muse turns; keep playing until the workspace deadline.

The native headless client supports excluding personal context. Its TUI does
not. Normal turns retain native context/compaction; if the model finishes early,
a fresh turn recovers from this workspace's notes rather than a shared index.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def deadline(path):
    value = path.read_text().strip()
    return time.mktime(time.strptime(value, '%Y-%m-%d %H:%M %Z'))


def command(prompt, options):
    return [str(Path.home()/'.local/bin/muse'), 'exec', '--json',
            '--no-foreign-personal-context', '--disable-reminders',
            '--disable-request-user-input', *options, prompt]


def main():
    if os.environ.get('POG_SCOPE_ACTIVE') != '1':
        raise SystemExit('launch through the prepared process scope')
    prompt = Path(sys.argv[1]).read_text()
    options = sys.argv[2:]
    first = True
    while time.time() < deadline(Path('deadline.txt')) - 20:
        left = deadline(Path('deadline.txt')) - time.time()
        message = prompt if first else (
            'Continue playing until deadline.txt. This is a fresh conversation; '
            'recover from AGENTS.md and your own notes.md. Keep your current '
            'identity. Read status, chat, tells and board, then continue your '
            'current work and keep notes.md current.')
        started = time.time()
        child = subprocess.Popen(command(message, options), start_new_session=True)
        def stop(*_):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda signum, frame: (stop(), sys.exit(128+signum)))
        try:
            result = child.wait(timeout=max(1, left))
        except subprocess.TimeoutExpired:
            stop()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            return 0
        with Path('context.log').open('a') as log:
            log.write(json.dumps({'time': time.time(), 'event': 'muse-headless-turn',
                                  'exit': result, 'seconds': time.time()-started})+'\n')
        if result:
            return result  # fail visibly; no provider-limit retry storm
        first = False
        time.sleep(min(10, max(0, deadline(Path('deadline.txt'))-time.time())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
