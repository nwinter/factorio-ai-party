#!/usr/bin/env python3
"""(note-mt309-y) agy for one team from a team home of its own: the sign-in kept in a file there, under the player
scope with no keychain (tools/agent-scope.py with POG_AGY_HOME), its traffic through a netgate port holding agy's
allow list (full_tools.NETGATE_ALLOW['agy']).

  agy_team_login.py start TEAM_HOME                   agy, interactive, in TEAM_HOME (made new: refused when it
                                                      exists with files in it). Sign in there once; its link is
                                                      printed and no browser is opened.
  agy_team_login.py start TEAM_HOME --until-prompt S  the same, stopped when the sign-in screen shows or after S
                                                      seconds; the screen goes to TEAM_HOME/work/until-prompt.txt
  agy_team_login.py check TEAM_HOME                   after the sign-in: secrets.json under TEAM_HOME (path, size and
                                                      mode only), the keychain probe under the same scope (exits 44: no item found),
                                                      and one agy -p reply through the gate

TEAM_HOME holds home/ (agy's HOME; ANTIGRAVITY_GEMINI_DIR is home/.gemini), app/ (ANTIGRAVITY_APP_DATA_DIR) and
work/ (the scope's tree and the agent's folder). Prints one JSON result; exit 1 when a check fails. ~/.gemini and ~/.cache/antigravity are
closed to the scope, and their file names, sizes and times are compared before and after (contents are not read).
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from full_tools import NETGATE_ALLOW
HOME = Path.home()
PROMPT = 'Reply with the single word OK.'
SIGN_IN = re.compile(r'open this link|sign in|log in|login', re.I)
ANSI = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\r')


def owner_folders():
    """Name, size and time of every file under the owner's agy folders (never their contents)."""
    out = {}
    for base in (HOME/'.gemini', HOME/'.cache/antigravity'):
        for dirpath, dirs, files in os.walk(base):
            for f in files:
                p = Path(dirpath)/f
                try:
                    st = p.lstat()
                except OSError:
                    continue
                out[str(p)] = (st.st_size, int(st.st_mtime))
    return out


def tree(home, new):
    home = home.resolve()
    if new:
        assert not home.exists() or not any(home.iterdir()), f'{home} exists with files in it: a team home starts empty'
    work = home/'work'
    for d in (home, home/'app', home/'home', work):
        d.mkdir(parents=True, exist_ok=True, mode=0o700)
    (work/'.launch-tree').write_text('agy team home\n')
    return home, work


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close(); return port


