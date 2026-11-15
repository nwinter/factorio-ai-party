"""Claim, preserve and restore the private imac2 slot. Never starts a game.

Use claim only after the operator's release. Each step leaves a durable receipt;
restore verifies the captured PID before asking the existing launcher to stop.
"""
import argparse
import datetime
import json
import os
import shlex
import subprocess
import tempfile
import time
from config import CLAIM, HERE, TREE, PASSWORD_FILE

REMOTE = '/Users/owner/pog-mt21'
RECEIPT = HERE / 'server-lease.json'


def write(row):
    tmp = RECEIPT.with_suffix('.tmp')
    tmp.write_text(json.dumps(row, indent=2) + '\n')
    tmp.replace(RECEIPT)


def owned():
    row = json.loads(RECEIPT.read_text())
    assert CLAIM.read_text() == row['claim'], 'claim changed; refusing server access'
    return row


def remote(script):
    owned()
    return subprocess.check_output(['ssh', '-o', 'BatchMode=yes', 'imac.local',
                                    'bash', '-s'], input='set -euo pipefail\n' + script,
                                   text=True)


def free_ports():
    return ('if lsof -nP -iTCP:27475 -sTCP:LISTEN -t; then exit 1; fi\n'
            'if lsof -nP -iUDP:34475 -t; then exit 1; fi\n')


def claim(note):
    HERE.mkdir(parents=True, exist_ok=True)
    assert not RECEIPT.exists(), 'choose a fresh MT306_ART; existing lease receipt'
    stamp = datetime.datetime.now().astimezone().isoformat()
    contents = f'eng-mt306 owns imac2; {note}; claimed {stamp}\n'
    fd, path = tempfile.mkstemp(prefix='.mt306-claim-', dir=CLAIM.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(contents); f.flush(); os.fsync(f.fileno())
        os.link(path, CLAIM)  # Fails atomically if another engineer holds it.
    finally:
        os.unlink(path)
    write({'claim': contents, 'claimed_at': stamp})


def backup():
    row = owned()
    assert 'backup' not in row, 'backup already recorded'
    name = REMOTE + '/mt306-before-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    script = f'd={shlex.quote(REMOTE)}\nb={shlex.quote(name)}\n' + free_ports() + '''
if [ -s "$d/server.pid" ] && kill -0 "$(cat "$d/server.pid")" 2>/dev/null; then exit 1; fi
test -s "$d/saves/mt.zip"
mkdir "$b"
cp -cp "$d/saves/mt.zip" "$b/mt.zip"
cp -cRp "$d/mods" "$b/mods"
cp -cRp "$d/config" "$b/config"
for f in server-settings.json server-whitelist.json; do
  if [ -e "$d/$f" ]; then cp -cp "$d/$f" "$b/$f"; fi
done
cmp -s "$d/saves/mt.zip" "$b/mt.zip"
diff -qr "$d/mods" "$b/mods"
diff -qr "$d/config" "$b/config"
shasum -a 256 "$b/mt.zip"
'''
    row['backup'] = name
    # Record the destination before mutation so an interrupted copy is inspectable.
    write(row)
    row['backup_result'] = remote(script)
    row['backup_complete'] = True
    write(row)


def capture_pid():
    row = owned()
    assert row.get('backup_complete'), 'backup must complete before startup'
    assert 'pid' not in row, 'PID already captured'
    pid = remote(f'cat {REMOTE}/server.pid\n').strip()
    assert pid.isdecimal() and int(pid) > 1
    row['pid'] = int(pid)
    row['process_start'] = remote(f'ps -p {pid} -o lstart=\n').strip()
    assert row['process_start']
    write(row)


def restore():
    row = owned()
    assert row.get('backup_complete') and row.get('pid'), 'missing backup or owned PID'
    pid = row['pid']
    if not row.get('stopped_at'):
        assert remote(f'cat {REMOTE}/server.pid\n').strip() == str(pid), 'different server PID'
        assert remote(f'ps -p {pid} -o lstart=\n').strip() == row['process_start'], 'PID reused'
        subprocess.run([str(TREE / 'tools/mt/port21.sh'), 'server', 'stop'], check=True,
                       env={**os.environ, 'MT_PASSWORD_FILE': str(PASSWORD_FILE)})
        row['stopped_at'] = datetime.datetime.now().astimezone().isoformat()
        write(row)
    script = f'd={shlex.quote(REMOTE)}\nb={shlex.quote(row["backup"])}\n' + free_ports() + '''
cp -cp "$b/mt.zip" "$d/saves/mt.zip"
rsync -a --delete "$b/mods/" "$d/mods/"
rsync -a --delete "$b/config/" "$d/config/"
for f in server-settings.json server-whitelist.json; do
  if [ -e "$b/$f" ]; then
    cp -cp "$b/$f" "$d/$f"; cmp -s "$b/$f" "$d/$f"
  else rm -f "$d/$f"; fi
done
cmp -s "$b/mt.zip" "$d/saves/mt.zip"
diff -qr "$b/mods" "$d/mods"
diff -qr "$b/config" "$d/config"
shasum -a 256 "$b/mt.zip" "$d/saves/mt.zip"
'''
    row['restore_result'] = remote(script)
    row['restored_at'] = datetime.datetime.now().astimezone().isoformat()
    write(row)


def release():
    row = owned()
    assert row.get('restored_at'), 'restore and verify before release'
    remote(free_ports())
    with CLAIM.open() as f:
        stat = os.fstat(f.fileno())
        assert f.read() == row['claim'], 'claim changed'
    assert CLAIM.stat().st_ino == stat.st_ino, 'claim replaced'
    CLAIM.unlink()
    row['released_at'] = datetime.datetime.now().astimezone().isoformat()
    write(row)
    message = ('ENGWAKE eng-mt306 released imac2 at ' + row['released_at'] +
               '; server stopped; prior save/mods/config/settings restored and compared; ports free.')
    fd = os.open(CLAIM.parent / 'mt306-wake.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, (json.dumps({'t': time.time(), 'from': 'eng-mt306', 'text': message}) + '\n').encode())
    finally:
        os.close(fd)
    print(message)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['claim', 'backup', 'capture-pid', 'restore', 'release'])
    p.add_argument('--note', default='matched after-bench after operator release')
    a = p.parse_args()
    if a.action == 'claim': claim(a.note)
    else: {'backup': backup, 'capture-pid': capture_pid, 'restore': restore, 'release': release}[a.action]()
