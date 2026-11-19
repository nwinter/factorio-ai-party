#!/usr/bin/env python3
"""(mt309) The POG Codex home: a separate CODEX_HOME with its own device login for scoped Codex players.

  codex_pog_home.py init [HOME]            make HOME (default ~/.pog-codex/home, mode 700) and its config.toml:
                                           credentials in HOME/auth.json (never the Keychain, whose entry could
                                           collide with the owner's), no update check
  codex_pog_home.py status [HOME]          logged in or not (auth.json present; its contents are never printed)
  codex_pog_home.py trust HOME DIR         trust one player workspace in HOME/config.toml (its .codex/config.toml
                                           then applies)
  codex_pog_home.py archive HOME DEST      move HOME/sessions/* (one run's transcripts) to DEST, so a later arm
                                           cannot read an earlier arm's sessions

The login itself is the owner's, once: CODEX_HOME=HOME codex login --device-auth. It starts its own refresh-token
chain; ~/.codex and its auth.json are never copied or written by POG (tools/mt/codex_scope_smoke.py only hashes
that auth.json, to prove it unchanged).
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import sys

DEFAULT = Path.home()/'.pog-codex'/'home'
CONFIG = '''# (mt309) POG Codex home for scoped players (tools/codex_pog_home.py); not the owner's ~/.codex
cli_auth_credentials_store = "file"
check_for_update_on_startup = false

'''


def init(home):
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(home, 0o700); os.chmod(home.parent, 0o700)
    cfg = home/'config.toml'
    if not cfg.exists():
        cfg.write_text(CONFIG); os.chmod(cfg, 0o600)
    assert 'cli_auth_credentials_store = "file"' in cfg.read_text(), f'{cfg} must keep credentials in auth.json'
    return status(home)


def status(home):
    auth = home/'auth.json'
    return dict(home=str(home), exists=home.is_dir(), logged_in=auth.is_file() and auth.stat().st_size > 0,
                file_store='cli_auth_credentials_store = "file"' in ((home/'config.toml').read_text() if (home/'config.toml').exists() else ''))


def trust(home, d):
    d = os.path.abspath(d)
    cfg = home/'config.toml'
    assert cfg.exists(), f'{home} is not initialised (codex_pog_home.py init)'
    header = f'[projects.{json.dumps(d)}]'
    with cfg.open('r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        text = f.read()
        if header not in text:
            f.write(('' if text.endswith('\n') else '\n') + f'\n{header}\ntrust_level = "trusted"\n')
    return dict(trusted=d)


def archive(home, dest):
    src = home/'sessions'
    moved = []
    if src.is_dir():
        dest.mkdir(parents=True, exist_ok=True)
        for p in sorted(src.iterdir()):
            target = dest/p.name
            if target.exists():
                for q in p.rglob('*'):
                    if q.is_file():
                        (target/q.relative_to(p)).parent.mkdir(parents=True, exist_ok=True)
                        shutil.move(str(q), target/q.relative_to(p))
                shutil.rmtree(p)
            else:
                shutil.move(str(p), target)
            moved.append(p.name)
    return dict(moved=moved, dest=str(dest))


def main(argv=None):
    a = sys.argv[1:] if argv is None else argv
    if not a or a[0] not in ('init', 'status', 'trust', 'archive'):
        print(__doc__); return 2
    home = Path(a[1]).expanduser() if len(a) > 1 else DEFAULT
    out = {'init': lambda: init(home), 'status': lambda: status(home),
           'trust': lambda: trust(home, a[2]), 'archive': lambda: archive(home, Path(a[2]))}[a[0]]()
    print(json.dumps(out))


if __name__ == '__main__':
    sys.exit(main())
