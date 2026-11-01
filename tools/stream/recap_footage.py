#!/usr/bin/env python3
"""Prepare bounded, silent gameplay cuts from reviewed program/replay intervals.

Default is a dry run. --apply writes only under RUN/recap-clips and atomically updates
RUN/recap-media.json. No OBS, game, remote execution or service restart. Recipes must
supply capture epoch and a subject-coverage receipt; filenames are never time evidence.
"""
import argparse
import fcntl
import hashlib
import json
import math
from pathlib import Path
import subprocess
import time

from shift_recap import read_json, save_json

MAX_CLIPS = 16
MAX_SECONDS = 20
MAX_BYTES = 16 * 1024 * 1024
BUDGET = 256 * 1024 * 1024


def plan(recipe, run):
    start = ((read_json(Path(run) / 'stream.json', {}) or {}).get('shift') or {}).get('start')
    end = ((read_json(Path(run) / 'stream.json', {}) or {}).get('shift') or {}).get('end')
    rows = recipe.get('clips')
    if not isinstance(rows, list) or not 0 < len(rows) <= MAX_CLIPS:
        raise ValueError('recipe needs 1..16 reviewed clips')
    jobs = []
    for row in rows:
        row = dict(row)
        source = Path(row['source']).expanduser().resolve()
        stat = source.stat()
        row.update(source_bytes=stat.st_size, source_mtime_ns=stat.st_mtime_ns)
        values = [row.get(k) for k in ('offset', 'duration', 't')]
        if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in values):
            raise ValueError('finite offset, duration and capture epoch required')
        offset, duration, stamp = values
        if offset < 0 or not 1 <= duration <= MAX_SECONDS:
            raise ValueError('clip length must be 1..20 seconds')
        if start is None or end is None or not start <= stamp < stamp + duration <= end:
            raise ValueError('clip interval must be inside the recorded shift')
        if row.get('subject_type') not in ('surface', 'platform') or not row.get('subject'):
            raise ValueError('explicit subject and subject_type required')
        # Require reviewed coverage of the WHOLE cut, not a camera request or replay label.
        coverage = row.get('coverage') or {}
        if not coverage.get('evidence') or not coverage.get('clock_anchor') or coverage.get('reviewed') is not True:
            raise ValueError('reviewed subject coverage and explicit clock anchor required')
        if coverage.get('start', math.inf) > stamp or coverage.get('end', -math.inf) < stamp + duration:
            raise ValueError('subject coverage does not span the whole cut')
        crop = row.get('crop')
        if not isinstance(crop, list) or len(crop) != 4 or any(type(v) is not int or v < 0 for v in crop) or min(crop[2:]) < 2:
            raise ValueError('explicit crop [x,y,width,height] required; review burnt-in overlays')
        key = hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest()[:24]
        out = Path(run) / 'recap-clips' / (key + '.webm')
        x, y, w, h = crop
        command = ['ffmpeg', '-v', 'error', '-nostdin', '-n', '-threads', '2', '-ss', str(offset), '-i', str(source),
                   '-t', str(duration), '-map', '0:v:0', '-an', '-sn', '-dn',
                   '-vf', f'crop={w}:{h}:{x}:{y},scale=1024:-2,fps=24', '-c:v', 'libvpx-vp9',
                   '-threads', '2', '-row-mt', '1', '-deadline', 'realtime', '-cpu-used', '8',
                   '-crf', '34', '-b:v', '0', '-pix_fmt', 'yuv420p', '-fs', str(MAX_BYTES),
                   '-f', 'webm', str(out.with_suffix('.tmp'))]
        jobs.append({'path': str(out.relative_to(run)), 'output': str(out), 'command': command,
                     'source': str(source), 't': stamp, 'duration': duration, 'subject': row['subject'],
                     'subject_type': row['subject_type'], 'coverage': coverage, 'crop': crop,
                     'source_bytes': stat.st_size, 'source_mtime_ns': stat.st_mtime_ns,
                     'offset': 0, 'recipe_key': key})
    return jobs


def probe(path, execute=subprocess.run):
    r = execute(['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=codec_type,width,height',
                 '-of', 'json', str(path)], capture_output=True, check=True, timeout=15)
    return json.loads(r.stdout)


def apply(jobs, run, execute=subprocess.run):
    """Publish only decoded, complete clips. Existing files/index survive any failed job."""
    run = Path(run)
    folder = run / 'recap-clips'
    folder.mkdir(parents=True, exist_ok=True)
    receipts = []
    with (folder / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for job in jobs:
            out = Path(job['output']); tmp = out.with_suffix('.tmp')
            if not Path(job['source']).is_file():
                raise ValueError('source missing: ' + job['source'])
            used = sum(p.stat().st_size for p in folder.iterdir() if p.is_file() and p.name != '.lock')
            if used > BUDGET or (not out.exists() and used + MAX_BYTES > BUDGET):
                raise ValueError('256 MiB clip budget exhausted')
            before = time.monotonic()
            try:
                if not out.exists():
                    tmp.unlink(missing_ok=True)
                    execute(job['command'], check=True, capture_output=True, timeout=120)
                candidate = out if out.exists() else tmp
                info = probe(candidate, execute)
                duration = float(info['format']['duration'])
                if (any(s['codec_type'] == 'audio' for s in info['streams']) or
                        not any(s['codec_type'] == 'video' for s in info['streams']) or
                        not math.isfinite(duration) or abs(duration - job['duration']) > .15 or
                        candidate.stat().st_size > MAX_BYTES):
                    raise ValueError('incomplete, oversized or non-silent clip')
                execute(['ffmpeg', '-v', 'error', '-nostdin', '-i', str(candidate), '-an', '-f', 'null', '-'],
                        check=True, capture_output=True, timeout=60)
                current = Path(job['source']).stat()
                if (current.st_size, current.st_mtime_ns) != (job['source_bytes'], job['source_mtime_ns']):
                    raise ValueError('source changed during preparation; use a finished recording')
                if candidate == tmp:
                    tmp.replace(out)
                receipts.append({k: v for k, v in job.items() if k not in ('command', 'output')})
                receipts[-1].update(bytes=out.stat().st_size, prep_seconds=round(time.monotonic() - before, 3))
            finally:
                tmp.unlink(missing_ok=True)
        # Share the capture helper's index lock so a still arriving during prep is preserved.
        (run / 'recap-frames').mkdir(exist_ok=True)
        with (run / 'recap-frames' / '.lock').open('w') as index_lock:
            fcntl.flock(index_lock, fcntl.LOCK_EX)
            old = read_json(run / 'recap-media.json', [])
            if not isinstance(old, list):
                raise ValueError('invalid existing media index')
            paths = {r['path'] for r in receipts}
            save_json(run / 'recap-media.json', [r for r in old if r.get('path') not in paths] + receipts)
    return receipts


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--recipe', type=Path, required=True)
    p.add_argument('--run-dir', type=Path, required=True)
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    jobs = plan(json.loads(a.recipe.read_text()), a.run_dir.resolve())
    print(json.dumps(apply(jobs, a.run_dir.resolve()) if a.apply else jobs, indent=2))


if __name__ == '__main__':
    main()
