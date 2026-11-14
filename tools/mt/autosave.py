#!/usr/bin/env python3
"""Arm a server tick clock and copy completed rotating saves onto external storage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import time
import zipfile

from run_state import alert, command, lock, op_dir, pinned, read, rcon, write

ARCHIVE = Path('/Volumes/POG Media/pog-runs/team-runs')
REMOTE = '/Users/owner/pog-mt21/data/saves'

def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024*1024), b''): h.update(block)
    return h.hexdigest()

def arm(run, minutes=15, slots=12):
    op_dir(run); pinned()
    assert 1 <= minutes <= 60 and 2 <= slots <= 96
    # Re-arming the same world is idempotent. Another run cannot inherit its names.
    lua = (f'local a=storage.pog_autosave; if not a or a.prefix~={json.dumps(run)} then '
           f'a={{prefix={json.dumps(run)},enabled=true,interval_ticks={minutes*3600},slots={slots},'
           'sequence=0,records={},next_tick=game.tick+60}; storage.pog_autosave=a end; '
           'rcon.print(helpers.table_to_json(a))')
    return json.loads(rcon(lua))

def remote(code, *args):
    return command(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                    os.environ.get('IMAC_HOST', 'imac.local'),
                    shlex.join(['python3', '-c', code, *map(str,args)])], timeout=120)

def stat(path):
    return json.loads(remote('import os,json,sys; s=os.stat(sys.argv[1]); print(json.dumps([s.st_size,s.st_mtime_ns]))',path))

def retain(rows, keep):
    """Latest N copies plus the first verified copy in each game hour, across restores."""
    recent = sorted(rows, key=lambda r:r['copied_at'])[-keep:]
    hourly = {}
    for row in sorted(rows, key=lambda r:(r['tick'],r['copied_at'])):
        hourly.setdefault(row['tick']//216000, row)
    return {r['file'] for r in recent+list(hourly.values())}

def copy_new(run, keep=12):
    pinned(); op = op_dir(run)
    assert Path('/Volumes/POG Media').is_mount(), 'external archive volume is not mounted'
    dest = ARCHIVE/run/'saves'; dest.mkdir(parents=True,exist_ok=True)
    with lock(dest/'.copy.lock'):
        index = read(dest/'index.json', {'copies':[], 'seen':{}})
        clock = json.loads(rcon('rcon.print(helpers.table_to_json(storage.pog_autosave or {}))'))
        assert clock.get('prefix') == run and clock.get('enabled'), 'wrong/unarmed save clock'
        if clock.get('error'): raise RuntimeError(clock['error'])
        records=clock.get('records') or {}
        if not isinstance(records,dict): records={str(i):r for i,r in enumerate(records)}
        for row in records.values():
            name=row['name']; assert name.startswith(run+'-auto-') and '/' not in name
            path=REMOTE+'/'+name+'.zip'
            stamp=stat(path)
            key=json.dumps([row['sequence'],row['tick'],stamp])
            if index['seen'].get(name)==key: continue
            # server_save queues its write. A new tick record can briefly name the
            # previous contents of a reused slot; do not mislabel that old ZIP.
            previous=index['seen'].get(name)
            if previous and json.loads(previous)[2]==stamp: continue
            digest=remote('import hashlib,sys; h=hashlib.sha256(); f=open(sys.argv[1],"rb"); '
                          '[h.update(b) for b in iter(lambda:f.read(1048576),b"")]; print(h.hexdigest())',path).strip()
            partial=dest/(name+'.partial')
            command(['scp','-q',os.environ.get('IMAC_HOST','imac.local')+':'+path,partial],timeout=120)
            if stat(path)!=stamp or sha(partial)!=digest:
                partial.unlink(missing_ok=True)
                raise RuntimeError('save changed during copy; retry next poll')
            with zipfile.ZipFile(partial) as z:
                if z.testzip(): raise RuntimeError('save ZIP CRC failed')
            filename=f"{row['tick']:012d}-{digest[:16]}.zip"
            partial.replace(dest/filename)
            if not any(r['file']==filename for r in index['copies']):
                index['copies'].append(dict(row,file=filename,sha256=digest,bytes=stamp[0],copied_at=time.time()))
            index['seen'][name]=key
            # Commit proof before deleting any old archive. Remote rotating slots are never deleted here.
            write(dest/'index.json',index)
        survivors=retain(index['copies'],keep)
        for row in index['copies']:
            if row['file'] not in survivors: (dest/row['file']).unlink(missing_ok=True)
        index['copies']=[r for r in index['copies'] if r['file'] in survivors]
        write(dest/'index.json',index)
        write(op/'autosave-copy.json',dict(at=time.time(),clock=clock,copies=len(index['copies']),archive=str(dest)))
        return index

def verified(run, filename):
    dest=ARCHIVE/run/'saves'
    if Path(filename).name!=filename: raise ValueError('archive filename only')
    rows=read(dest/'index.json',{})['copies']
    row=next(r for r in rows if r['file']==filename)
    if sha(dest/filename)!=row['sha256']: raise RuntimeError('archive hash mismatch')
    return dest/filename,row

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['arm','once','watch','verify']);p.add_argument('run')
    p.add_argument('--minutes',type=int,default=15);p.add_argument('--slots',type=int,default=12)
    p.add_argument('--keep',type=int,default=12);p.add_argument('--file')
    a=p.parse_args();assert a.keep>=1;op=op_dir(a.run);op.mkdir(parents=True,exist_ok=True)
    if a.action=='arm': print(json.dumps(arm(a.run,a.minutes,a.slots)));return
    if a.action=='verify': print(verified(a.run,a.file)[0]);return
    if a.action=='once': print(json.dumps(copy_new(a.run,a.keep)));return
    import threading
    stop=threading.Event()
    for sig in (signal.SIGINT,signal.SIGTERM):signal.signal(sig,lambda *_:stop.set())
    with lock(op/'autosave-watch.lock'):
        last_alert=0
        while not stop.is_set():
            try: copy_new(a.run,a.keep)
            except Exception as e:
                print(str(e),flush=True)
                if time.time()-last_alert>=300:alert(op,'save-copy-failed',e);last_alert=time.time()
            stop.wait(30)

if __name__=='__main__':main()
