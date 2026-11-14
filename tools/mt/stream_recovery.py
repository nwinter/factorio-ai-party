"""Operator-only, bounded recovery primitives shared by the stream supervisors."""
import hashlib
import json
from pathlib import Path
import time

from run_state import alert, read, write


class Recovery:
    def __init__(self, op, name):
        self.op = Path(op)
        self.path = self.op / (name + '-recovery.json')
        self.states = read(self.path, {})

    def event(self, component, event, **data):
        with (self.op/'stream-recovery.jsonl').open('a') as out:
            out.write(json.dumps(dict(t=time.time(), component=component, event=event, **data))+'\n')

    def run(self, component, check, repair, *, grace=20, cooldown=30, now=None):
        """Only an observed healthy check clears a failure. Repair success alone never does.

        A failed dependency should skip calling its dependants. Backoff persists across
        controller restarts, caps at five minutes, and alerts every fifteen minutes.
        """
        now = time.time() if now is None else now
        state = self.states.setdefault(component, {})
        try:
            check()
        except (Exception, SystemExit) as e:
            reason = str(e)[:300]
            if 'since' not in state:
                state.update(since=now, attempts=0, next=now+grace)
                self.event(component, 'unhealthy', reason=reason)
            state['reason'] = reason
            if now-state.get('alerted', 0) >= 900:
                alert(self.op, 'stream-'+component, reason)
                state['alerted'] = now
            if now >= state['next']:
                state['attempts'] += 1
                state['next'] = now+min(300, cooldown*2**min(4,state['attempts']-1))
                # Persist before side effects; a crash does not erase the retry budget.
                write(self.path, self.states)
                self.event(component, 'repair', attempt=state['attempts'], reason=reason)
                try:
                    repair()
                except (Exception, SystemExit) as error:
                    state['repair_error'] = str(error)[:300]
                    self.event(component, 'repair-error', reason=state['repair_error'])
            write(self.path, self.states)
            return False
        else:
            if 'since' in state:
                self.event(component, 'recovered', seconds=now-state['since'], attempts=state['attempts'])
                alert(self.op, 'stream-'+component+'-recovered', f"healthy after {now-state['since']:.0f}s")
            self.states[component] = {}
            write(self.path, self.states)
            return True


class FrameProgress:
    """Detect a frozen OBS camera, with a progressing game clock and successful cuts.

    Exact JPEG equality tolerates a quiet/paused world. A live director visiting
    different teams should change pixels; first release the hook, then restart the
    camera if that fails. A disconnected/modalled client is detected separately.
    """
    def __init__(self):
        self.digest, self.since, self.tick, self.cut = None, None, None, None

    def observe(self, data, tick, cut, paused, now):
        digest = hashlib.sha256(data.encode()).hexdigest()
        if paused or digest != self.digest or self.tick is None or tick < self.tick:
            self.digest, self.since, self.tick, self.cut = digest, now, tick, cut
            return True
        return not (now-self.since >= 120 and tick-self.tick >= 3600 and cut != self.cut)


def require(value, message):
    if not value:
        raise RuntimeError(message)


def terminate(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=10)
        except Exception:
            child.kill()
            child.wait(timeout=5)
