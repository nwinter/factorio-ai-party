#!/usr/bin/env python3
"""(mt309, note-mt309-g) Before a run: does every harness in its roster start under the current player scope?

  harness_smoke.py ROSTER [--tree DIR]

For each roster row, a throwaway folder in a scratch launch tree (tools/mt/launch-tree.sh from HEAD, default
worktrees/pog-smoke) and one short headless start of the real CLI as the launcher starts it:
  grok, agy, muse   under tools/agent-scope.py (the exact process scope a player gets: POG_ISOLATED runs) with the
                    provider traffic through a netgate.py port holding that CLI's allowlist (full_tools.NETGATE_ALLOW);
                    Grok with its run-local home (tools/grok-home.py) and $grok_env, agy through tools/agy-local.py,
                    Muse with the scope's native config and home (and `muse skills list --source user` must be empty)
  claude            the launcher's own claude_settings (sandbox and Read rules, run with the run env's POG_ISOLATED and
                    POG_READ_SCOPE) and $claude_unset $claude_vars $claude_flags (tools/profile-flags.sh)
Each is asked for the single word OK. A row passes when the CLI exits 0, prints OK, and no "Operation not permitted"
or "failed to start" shows. Prints one JSON line per row and exits 1 if any failed. One small model call per row.
The throwaway folders are removed; the scratch tree stays for the next check.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
WORKTREES = Path.home()/'code/personal/player-of-games/worktrees'
sys.path.insert(0, str(ROOT/'tools'))
from full_tools import NETGATE_ALLOW
PROMPT = 'Reply with the single word OK.'
# The run environment the launcher sees (tools/mt/launch.py's isolated sprints, as in runs/*/op/full-env.json)
RUN_ENV = dict(POG_ISOLATED='1', POG_READ_SCOPE='1', POG_BROKER='1', POG_CONTINUOUS='1')


def roster(path):
    rows = []
    for line in Path(path).read_text().splitlines():
        if line.startswith('#') or not line.strip():
            continue
        team, name, kind, route, model, effort = line.split('\t')[:6]
        rows.append(dict(team=team, name=name, kind=kind, route=route, model=model, effort=effort))
    return rows


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]


def gate(kind, folder):
    port = free_port()
    cfg = folder/'netgate.json'
    cfg.write_text(json.dumps({'agents': {'smoke': {'port': port, 'allow': NETGATE_ALLOW[kind], 'kind': kind}}}))
    p = subprocess.Popen([sys.executable, str(ROOT/'tools/mt/netgate.py'), str(cfg), str(folder/'netgate.jsonl')],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            socket.create_connection(('127.0.0.1', port), 0.2).close(); return p, f'http://127.0.0.1:{port}'
        except OSError:
            time.sleep(0.1)
    p.kill(); raise RuntimeError('netgate did not listen')


def proxy_lines(proxy):
    return (f'export HTTPS_PROXY={proxy} HTTP_PROXY={proxy} ALL_PROXY={proxy} https_proxy={proxy} http_proxy={proxy} '
            f'all_proxy={proxy} NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1')


def scoped(tree, row, folder):
    kind, m, e = row['kind'], row['model'], row['effort']
    gp, proxy = gate(kind, folder)
    try:
        lines = ['#!/usr/bin/env bash', f"cd '{folder}'", proxy_lines(proxy), f"source '{tree}/tools/profile-flags.sh'"]
        if kind == 'grok':
            home_env = subprocess.run([sys.executable, str(tree/'tools/grok-home.py'), 'setup', str(folder), '900'],
                                      capture_output=True, text=True, check=True).stdout.strip()
            lines.append(f"exec env $grok_env {home_env} \"$grok_bin\" -m {m} --effort {e} -p '{PROMPT}'")
        elif kind == 'agy':
            lines.append(f"exec python3 '{tree}/tools/agy-local.py' -p '{PROMPT}' --model {m} "
                         "--dangerously-skip-permissions --print-timeout 120s")
        elif kind == 'muse':
            lines += ['echo "== user skills"; muse skills list --source user --json',
                      f"echo '== reply'; exec env $muse_env muse exec -c 'hooks={{}}' -c context.foreign_personal_rules=false "
                      f"-c context.foreign_personal_skills=false --model {m} --effort {e} --approval-mode never '{PROMPT}'"]
        script = folder/f'.{kind}-smoke.sh'          # agent-scope keys Muse's native setup on ".muse" in the name
        script.write_text('\n'.join(lines)+'\n'); script.chmod(0o755)
        r = subprocess.run([sys.executable, str(tree/'tools/agent-scope.py'), str(tree), proxy, str(script)], cwd=folder,
                           capture_output=True, text=True, timeout=300)
        out = r.stdout + r.stderr
        extra = {}
        if kind == 'muse':
            skills = out.split('== user skills', 1)[-1].split('== reply', 1)[0]
            try:
                extra['user_skills'] = len(json.loads(skills)['skills'])
            except (ValueError, KeyError):
                extra['user_skills'] = 'unreadable'
        return r.returncode, out, extra
    finally:
        gp.terminate()


def claude(tree, row, folder):
    route = row['route'] if row['route'] != '-' else 'claude'
    croot = subprocess.run(['/Users/owner/.local/bin/ai-session', 'routes'], capture_output=True, text=True).stdout
    croot = next((l.split()[-1] for l in croot.splitlines() if l.split()[:2] == [route, 'claude']), None)
    if not croot:
        return 1, f'unknown Claude route {route}', {}
    cenv = '-u CLAUDE_CONFIG_DIR' if route == 'claude' else f"CLAUDE_CONFIG_DIR='{croot}'"
    launcher = tree/'tools/launch-agent.sh'
    lines = ['#!/usr/bin/env bash', 'set -u', f"root='{tree}'; dir='{folder}'; run=smoke",
             *(f'export {k}={v}' for k, v in RUN_ENV.items()),
             'source "$root/tools/profile-flags.sh"',
             # the launcher's own Read allowlist and settings writer, taken from the file the run uses
             "eval \"$(sed -n '/^allow=/,/^# Compaction/p' \"$root/tools/launch-agent.sh\" | sed '$d')\"",
             "eval \"$(sed -n '/^claude_settings() {/,/^}/p' \"$root/tools/launch-agent.sh\")\"",
             'claude_settings', 'cd "$dir"',
             f"eval \"exec env $claude_unset {cenv} $claude_vars /Users/owner/.local/bin/claude --model {row['model']} "
             f"--effort {row['effort']} $claude_flags -p '{PROMPT}'\""]
    assert launcher.exists()
    script = folder/'.claude-smoke.sh'
    script.write_text('\n'.join(lines)+'\n'); script.chmod(0o755)
    r = subprocess.run(['/bin/bash', str(script)], cwd=folder, capture_output=True, text=True, timeout=300,
                       env={k: v for k, v in os.environ.items() if not k.startswith('CLAUDE_CODE') and k != 'CLAUDECODE'})
    settings = json.loads((folder/'.claude/settings.json').read_text())
    return r.returncode, r.stdout + r.stderr, dict(sandbox=bool(settings.get('sandbox', {}).get('enabled')))


def verdict(rc, out, extra):
    replied = any(l.strip().strip('.').upper() == 'OK' for l in out.splitlines())
    blocked = [l.strip()[:200] for l in out.splitlines() if 'Operation not permitted' in l or 'failed to start' in l]
    ok = rc == 0 and replied and not blocked and extra.get('user_skills', 0) == 0 and extra.get('sandbox', True)
    return ok, replied, blocked


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('roster'); ap.add_argument('--tree', default=str(WORKTREES/'pog-smoke'))
    a = ap.parse_args()
    tree = Path(subprocess.run([str(ROOT/'tools/mt/launch-tree.sh'), a.tree], capture_output=True, text=True,
                               check=True).stdout.strip().splitlines()[-1])
    head = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True).stdout.strip()
    failed = 0
    for row in roster(a.roster):
        folder = tree/'runs/smoke'/f"{row['name']}-{int(time.time())}"
        folder.mkdir(parents=True)
        t0 = time.time()
        try:
            if row['kind'] in ('grok', 'agy', 'muse'):
                rc, out, extra = scoped(tree, row, folder)
            elif row['kind'] == 'claude':
                rc, out, extra = claude(tree, row, folder)
            else:
                rc, out, extra = 1, f"no smoke for kind {row['kind']} yet", {}
        except Exception as e:  # a smoke that cannot run is a failed check
            rc, out, extra = 1, repr(e), {}
        ok, replied, blocked = verdict(rc, out, extra)
        failed += not ok
        print(json.dumps(dict(name=row['name'], kind=row['kind'], model=row['model'], ok=ok, exit=rc, replied=replied,
                              blocked=blocked, took_s=round(time.time()-t0, 1), head=head, **extra,
                              tail=None if ok else out[-600:])), flush=True)
        native = folder/'.native-root'
        if native.exists():
            shutil.rmtree(native.read_text().strip(), ignore_errors=True)
        shutil.rmtree(folder, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
