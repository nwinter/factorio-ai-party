#!/usr/bin/env python3
"""(mt309) Back up the iMac mt server's prior state before a private run and restore it exactly afterwards.

  server_backup.py backup  [--execute]   the server must be stopped; copies saves/mt.zip, mods, config, the settings,
                                         whitelist and setup clients to MT_DIR-OWNER-backup with a SHA-256 manifest,
                                         and lists saves/ so files a run adds can be taken away again
  server_backup.py restore [--execute]   the server must be stopped; copies the run's new saves to TEAM_RUNS/OWNER-saves
                                         here, removes them there, restores the backup and verifies the manifest
  server_backup.py verify                compares the server folder with the backup's manifest (read only)

Only the claim's owner (POG_CLAIM_OWNER, run_state.CLAIM) may back up or restore. Modelled on mt307's
preserve-server.py, which must never be run against another owner's state.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_state import TEAM_RUNS, claim

HOST = os.environ.get('IMAC_HOST', 'imac.local')
MT_DIR = '/Users/owner/pog-mt21'

REMOTE = r'''
import hashlib, json, shutil, sys, time
from pathlib import Path
action, owner = sys.argv[1], sys.argv[2]
root = Path(%(root)r); backup = Path(str(root) + '-' + owner + '-backup')
paths = ['saves/mt.zip', 'mods', 'config', 'server-settings.json', 'server-whitelist.json', 'clients']
def manifest(base):
    out = {}
    for name in paths:
        p = base/name
        if not p.exists() and not p.is_symlink():
            out[name] = None; continue
        for q in ([p] + sorted(p.rglob('*')) if p.is_dir() else [p]):
            key = str(q.relative_to(base))
            if q.is_symlink(): out[key] = {'link': str(q.readlink())}
            elif q.is_dir(): out[key] = {'dir': True}
            else:
                h = hashlib.sha256()
                with q.open('rb') as f:
                    for b in iter(lambda: f.read(1 << 20), b''): h.update(b)
                out[key] = {'sha256': h.hexdigest(), 'bytes': q.stat().st_size, 'mode': q.stat().st_mode & 0o777}
    return out
def copy(src, dst):
    for name in paths:
        p, q = src/name, dst/name
        if q.is_symlink() or q.is_file(): q.unlink()
        elif q.is_dir(): shutil.rmtree(q)
        if not p.exists() and not p.is_symlink(): continue
        q.parent.mkdir(parents=True, exist_ok=True)
        if p.is_dir(): shutil.copytree(p, q, symlinks=True)
        else: shutil.copy2(p, q, follow_symlinks=False)
saves = lambda: sorted(x.name for x in (root/'saves').iterdir()) if (root/'saves').is_dir() else []
if action == 'backup':
    backup.mkdir(exist_ok=False)
    before = manifest(root)
    (backup/'manifest.json').write_text(json.dumps(before, indent=2) + '\n')
    (backup/'saves-before.json').write_text(json.dumps(saves()) + '\n')
    copy(root, backup)
    assert manifest(backup) == before == manifest(root), 'backup changed or incomplete'
    res = dict(action=action, entries=len(before), save=before['saves/mt.zip'])
elif action == 'new-saves':
    old = set(json.loads((backup/'saves-before.json').read_text()))
    res = dict(action=action, new=[s for s in saves() if s not in old and s != 'mt.zip'])
elif action == 'restore':
    before = json.loads((backup/'manifest.json').read_text())
    assert manifest(backup) == before, 'backup corrupt'
    old = set(json.loads((backup/'saves-before.json').read_text()))
    removed = [s for s in saves() if s not in old]
    for s in removed: (root/'saves'/s).unlink()
    copy(backup, root)
    assert manifest(root) == before and set(saves()) == old, 'restoration mismatch'
    res = dict(action=action, entries=len(before), removed_saves=removed, save=before['saves/mt.zip'])
else:
    before = json.loads((backup/'manifest.json').read_text())
    now = manifest(root)
    res = dict(action=action, same=now == before, differ=sorted(k for k in set(now) | set(before) if now.get(k) != before.get(k))[:20])
res.update(at=time.time(), backup=str(backup), verified=action != 'verify' or res['same'])
(backup/(action + '-proof.json')).write_text(json.dumps(res, indent=2) + '\n') if backup.exists() else None
print(json.dumps(res))
''' % {'root': MT_DIR}


def remote(*args, timeout=600):
    return json.loads(subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', HOST, 'python3', '-'] + list(args),
                                     input=REMOTE, capture_output=True, text=True, check=True, timeout=timeout).stdout.strip().splitlines()[-1])


def stopped():
    env = dict(os.environ, MT_DIR=MT_DIR, MT_EXPECT_VERSION='2.1.24', MT_RCON_PORT='27475', MT_GAME_PORT='34475',
               MT_FACTORIO_APP='/Users/owner/code/factorio-mac-2.1.24/factorio.app')
    out = subprocess.run(['bash', str(Path(__file__).with_name('imac_mt.sh')), 'status'], env=env, capture_output=True, text=True).stdout
    return out.startswith('not running'), out.strip()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('action', choices=['backup', 'restore', 'verify']); p.add_argument('--execute', action='store_true')
    a = p.parse_args(argv)
    owner = os.environ.get('POG_CLAIM_OWNER', 'eng-mt309')
    if a.action == 'verify':
        print(json.dumps(remote('verify', owner))); return
    claim()
    ok, status = stopped()
    assert ok, f'the server must be stopped first: {status}'
    if not a.execute:
        print(f'would {a.action} {MT_DIR} on {HOST} for {owner}'); return
    if a.action == 'restore':
        new = remote('new-saves', owner)['new']
        dest = TEAM_RUNS/f'{owner}-saves'
        assert TEAM_RUNS.is_dir(), f'{TEAM_RUNS} is missing'
        dest.mkdir(exist_ok=True)
        for s in new:
            subprocess.run(['scp', '-q', f'{HOST}:{MT_DIR}/saves/{s}', str(dest/s)], check=True, timeout=600)
        print('kept', new, 'in', dest)
    print(json.dumps(remote(a.action, owner)))


if __name__ == '__main__':
    main()
