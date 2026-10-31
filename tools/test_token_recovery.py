#!/usr/bin/env python3
"""Offline recovery contract: each CLI, compaction, shift change, overflow and missing hook.

Executes the actual hook handlers and generated agy loop text; no live CLI or game.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agy_rules
import brief
import context
import handover
import testsafe

ROOT = Path(__file__).resolve().parents[1]
KINDS = ('claude', 'codex', 'grok', 'agy', 'muse')


def hook(d, event, *args):
    return subprocess.check_output([sys.executable, str(ROOT / 'tools/context.py'), 'hook', event, *args],
                                   input=json.dumps({'cwd': str(d), 'source': 'compact'}), text=True, env=testsafe.env())


def fallback_received(d, kind):
    # Instruction contract, not a simulated model: these are the required recovery reads.
    core = brief.sample(kind)
    assert 'Without a brief, read `notes.md`' in core
    assert 'or read notes.md if none arrived' in core
    return (d / 'notes.md').read_text() + (d / 'deadline.txt').read_text() + core


def received(d, kind):
    if kind == 'codex':
        # There is no recovery-brief hook after compaction.
        return fallback_received(d, kind)
    if kind == 'agy':
        return agy_rules.digest(str(d), with_rules=True)
    hook(d, 'post-compact', *(['--mark'] if kind in ('grok', 'muse') else []))
    if kind == 'claude':
        return hook(d, 'session-compact')
    out = json.loads(hook(d, 'post-tool'))['hookSpecificOutput']['additionalContext']
    assert hook(d, 'post-tool') == '', 'a compaction is injected once'
    return out


def main():
    replies = [json.dumps({'response': {'result': {'item': {
        'id': 71, 'title': 'Delivery', 'owner': owner, 'status': 'doing'}}}}) for owner in ('sol', 'astra')]
    assert context.my_claims(replies, 'sol', keep=None) == [], 'latest recorded ownership wins'
    assert context.my_claims(replies, 'astra', keep=None) == ['#71 Delivery (doing)']
    notes = ('## Now\nOPEN_WORK: delivery #71 pending\n## Claims and coordinates\n'
             'OWNER: sol, chest (4,9)\n## Open board items\n#72 owned by sol, doing\n'
             '## Safety checks\nSAFETY: action still running; ./fh wait before acting\n')
    with tempfile.TemporaryDirectory() as temp:
        for kind in KINDS:
            old, new = Path(temp) / kind / 'shift1' / 'sol', Path(temp) / kind / 'shift2' / 'sol'
            old.mkdir(parents=True)
            new.mkdir(parents=True)
            (old / 'notes.md').write_text(notes)
            (old / 'deadline.txt').write_text('2030-01-01 12:00 UTC')
            # The real shift carry function, with no journal and a fixed new shift deadline.
            handover.carry(str(old / 'notes.md'), str(old / 'journal.jsonl'), str(new / 'notes.md'), 'shift1', 'sol')
            (new / 'deadline.txt').write_text('2030-01-02 12:00 UTC')
            for d in (old, new):
                with contextlib.redirect_stdout(io.StringIO()):
                    context.setup(kind, 'test-model', str(d))
                # Only agy supplies a brief on a fresh shift launch. The others read carried
                # notes; their compaction hooks are exercised in the old workspace and below.
                out = fallback_received(d, kind) if d == new and kind != 'agy' else received(d, kind)
                for fact in ('OPEN_WORK', 'OWNER', '#72', 'SAFETY', (d / 'deadline.txt').read_text()):
                    assert fact in out, (kind, d, fact, out)
                if d == new:
                    assert '2030-01-01' not in out, (kind, 'stale deadline')
            # More than the entire brief in each mandatory section, with facts at the end.
            (new / 'notes.md').write_text(notes.replace('OPEN_WORK', 'x' * 7000 + 'OPEN_WORK')
                                         .replace('OWNER', 'y' * 7000 + 'OWNER')
                                         .replace('SAFETY', 'z' * 7000 + 'SAFETY'))
            (new / '.ground_rules.json').write_text(json.dumps({'lines': ['🙂漢' * 4000 + 'RULE_END']}))
            if kind != 'codex':
                out = received(new, kind)
                assert len(out.encode()) <= 3001, (kind, len(out.encode()))
                for label in ('Identity and deadline', 'Ground rules', 'open commitments', 'Now (notes.md)', 'live checks'):
                    assert label in out, (kind, label)
                assert '2030-01-02' in out and 'Player/owner: sol' in out
                assert 'Before acting, read the marked fields' in out
                assert './fh call status and ./fh call chat' in out
                detail = (new / '.recovery-detail.md').read_text()
                assert all(x in detail for x in ('OPEN_WORK', 'OWNER', 'SAFETY', '#72', 'RULE_END'))
                # A missing/unwritable overflow file cannot masquerade as a complete digest.
                with patch('builtins.open', side_effect=OSError('read-only')):
                    fallback = context.recovery_text(str(new), ['head'], [('## Field', 'x' * 9000)])
                assert 'Recovery brief unavailable' in fallback and 'read notes.md, deadline.txt' in fallback
        launch = (ROOT / 'tools/launch-agent.sh').read_text()
        assert 'Re-read notes.md' not in launch and 'read it and deadline.txt first' not in launch
        assert 'if none arrived, read notes.md' in launch
        sentence = subprocess.check_output(['bash', str(ROOT / 'tools/launch-agent.sh'), '--resume-sentence'],
                                           text=True, env=testsafe.env())
        assert 'new deadline.txt' in sentence and 'if no recovery brief arrived' in sentence
    print('token recovery: 5 CLI kinds, compaction + shift carry + overflow + fallback passed')


if __name__ == '__main__':
    main()
