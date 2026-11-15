"""Unlisted rehearsal stream checks; keep publication alive across the game restore."""
import time

from run_state import ROOT, command, op_dir, read, write


def before_restore(run):
    from public_session import owned_pid
    from public_stream import owned
    from stream_drill import snapshot, healthy
    op = op_dir(run)
    session = read(op/'public-session.json', {})
    assert session.get('run') == run and session.get('privacy') == 'unlisted', 'unlisted owned session required'
    assert session.get('run_mode') == 'full' and session.get('phase') == 'live', 'live full-mode session required'
    assert owned_pid(session.get('pid'), run), 'publication supervisor missing'
    assert owned(read(op/'public-stream.json', {}), run), 'staging supervisor missing'
    state = snapshot(op)
    assert state['youtube']['privacyStatus'] == 'unlisted', 'YouTube privacy changed'
    assert healthy(state, op), 'stream must be healthy before restoring the game'
    return state


class RecoveryProof:
    def __init__(self, run, before):
        self.op, self.before = op_dir(run), before
        self.started = time.time()
        self.since = self.key = self.previous = None

    def __call__(self):
        from stream_drill import snapshot, healthy
        now = time.time()
        row = dict(started=self.started, at=now, before=self.before)
        accepted = False
        try:
            after = snapshot(self.op)
            row['after'] = after
            assert after['session']['privacy'] == after['youtube']['privacyStatus'] == 'unlisted'
            assert healthy(after, self.op) and after['game']['tick'] > self.before['game']['tick']
            key = (after['camera'].get('ProcessId'), after['staging']['tunnel_pid'], after['video'])
            current = (after['game']['tick'], after['output']['outputBytes'])
            if self.since is None or self.key != key or (self.previous and any(a <= b for a,b in zip(current,self.previous))):
                self.since = now
            self.key, self.previous = key, current
            row.update(stable_since=self.since, stable_seconds=now-self.since)
            accepted = now-self.since >= 60
        except Exception as e:
            self.since = self.key = self.previous = None
            row['error'] = type(e).__name__+': '+str(e)[:200]
        row['accepted'] = accepted
        write(self.op/'restore-stream.json', row)
        return accepted


def stop_publication(run):
    import sys
    from public_session import owned_pid
    op = op_dir(run)
    if not (op/'public-session.json').exists():
        return
    state = read(op/'public-session.json')
    assert state.get('run') == run and state.get('privacy') == 'unlisted', 'refusing foreign/public session teardown'
    command([sys.executable, ROOT/'tools/mt/public_session.py', 'stop', run, '--keep-world'])
    end = time.time()+180
    while owned_pid(state.get('pid'), run) and time.time() < end:
        time.sleep(1)
    state = read(op/'public-session.json')
    assert not owned_pid(state.get('pid'), run) and state.get('phase') == 'stopped', state
