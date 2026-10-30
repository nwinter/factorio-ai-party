"""Durable, per-line host speech lifecycle. Completed capture receipts alone establish heard speech."""
import json
import os
import threading
import time
import uuid


class PlaybackMemory:
    def __init__(self, path=None):
        self.path = path
        self.lock = threading.RLock()
        self.groups = {}
        if path:
            try:
                with open(path) as f:
                    self.groups = json.load(f).get('groups', {})
                for gid, group in self.groups.items():
                    self._bind_directions(gid, group)
                    for row in group['lines']:
                        if row['state'] == 'generated':
                            row.update(state='error', reason='generation interrupted by restart')
            except (OSError, ValueError):
                pass

    @staticmethod
    def _bind_directions(gid, group):
        """Migrate the old event-wide list once, against the FULL original exchange, never a resume subset."""
        old = group['event'].pop('directions', None) or []
        directions = group.setdefault('directions', {})
        for i, row in enumerate(group['lines']):
            row.setdefault('id', f'{gid}:{i}')
            directions.setdefault(row['id'], old[i] if i < len(old) else None)

    def save(self):
        with self.lock:
            self._save()

    def _save(self):
        if not self.path:
            return
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        tmp = self.path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump({'groups': self.groups}, f, ensure_ascii=False)
        os.replace(tmp, self.path)

    def generated(self, lines, event, facts, backend, now=None):
        with self.lock:
            gid = uuid.uuid4().hex
            self.groups[gid] = {'event': dict(event), 'facts': facts, 'backend': backend,
                                't': time.time() if now is None else now, 'topic_heard': False,
                                'lines': [{'who': who, 'text': text, 'state': 'generated', 'attempt': 0,
                                           'generated': time.time() if now is None else now}
                                          for who, text in lines]}
            self._bind_directions(gid, self.groups[gid])
            # Bound disk/memory, retaining active and interrupted explanations first.
            for key, group in list(self.groups.items()):
                if len(self.groups) <= 200:
                    break
                if (all(r['state'] in ('completed', 'skipped', 'expired', 'error', 'cancelled') for r in group['lines'])
                        and max((r.get('completed', 0) for r in group['lines']), default=0) < time.time() - 300):
                    del self.groups[key]
            self.save()
            return gid

    def change(self, gid, index, state, **values):
        with self.lock:
            row = self.groups[gid]['lines'][index]
            if row['state'] == 'completed':
                return
            row.update(state=state, **values)
            self.save()

    def queued(self, gid, index, meta):
        with self.lock:
            row = self.groups[gid]['lines'][index]
            row.pop('started', None)
            self.change(gid, index, 'queued', cid=meta['id'], expires=meta.get('expires', time.time() + 25),
                        duration=meta.get('duration', 20), queued=time.time(), attempt=row['attempt'] + 1)

    def receipts(self, status, now=None):
        """Apply ordered capture receipts; returns newly completed (group, index) pairs exactly once."""
        now = time.time() if now is None else now
        completed = []
        changed = False
        with self.lock:
            by_id = {r.get('cid'): (gid, i, r) for gid, g in self.groups.items()
                     for i, r in enumerate(g['lines']) if r.get('cid')}
            for receipt in status.get('receipts') or []:
                hit = by_id.get(receipt.get('id'))
                if not hit:
                    continue
                gid, index, row = hit
                if row['state'] == 'completed':
                    continue
                state = receipt.get('state')
                if state == 'start' and row['state'] == 'queued':
                    row.update(state='started', started=receipt['t'])
                    changed = True
                elif state == 'end' and receipt.get('completed'):
                    row.update(state='completed', completed=receipt['t'])
                    completed.append((gid, index))
                    changed = True
                elif receipt.get('ended'):
                    interrupted = row.get('started') is not None and state != 'skip'
                    target = 'interrupted' if interrupted else 'error' if state == 'error' else 'skipped'
                    reason = receipt.get('reason') or state
                    if row['state'] != target or row.get('reason') != reason:
                        row.update(state=target, reason=reason)
                        changed = True
            # A disappearing listener must release topics even if it never sends a skip/no_end.
            # Use the authoritative queue: narrator holds can extend expiry in the page.
            live = {r['id'] for key in ('playing', 'queued') for r in status.get(key) or []}
            for gid, index, row in by_id.values():
                if row['state'] == 'queued' and row['cid'] not in live and now > row.get('expires', now) + 5:
                    row.update(state='expired', reason='no playback receipt')
                    changed = True
                elif row['state'] == 'started' and row['cid'] not in live and now > row['started'] + row.get('duration', 20) + 5:
                    row.update(state='interrupted', reason='capture disconnected')
                    changed = True
            if changed:
                self.save()
        return completed

    def held_points(self):
        with self.lock:
            return {g['event']['point']['id'] for g in self.groups.values() if g['event'].get('point', {}).get('id')
                    and any(r['state'] in ('generated', 'queued', 'started') for r in g['lines'])}

    def unfinished(self):
        """The uncompleted lines of an interrupted explanation; completed lines never enter a retry."""
        with self.lock:
            for gid, g in self.groups.items():
                if g['backend'] == 'voice':
                    continue
                if any(r['state'] in ('queued', 'started', 'generated') for r in g['lines']):
                    continue
                continuation = (any(r['state'] == 'completed' for r in g['lines']) and
                                any(r['state'] in ('error', 'skipped', 'expired') for r in g['lines']))
                if not any(r['state'] == 'interrupted' for r in g['lines']) and not continuation:
                    continue
                indices = [i for i, r in enumerate(g['lines']) if r['state'] != 'completed']
                return gid, indices
        return None
