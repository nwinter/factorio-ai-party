"""Bounded browser-layer telemetry. It does not attest to OBS's final composition."""
from collections import OrderedDict
import json
import math
import re
import threading
import time


class OverlayHealth:
    MAX_BYTES = 32768

    def __init__(self, log_path=None):
        self.log_path = log_path
        self.sessions = OrderedDict()
        self.lock = threading.Lock()

    def record(self, body):
        if not isinstance(body, dict):
            raise ValueError('expected object')
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', str(body.get('session', ''))):
            raise ValueError('invalid session')
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,24}', str(body.get('page', ''))):
            raise ValueError('invalid page')
        # Keep diagnostics bounded, JSON-safe and detached from callers. No arbitrary deep payloads in status/logs.
        def clean(value, depth=0):
            if depth > 5:
                return None
            if isinstance(value, str):
                return value[:600]
            if value is None or isinstance(value, bool):
                return value
            if isinstance(value, (int, float)):
                return value if math.isfinite(value) else None
            if isinstance(value, list):
                return [clean(v, depth + 1) for v in value[:20]]
            if isinstance(value, dict):
                return {str(k)[:64]: clean(v, depth + 1) for k, v in list(value.items())[:24]}
            return None
        row = clean({k: body[k] for k in ('session', 'page', 'capture', 'path', 'age_s', 'classes', 'state_age_s',
            'state_source', 'static_version', 'recap', 'program_layout', 'captions', 'layers', 'requests', 'errors') if k in body})
        row['received_at'] = time.time()
        with self.lock:
            self.sessions.pop(row['session'], None)
            self.sessions[row['session']] = row
            while len(self.sessions) > 16:
                self.sessions.popitem(last=False)
            if self.log_path:
                with open(self.log_path, 'a') as f:
                    f.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')
        return row

    def status(self):
        with self.lock:
            return {'sessions': list(self.sessions.values()), 'scope': 'browser layers; compare OBS program screenshot'}
