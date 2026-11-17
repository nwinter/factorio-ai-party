#!/usr/bin/env python3
"""Move closed, dedicated OBS segments to the media folder (run_state.TEAM_RUNS) after SHA-256 verification.

Only this run's spool is inspected. Open files are skipped, never copied/deleted.
The media folder must exist before any write (nothing here creates it).
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import threading
import time

from public_stream import checked, powershell
from run_state import TEAM_RUNS, alert, write


def archive(op, run):
    if not TEAM_RUNS.is_dir():
        raise RuntimeError(f'{TEAM_RUNS} is missing; recordings retained on pogwin')
    dest=TEAM_RUNS/run/'recordings'
    dest.mkdir(parents=True,exist_ok=True)
    spool=f'D:/pog/mt-stream21/recordings/{run}'
    script=r"""
    $rows=@(); Get-ChildItem -LiteralPath '__SPOOL__' -File -ErrorAction SilentlyContinue | ForEach-Object {
      $f=$null
      try {
        $f=[IO.File]::Open($_.FullName,'Open','Read','None')
        $sha=[Security.Cryptography.SHA256]::Create()
        $hash=([BitConverter]::ToString($sha.ComputeHash($f))).Replace('-','').ToLower()
        $rows+=@{name=$_.Name;size=$f.Length;sha256=$hash}
      } catch {} finally { if ($f) {$f.Dispose()} }
    }; ConvertTo-Json -InputObject @($rows) -Compress
    """.replace('__SPOOL__',spool)
    rows=json.loads(checked(powershell(script),capture_output=True,text=True).stdout or '[]')
    for row in rows:
        name=row['name']
        if not re.fullmatch(r'[A-Za-z0-9_. -]+\.(mkv|mp4|mov)',name):
            raise RuntimeError('unexpected filename in dedicated recording spool')
        target=dest/name
        part=target.with_suffix(target.suffix+'.part')
        if not target.exists():
            checked(['scp','-q',f'pogwin:{spool}/{name}',str(part)],timeout=600)
            with part.open('rb') as stream:
                digest=hashlib.file_digest(stream,'sha256').hexdigest()
            if digest!=row['sha256'] or part.stat().st_size!=row['size']:
                raise RuntimeError('recording transfer checksum mismatch')
            part.replace(target)
        else:
            with target.open('rb') as stream:
                if hashlib.file_digest(stream,'sha256').hexdigest()!=row['sha256']:
                    raise RuntimeError('recording destination collision')
        # Reopen exclusively and hash immediately before deleting exactly this file.
        checked(powershell(r"""
        $p='__FILE__'; $f=[IO.File]::Open($p,'Open','ReadWrite','None')
        try {
          $sha=[Security.Cryptography.SHA256]::Create()
          $hash=([BitConverter]::ToString($sha.ComputeHash($f))).Replace('-','').ToLower()
          if ($hash -ne '__HASH__') {throw 'recording changed after copy'}
        } finally {$f.Dispose()}
        Remove-Item -LiteralPath $p -ErrorAction Stop
        """.replace('__FILE__',spool+'/'+name).replace('__HASH__',row['sha256'])),capture_output=True,text=True)
        with (op/'recordings.jsonl').open('a') as out:
            out.write(json.dumps(dict(row,path=str(target),at=time.time()))+'\n')
    write(op/'recordings.json',dict(heartbeat=time.time(),destination=str(dest),copied=len(rows)))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('op',type=Path);p.add_argument('--once',action='store_true')
    a=p.parse_args();run=a.op.parent.name
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,20}',run):
        raise ValueError('plain run name required')
    handle=(a.op/'recordings.lock').open('a+')
    fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
    stop=threading.Event()
    for sig in (signal.SIGTERM,signal.SIGINT):
        signal.signal(sig,lambda *_:stop.set())
    last_alert=0
    while True:
        try:
            archive(a.op,run)
        except Exception as e:
            if time.time()-last_alert>900:
                alert(a.op,'recording-archive',str(e));last_alert=time.time()
            if a.once:
                raise
        if a.once or stop.is_set():
            return
        if stop.wait(60):
            return


if __name__=='__main__':
    main()
