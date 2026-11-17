"""Private run ownership, atomic receipts and operator-only alerts."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
CLAIM = Path('/Users/owner/code/pog-operator/server-claim.txt')
DEFAULT_WAKE = Path('/Users/owner/code/pog-operator/mt300-wake.jsonl')
# (d46 Nov 16) Team-run archives (saves, metrics, recordings) live in an ordinary folder on the Mac's internal
# disk, ~/pog-media; until then they were on the external "POG Media" volume. POG_MEDIA names another folder.
# The tools write only when TEAM_RUNS exists and never create it: a missing one means the wrong machine or path.
MEDIA = Path(os.environ.get('POG_MEDIA') or Path.home()/'pog-media')
TEAM_RUNS = MEDIA/'pog-runs'/'team-runs'

def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default

def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f'.{os.getpid()}.tmp')
    with tmp.open('w') as out:
        json.dump(value, out, indent=2)
        out.write('\n'); out.flush(); os.fsync(out.fileno())
    tmp.replace(path)

def op_dir(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,16}', run):
        raise ValueError('plain run ID, 1..16 characters required')
    return ROOT/'runs'/run/'op'

def claim():
    owner = os.environ.get('POG_CLAIM_OWNER', 'eng-mt300')
    if not CLAIM.exists() or owner not in CLAIM.read_text().split():
        raise RuntimeError(f'{owner} must hold {CLAIM}')

def pinned():
    if os.environ.get('MT_DIR') != '/Users/owner/pog-mt21' or os.environ.get('MT_EXPECT_VERSION') != '2.1.24':
        raise RuntimeError('isolated 2.1.24 pins required')
    claim()

def command(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, text=True, capture_output=True,
                          timeout=kwargs.pop('timeout', 30), **kwargs).stdout

def rcon(lua):
    pinned()
    return command([sys.executable, ROOT/'tools/pog.py', '--world', 'imac2', 'rcon', '/silent-command '+lua])

def alert(op, event, detail):
    now=time.time()
    row = dict(at=now,t=now,run=op.parent.name,event=event,detail=str(detail),
               **{'from':'run-supervisor','text':f'{op.parent.name}: {event}: {detail}'})
    for path in (op/'alerts.jsonl', Path(os.environ.get('POG_OPERATOR_WAKE', DEFAULT_WAKE))):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('a') as out:
            fcntl.flock(out, fcntl.LOCK_EX)
            out.write(json.dumps(row)+'\n'); out.flush()

@contextlib.contextmanager
def lock(path, blocking=False):
    with Path(path).open('a+') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield
