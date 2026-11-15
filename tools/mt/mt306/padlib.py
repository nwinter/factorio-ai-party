"""(mt306, private) RCON helpers for the claimed imac2 2.1.24 server. Never world n."""
import json, os, sys, time
from pathlib import Path
from config import TREE, HERE, CODE, PYTHON, CLAIM, PASSWORD_FILE, LABEL
sys.path.insert(0, str(TREE / 'tools'))
import pog  # noqa: E402
_r = None
def rc():
    global _r
    assert 'eng-mt306 owns imac2' in CLAIM.read_text(), 'no claim'
    if _r is None:
        _r = pog.Rcon('imac.local', 27475, PASSWORD_FILE.read_text().strip(), timeout=120)
    return _r
def raw(cmd):
    assert 'eng-mt306 owns imac2' in CLAIM.read_text(), 'lost claim'
    return rc().command(cmd)
def lua(code, ctx=''):
    one = ' '.join(l.strip() for l in code.strip().splitlines() if l.strip() and not l.strip().startswith('--'))
    out = raw('/silent-command ' + (ctx + ' ' if ctx else '') + one)
    try:
        return json.loads(out)
    except ValueError:
        raise RuntimeError(out[:3000]) from None
def record(name, data):
    p = HERE / f'{name}.json'
    rows = json.loads(p.read_text()) if p.exists() else []
    rows.append({'at': time.strftime('%Y-%m-%d %H:%M:%S'), **data})
    p.write_text(json.dumps(rows, indent=1) + '\n')
    pass
def alive():
    try:
        return raw('/silent-command rcon.print(game.tick)').strip()
    except Exception as e:
        return 'DEAD ' + repr(e)[:200]
import uuid
def call(action, args=None):
    q = {'id': 'mt306-' + uuid.uuid4().hex, 'action': action, 'args': args or {}, 'operator': True}
    def ls(text):
        level = 0
        while f"]{'=' * level}]" in text: level += 1
        return f"[{'=' * level}[{text}]{'=' * level}]"
    out = json.loads(raw('/silent-command rcon.print(remote.call("agent_harness","dispatch",' + ls(json.dumps(q)) + '))'))
    if not out.get('ok'): raise RuntimeError(str(out)[:2000])
    return out.get('result')