def gate(work):
    port = free_port(); cfg = work/'netgate.json'
    cfg.write_text(json.dumps({'agents': {'agy': {'port': port, 'allow': NETGATE_ALLOW['agy'], 'kind': 'agy'}}}))
    p = subprocess.Popen([sys.executable, str(ROOT/'tools/mt/netgate.py'), str(cfg), str(work/'netgate.jsonl')],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            socket.create_connection(('127.0.0.1', port), 0.2).close(); return p, f'http://127.0.0.1:{port}'
        except OSError:
            time.sleep(0.1)
    p.kill(); raise RuntimeError('netgate did not listen')


def hosts(work):
    out = {}
    log = work/'netgate.jsonl'
    for line in (log.read_text().splitlines() if log.exists() else []):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get('host'):
            out[r['host']] = out.get(r['host'], True) and bool(r.get('passed'))
    return out


def script(work, name, body, proxy):
    """A shell script agent-scope keys agy's scope on (".agy" in its name)."""
    p = work/name
    p.write_text('#!/usr/bin/env bash\n'
                 f"cd '{work}'\n"
                 f'export HTTPS_PROXY={proxy} HTTP_PROXY={proxy} ALL_PROXY={proxy} https_proxy={proxy} http_proxy={proxy} '
                 f'all_proxy={proxy} NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1\n' + body + '\n')
    p.chmod(0o755)
    return p


def scoped(home, work, proxy, sh):
    env = dict(os.environ, POG_AGY_HOME=str(home))
    return [sys.executable, str(ROOT/'tools/agent-scope.py'), str(work), proxy, str(sh)], env


def until_prompt(cmd, env, cwd, seconds):
    """Run cmd on a terminal of its own; stop it when the sign-in screen shows or after seconds."""
    import pty
    master, slave = pty.openpty()
    p = subprocess.Popen(cmd, env=env, cwd=cwd, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    buf, seen, t0 = b'', None, time.time()
    while time.time() - t0 < seconds and p.poll() is None:
        r, _, _ = select.select([master], [], [], 0.5)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            buf += chunk
            text = ANSI.sub('', buf.decode('utf-8', 'replace'))
            if seen is None and SIGN_IN.search(text):
                seen = time.time() - t0
            if seen is not None and time.time() - t0 > seen + 3:    # the rest of the screen
                break
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except (ProcessLookupError, PermissionError):      # the group is gone (or only its leader is left)
            try:
                p.send_signal(sig)
            except ProcessLookupError:
                pass
        try:
            p.wait(10); break
        except subprocess.TimeoutExpired:
            continue
    os.close(master)
    return ANSI.sub('', buf.decode('utf-8', 'replace')), seen, p.returncode


def start(a):
    home, work = tree(Path(a.team_home), new=True)
    before = owner_folders()
    gp, proxy = gate(work)
    try:
        sh = script(work, '.agy-login.sh', 'exec /Users/owner/.local/bin/agy', proxy)
        cmd, env = scoped(home, work, proxy, sh)
        if a.until_prompt is None:
            rc = subprocess.run(cmd, env=env, cwd=work).returncode
            screen, seen = None, None
        else:
            screen, seen, rc = until_prompt(cmd, env, work, a.until_prompt)
            (work/'until-prompt.txt').write_text(screen)
    finally:
        gp.terminate()
    files = sorted(str(p.relative_to(home)) for p in home.rglob('*') if p.is_file())
    after = owner_folders()
    res = dict(action='start', team_home=str(home), sign_in_screen_after_s=seen, exit=rc, hosts=hosts(work),
               files=files, secrets_file=[f for f in files if f.endswith('secrets.json')],
               owner_agy_folders_unchanged=before == after, owner_agy_files=len(before),
               screen_tail=(screen or '')[-600:] if screen is not None else None)
    print(json.dumps(res, indent=1))
    return 0 if before == after else 1


def check(a):
    home, work = tree(Path(a.team_home), new=False)
    before = owner_folders()
    secrets = [p for p in home.rglob('secrets.json') if p.is_file()]
    checks = dict(secrets_file=dict(ok=bool(secrets), files=[dict(path=str(p.relative_to(home)), bytes=p.stat().st_size,
                                                                    mode=oct(p.stat().st_mode & 0o777)) for p in secrets]))
    gp, proxy = gate(work)
    try:
        # the keychain probe: a lookup of any generic password at all (attributes only, output discarded) finds none
        sh = script(work, '.agy-keychain.sh', 'security find-generic-password >/dev/null 2>&1; exit $?', proxy)
        cmd, env = scoped(home, work, proxy, sh)
        rc = subprocess.run(cmd, env=env, cwd=work, capture_output=True, timeout=60).returncode
        checks['keychain_probe'] = dict(ok=rc == 44, exit=rc)
        sh = script(work, '.agy-reply.sh', f"exec /Users/owner/.local/bin/agy -p '{PROMPT}' < /dev/null", proxy)
        cmd, env = scoped(home, work, proxy, sh)
        r = subprocess.run(cmd, env=env, cwd=work, capture_output=True, text=True, timeout=300)
        out = r.stdout + r.stderr
        checks['reply'] = dict(ok=r.returncode == 0 and 'OK' in r.stdout, exit=r.returncode, tail=out[-300:])
    finally:
        gp.terminate()
    seen = hosts(work)
    checks['gate'] = dict(ok=all(seen.values()), hosts=seen)
    checks['owner_agy_folders_unchanged'] = dict(ok=before == owner_folders())
    res = dict(action='check', team_home=str(home), passed=all(c['ok'] for c in checks.values()), checks=checks)
    print(json.dumps(res, indent=1))
    return 0 if res['passed'] else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    q = sub.add_parser('start'); q.add_argument('team_home'); q.add_argument('--until-prompt', type=float)
    q = sub.add_parser('check'); q.add_argument('team_home')
    a = ap.parse_args()
    sys.exit(start(a) if a.cmd == 'start' else check(a))


if __name__ == '__main__':
    main()
