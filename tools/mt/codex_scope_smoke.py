#!/usr/bin/env python3
"""(mt309) Smoke test of the scoped Codex player (tools/agent-scope.py with the POG Codex home).

  codex_scope_smoke.py            offline: a throwaway team tree and a throwaway rival tree; under the exact scope
                                  profile a Codex player gets, plain shell commands check that ~/.codex, the rival
                                  tree, ~/.config/pog and outside hosts are refused and that the tree, its broker
                                  socket and the POG Codex home work. ~/.codex/auth.json is hashed before and after.
                                  No model call, no login needed (the POG home is created empty if missing).
  codex_scope_smoke.py --live     also one scoped `codex exec` reply through netgate.py --learn (the hosts Codex
                                  uses go in the result, for NETGATE_ALLOW). Needs the POG home's login and refuses
                                  while personal Codex reads 100% of its week (credits are never spent).

Prints one JSON result; exit 1 on any failed check. Removes both throwaway trees.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('agent_scope', ROOT/'tools/agent-scope.py')
scope = importlib.util.module_from_spec(spec); spec.loader.exec_module(scope)
sys.path.insert(0, str(ROOT/'tools'))
import codex_pog_home

HOME = Path.home()
WORKTREES = HOME/'code/personal/player-of-games/worktrees'


def fingerprint(p):
    if not p.exists():
        return None
    st = p.stat()
    return dict(sha256=hashlib.sha256(p.read_bytes()).hexdigest(), size=st.st_size, mtime=st.st_mtime, ino=st.st_ino)


def run_scoped(profile_path, env, cmd, timeout=20, cwd=None):
    # stdin closed: `codex exec` appends a piped stdin to its prompt and waits for it to end (a smoke run from a tool
    # whose stdin is an open pipe hung for the whole timeout)
    r = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile_path), '/bin/sh', '-c', cmd], env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()[:200]


def live_ok():
    b = json.loads((HOME/'.cache/ai-usage/agent-brief.json').read_text())
    p = next((p for p in b.get('profiles', []) if p.get('id') == 'codex_account_a'), {})
    pct = max((w.get('percent') or 0) for w in p.get('windows') or [{}])
    return p.get('available') and not p.get('stale') and pct < 99, pct


def main(argv=None):
    live = '--live' in (sys.argv[1:] if argv is None else argv)
    auth = HOME/'.codex/auth.json'
    before = fingerprint(auth)
    home = codex_pog_home.DEFAULT
    codex_pog_home.init(home)
    checks = {}
    tree = Path(tempfile.mkdtemp(prefix='play-smoke-', dir=WORKTREES)); rival = Path(tempfile.mkdtemp(prefix='play-smoke-', dir=WORKTREES))
    try:
        (tree/'.launch-tree').write_text('smoke\n')
        ws = tree/'runs'/'sm'/'arm'; ws.mkdir(parents=True); (ws/'notes.md').write_text('own notes\n')
        (rival/'runs').mkdir(); (rival/'runs'/'secret.md').write_text('rival notes\n')
        sockdir = tree/'runs'/'sm'/'.sock'; sockdir.mkdir()
        sock_path = sockdir/'arm.sock'
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); srv.bind(str(sock_path)); srv.listen(1)
        threading.Thread(target=lambda: (lambda c: (c[0].sendall(b'pong'), c[0].close()))(srv.accept()), daemon=True).start()
        prepared = ws/'.codex-run.sh'; prepared.write_text('#!/usr/bin/env bash\n'); prepared.chmod(0o755)
        native = Path(tempfile.mkdtemp(prefix='pg-', dir='/private/tmp'))
        env = scope.environment(os.environ)
        env.update(TMPDIR=str(native) + '/', CODEX_HOME=str(home), POG_SCOPE_ACTIVE='1')
        policy = ws/'.scope.sb'
        policy.write_text(scope.profile(tree.resolve(), HOME, None, native.resolve(), home))
        q = lambda p: "'" + str(p).replace("'", "'\\''") + "'"
        tests = {
            'own tree readable': (f'cat {q(ws/"notes.md")}', True),
            'own tree writable': (f'echo x > {q(ws/"scratch.txt")}', True),
            'POG Codex home readable': (f'cat {q(home/"config.toml")}', True),
            'broker socket in the tree': (f"python3 -c 'import socket;s=socket.socket(socket.AF_UNIX);s.connect({json.dumps(str(sock_path))});print(s.recv(4))'", True),
            '~/.codex/auth.json refused': (f'cat {q(auth)}', False),
            '~/.codex sessions refused': (f'ls {q(HOME/".codex/sessions")}', False),
            'rival tree refused': (f'cat {q(rival/"runs"/"secret.md")}', False),
            'operator folder refused': (f'ls {q(HOME/"code/pog-operator")}', False),
            '~/.config/pog refused': (f'ls {q(HOME/".config/pog")}', False),
            'media folder refused': (f'ls {q(HOME/"pog-media/pog-runs")}', False),
            'outside host refused': ("python3 -c 'import socket;socket.create_connection((\"1.1.1.1\",443),5)'", False),
        }
        for name, (cmd, want_ok) in tests.items():
            rc, out = run_scoped(policy, env, cmd, cwd=ws)
            checks[name] = dict(ok=(rc == 0) == want_ok, rc=rc, out=out[-120:])
        if live:
            ok, pct = live_ok()
            st = codex_pog_home.status(home)
            if not st['logged_in']:
                checks['live'] = dict(ok=False, out='the POG Codex home has no login yet')
            elif not ok:
                checks['live'] = dict(ok=False, out=f'personal Codex at {pct}% of its week: no live call (never on credits)')
            else:
                log = native/'learn.jsonl'
                gate = subprocess.Popen([sys.executable, str(ROOT/'tools/mt/netgate.py'), '--learn', '18199', str(log)])
                time.sleep(1)
                penv = dict(env, HTTPS_PROXY='http://127.0.0.1:18199', HTTP_PROXY='http://127.0.0.1:18199', ALL_PROXY='http://127.0.0.1:18199')
                live_policy = ws/'.scope-live.sb'
                live_policy.write_text(scope.profile(tree.resolve(), HOME, 'http://127.0.0.1:18199', native.resolve(), home))
                try:     # a hung call (timeout) must not leave the learn gate running
                    rc, out = run_scoped(live_policy, penv, f"/opt/homebrew/bin/codex exec -C {q(ws)} -s danger-full-access --skip-git-repo-check 'Reply with the single word OK.'", timeout=300, cwd=ws)
                except subprocess.TimeoutExpired as e:
                    rc, out = 124, f'timed out after 300 s: {(e.stdout or b"")[-200:]!r}'
                finally:
                    gate.terminate()
                # the learn log's first line is the gate's own start event (no host)
                hosts = sorted({json.loads(l).get('host') for l in log.read_text().splitlines()} - {None} if log.exists() else set())
                checks['live'] = dict(ok=rc == 0 and 'OK' in out, rc=rc, out=out[-200:], hosts=hosts)
    finally:
        try:
            srv.close()
        except Exception:
            pass
        shutil.rmtree(tree, ignore_errors=True); shutil.rmtree(rival, ignore_errors=True)
    after = fingerprint(auth)
    checks['~/.codex/auth.json unchanged'] = dict(ok=before == after, out='' if before == after else 'CHANGED')
    result = dict(at=time.time(), live=live, pog_home=codex_pog_home.status(home), passed=all(c['ok'] for c in checks.values()), checks=checks)
    print(json.dumps(result, indent=1))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
