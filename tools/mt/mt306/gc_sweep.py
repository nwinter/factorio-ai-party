"""Private mt306 GC measurement; requires the current imac2 claim on every call.

Run during a claimed bench, beside stand-ins. Settings restore in finally.
No runtime defaults change. Results are native timings, not a proposed preset.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

from config import TREE, HERE, CODE, PYTHON, CLAIM, PASSWORD_FILE, LABEL
sys.path.insert(0, str(TREE / 'tools'))
sys.path.insert(0, str(TREE / 'tools/mt'))
import pog
from load_bench import window_stats, profile_completion


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', required=True)
    ap.add_argument('--seconds', type=int, default=120)
    ap.add_argument('--allocation-seconds', type=int, default=5)
    a = ap.parse_args()
    assert 30 <= a.seconds <= 180
    assert 1 <= a.allocation_seconds <= 10
    assert 'eng-mt306 owns imac2' in CLAIM.read_text(), 'no claim'
    password = PASSWORD_FILE.read_text().strip()
    rc = pog.Rcon('imac.local', 27475, password, timeout=120)
    def raw(cmd):
        assert 'eng-mt306 owns imac2' in CLAIM.read_text(), 'lost claim'
        return rc.command(cmd)
    def lua(code):
        return json.loads(raw('/silent-command __agent-harness__ ' + code))
    def profile(args):
        return json.loads(raw("/silent-command rcon.print(remote.call('agent_harness','profile_ticks'," + args + '))'))
    def sample():
        return lua("rcon.print(helpers.table_to_json{tick=game.tick,kb=collectgarbage('count')})")
    def log_text():
        assert 'eng-mt306 owns imac2' in CLAIM.read_text(), 'lost claim'
        return subprocess.run(['ssh', 'imac.local', 'cat', '/Users/owner/pog-mt21/data/factorio-current.log'],
                              capture_output=True, text=True, check=True).stdout
    rows = []
    out = Path(a.out)
    def save():
        tmp = out.with_suffix(out.suffix + '.tmp')
        tmp.write_text(json.dumps(rows, indent=1) + '\n')
        tmp.replace(out)
    # Lua 5.2 returns the previous settings; restore immediately after reading.
    old = lua("local p=collectgarbage('setpause',200); local s=collectgarbage('setstepmul',200); "
              "collectgarbage('setpause',p); collectgarbage('setstepmul',s); "
              "rcon.print(helpers.table_to_json{pause=p,stepmul=s,tick=game.tick})")
    rows.append({'original': old})
    save()
    try:
        settings = [(old['pause'], old['stepmul']), (150, 200), (150, 400), (120, 400)]
        for pause, step in settings:
            changed = lua(f"local p=collectgarbage('setpause',{pause}); local s=collectgarbage('setstepmul',{step}); "
                          "rcon.print(helpers.table_to_json{tick=game.tick,previous_pause=p,previous_stepmul=s})")
            start = profile('{seconds=' + str(a.seconds) + '}')
            points = []
            deadline = time.monotonic() + a.seconds * 3 + 30
            while time.monotonic() < deadline:
                time.sleep(5)
                point = sample()
                point['wall'] = time.time()
                points.append(point)
                assert point['kb'] < 1500 * 1024, 'heap above 1500 MB; ending sweep'
                if point['tick'] >= start['until_tick'] + 120:
                    break
            else:
                raise TimeoutError('GC profile exceeded its time budget')
            log = log_text()
            coverage = profile_completion(log, start['tick'], start['until_tick'])
            assert coverage['complete'], coverage
            stats = window_stats(log, start['tick'], start['until_tick'])
            stats.update(coverage)
            ups = [(b['tick']-a['tick'])/(b['wall']-a['wall']) for a,b in zip(points,points[1:])]
            rows.append({'pause': pause, 'stepmul': step, 'changed': changed, 'profile': start,
                         'stats': stats, 'samples': points, 'ups': ups})
            save()
            print(json.dumps(rows[-1]), flush=True)
        # Allocation-only microprofile: do not mix its GC-stopped timing into the sweep.
        start = profile('{seconds=' + str(a.allocation_seconds) + ',alloc=true,gc="stop"}')
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            time.sleep(1)
            point = sample()
            assert point['kb'] < 1500 * 1024, 'allocation probe heap above 1500 MB'
            if point['tick'] >= start['until_tick'] + 120:
                break
        else:
            raise TimeoutError('allocation profile exceeded its time budget')
        rows.append({'allocation_profile': start})
        save()
        out.with_suffix('.profile.log').write_text(log_text())
    finally:
        # Stop restores GC if the bounded allocation run was still active.
        try:
            profile('{stop=true}')
        finally:
            restored = lua(f"collectgarbage('restart'); collectgarbage('setpause',{old['pause']}); "
                           f"collectgarbage('setstepmul',{old['stepmul']}); "
                           "rcon.print(helpers.table_to_json{tick=game.tick,restored=true})")
            rows.append({'restore': restored, 'pause': old['pause'], 'stepmul': old['stepmul']})
            save()


if __name__ == '__main__':
    main()
