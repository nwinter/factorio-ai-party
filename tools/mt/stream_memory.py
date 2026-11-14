#!/usr/bin/env python3
"""Read-only pogwin memory telemetry. Never reboots or changes logon settings.

agent-python tools/mt/stream_memory.py /ABS/OP [--every 300] [--once]
Keep this on the Mac so failures on the Windows desktop can still wake the operator.
"""
import argparse
import json
from pathlib import Path
import time
import fcntl

from run_state import alert, read, write
from public_stream import checked, powershell

GIB = 1024 ** 3
SAMPLE = r"""
$m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
$o=Get-CimInstance Win32_OperatingSystem
[ordered]@{
  at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  boot=$o.LastBootUpTime.ToUniversalTime().ToString('o')
  total_bytes=[long]$o.TotalVisibleMemorySize*1024
  available_bytes=[long]$m.AvailableBytes
  nonpaged_bytes=[long]$m.PoolNonpagedBytes
  paged_bytes=[long]$m.PoolPagedBytes
  commit_bytes=[long]$m.CommittedBytes
  commit_limit=[long]$m.CommitLimit
  pages_per_sec=[long]$m.PagesPersec
  processes=@(Get-CimInstance Win32_Process |
    Where-Object {$_.Name -match '^(obs64|factorio.*)\.exe$'} |
    Select-Object Name,ProcessId,ExecutablePath,WorkingSetSize,PrivatePageCount)
} | ConvertTo-Json -Depth 4 -Compress
"""


def sample():
    return json.loads(checked(powershell(SAMPLE), capture_output=True, text=True).stdout)


def assess(samples):
    """A trend is evidence, not a driver diagnosis. Never extrapolate across boots."""
    s = samples[-1]
    same = [p for p in samples if p['boot'] == s['boot'] and 0 <= s['at'] - p['at'] <= 86400]
    out = {'available_gib': s['available_bytes']/GIB, 'nonpaged_gib': s['nonpaged_bytes']/GIB,
           'hours': (s['at']-same[0]['at'])/3600, 'warnings': []}
    if s['available_bytes'] < 4*GIB:
        out['warnings'].append('less than 4 GiB available; arrange a staffed reboot/sign-in window')
    if s['nonpaged_bytes'] > 2*GIB:
        out['warnings'].append('nonpaged pool above 2 GiB; inspect growth and arrange a staffed window')
    if s['commit_limit'] and s['commit_bytes']/s['commit_limit'] > .85:
        out['warnings'].append('commit exceeds 85% of its limit')
    if out['hours'] >= 2:
        first = same[0]
        pool = (s['nonpaged_bytes']-first['nonpaged_bytes'])/GIB/out['hours']
        loss = (first['available_bytes']-s['available_bytes'])/GIB/out['hours']
        out.update(nonpaged_gib_per_hour=pool, available_loss_gib_per_hour=loss,
                   hours_to_4gib=(out['available_gib']-4)/loss if loss > .05 else None)
        if loss > .05 and out['hours_to_4gib'] < 12:
            out['warnings'].append('available-memory trend reaches 4 GiB within 12 hours; arrange staffed reboot')
        if pool > .02:
            out['warnings'].append('nonpaged pool growing more than 20 MiB/hour over at least two hours')
    return out


def observe(op):
    previous = read(op/'memory.json', {})
    s = sample()
    history = [p for p in previous.get('samples', []) if s['at']-p['at'] <= 86400][-287:]+[s]
    result = assess(history)
    row = dict(s, assessment=result)
    with (op/'memory.jsonl').open('a') as out:
        out.write(json.dumps(row)+'\n')
    last_alert = previous.get('last_alert', 0)
    if result['warnings'] and s['at']-last_alert >= 1800:
        alert(op, 'pogwin-memory', '; '.join(result['warnings']) + '. No automatic reboot. Game stays on imac2.')
        last_alert = s['at']
    write(op/'memory.json', dict(samples=history, latest=row, last_alert=last_alert, heartbeat=time.time()))
    return row


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('op', type=Path)
    p.add_argument('--every', type=int, default=300)
    p.add_argument('--once', action='store_true')
    a = p.parse_args()
    a.op.mkdir(parents=True, exist_ok=True)
    handle=(a.op/'memory.lock').open('a+')
    fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
    last_error = 0
    while True:
        try:
            print(json.dumps(observe(a.op)), flush=True)
        except Exception as e:
            if time.time()-last_error > 1800:
                alert(a.op, 'pogwin-memory-unavailable', type(e).__name__)
                last_error = time.time()
            if a.once:
                raise
        if a.once:
            return
        time.sleep(max(30, a.every))


if __name__ == '__main__':
    main()
