#!/usr/bin/env python3
"""Offline pin, fresh-save and endpoint isolation regressions; no engine or network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import bench_mod

from test_imac_copy import stub
import testsafe

ROOT = Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory() as d:
        log = Path(d) / 'calls'
        stub(d, 'ssh', f'''echo "$*" >> '{log}'
case "$*" in
  *"cat > "*) cat >/dev/null ;;
  *"mkdir '"*launch.lock*) exit "${{LOCK_EXIT:-0}}" ;;
  *holder.json*) ;;
  *"for f in"*) echo /Users/owner/code/factorio-mac-2.1.24/factorio.app/Contents/MacOS/factorio ;;
  *codesign*) exit "${{SIGN_EXIT:-0}}" ;;
  *base/info.json*) echo '{{"version":"'"${{ENGINE_VERSION:-2.1.24}}"'"}}' ;;
  *nohup*) echo 5151 ;;
  *"kill -0"*) exit 1 ;;
esac''')
        stub(d, 'scp', f'echo "scp $*" >> "{log}"')
        stub(d, 'rsync', f'echo "rsync $*" >> "{log}"')
        stub(d, 'sleep', 'exit 0')
        stub(d, 'python3', f'''case "$*" in
*pog.py*) echo "rcon $POG_RCON_HOST $*" >> '{log}'
  case "$*" in *active_mods*) echo '{{"base":"2.1.24","harness":"0.1.0","recycler":"2.1.24","interface":true}}';; *) [ "${{EMPTY_TICK:-0}}" = 1 ] || echo 'tick 1';; esac; exit 0;;
esac
exec '{sys.executable}' "$@"''')
        run = lambda *args, **env: subprocess.run([str(ROOT / 'tools/port21-copy.sh'), *args],
            env=testsafe.env(PATH=d + os.pathsep + os.environ['PATH'], **env), capture_output=True, text=True)
        r = run('start', 'port21/test')
        assert r.returncode == 64 and not log.exists(), r
        for env in ({'ENGINE_VERSION':'2.0.77'}, {'SIGN_EXIT':'1'}, {'LOCK_EXIT':'1'}):
            log.write_text('')
            r = run('start', 'port21/test', '--fresh', **env)
            assert r.returncode and 'nohup' not in log.read_text(), (env, r)
        log.write_text('')
        r = run('start', 'port21/test', '--fresh', IMAC_DIR='/shared', IMAC_RCON_PORT='27400')
        assert r.returncode == 0, r
        calls = log.read_text()
        assert '--create' in calls and '--mod-directory' in calls and 'fresh-' in calls
        assert '/shared' not in calls and '--port 27400' not in calls
        assert '--port 27478' in calls and '--port 34478' in calls
        assert 'codesign --verify --deep --strict' in calls
        assert calls.index('codesign') < calls.index('nohup')
        assert 'active_mods' in calls and 'rmdir' in calls
        r = run('start', 'port21/test', 'imac:/private/reference.zip', EMPTY_TICK='1')
        assert r.returncode == 1 and 'up:' not in r.stdout, r
        stub(d, 'node', 'echo "$FACTORIO_RCON_HOST $FACTORIO_RCON_PORT ${FH_SOCKET:-none}"')
        r = run('fh', 'status', POG_FH_SOCKET='/shared/socket', FH_SOCKET='/other', POG_WORLD='n')
        assert r.stdout.strip() == 'imac.local 27478 none', r
    print('port21: exact pin, signature, start lock, fresh-save, private endpoint and broker isolation: ok')
    with tempfile.TemporaryDirectory() as d:
        mod = Path(d) / 'source'
        mod.mkdir()
        (mod / 'control.lua').write_text((ROOT / 'vendor/factorio-harness/mod/agent-harness_0.1.0/control.lua').read_text())
        for version in ['2.0', '2.1']:
            (mod / 'info.json').write_text(json.dumps({'factorio_version': version}))
            target = Path(d) / version
            bench_mod.main([str(target), '--mod', str(mod)])
            names = {m['name'] for m in json.loads((target / 'mod-list.json').read_text())['mods'] if m['enabled']}
            assert ('recycler' in names) == (version == '2.1')
    print('benchmark packaging: recycler follows the supplied mod engine version')


if __name__ == '__main__':
    main()
