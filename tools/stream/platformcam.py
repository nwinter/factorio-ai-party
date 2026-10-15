"""Operator platform hold: POST /platform {name, seconds?, label?, by?}, DELETE /platform.

Kept in runs/RUN/director-platform.json ({name, until, label, by}, epoch seconds), including across restarts.
Manual edits/deletion work too. A platform hold takes priority over /follow; the follow resumes if still live.
The controller uses the director's existing platform snapshot, with no extra game reads.
"""
import json, math, os, time

from follow import DEFAULT_S, MAX_S


class PlatformControl:
    def __init__(self, director, path=None):
        self.director, self.path, self.mtime = director, path, None

    def resolve(self, name):
        name = str(name or "").strip().casefold()
        return next((n for n in self.director.plat_rows if n.casefold() == name), None)

    def apply(self, data, now):
        try:
            name, until = data.get("name"), float(data.get("until", 0))
            if not isinstance(name, str) or not name.strip() or not math.isfinite(until) or until <= now:
                data = None
        except (AttributeError, TypeError, ValueError, OverflowError):
            data = None
        self.director.platform_follow = {"name": name.strip(), "until": until,
                                         "label": str(data.get("label") or "").strip()[:80] or None,
                                         "by": str(data.get("by") or "operator")[:40]} if data else None

    def request(self, body, now=None):
        now = time.time() if now is None else now
        if not isinstance(body, dict):
            return 400, {"error": "expected an object with name and optional seconds, label, by"}
        name = self.resolve(body.get("name"))
        if not name:
            return 400 if self.director.plat_rows else 409, {
                "error": f"unknown platform {body.get('name')!r}" if self.director.plat_rows else "no platforms read yet",
                "platforms": list(self.director.plat_rows)}
        if not ((self.director.plat_rows.get(name) or {}).get("view") or {}).get("surface"):
            return 409, {"error": f"no camera view for platform {name}"}
        try:
            secs = float(body.get("seconds", DEFAULT_S))
            if not math.isfinite(secs):
                raise ValueError()
        except (TypeError, ValueError, OverflowError):
            return 400, {"error": "seconds must be a finite number"}
        secs = max(1.0, min(MAX_S, secs))
        data = {"name": name, "until": round(now + secs, 1),
                "label": str(body.get("label") or "").strip()[:80] or None,
                "by": str(body.get("by") or "operator")[:40]}
        if self.path:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.replace(tmp, self.path)
            self.mtime = os.stat(self.path).st_mtime_ns
        self.apply(data, now)
        print(f"[platform] {data['by']}: {name} for {int(secs)} s", flush=True)
        return 200, dict(data, seconds=int(secs))

    def clear(self, now=None):
        if self.path:
            try:
                os.remove(self.path)
            except FileNotFoundError:
                pass
        self.mtime = None
        self.apply(None, time.time() if now is None else now)
        print("[platform] hold off", flush=True)
        return 200, {"platform": None}

    def sync(self, now=None):
        if not self.path:
            return
        now = time.time() if now is None else now
        try:
            m = os.stat(self.path).st_mtime_ns
        except OSError:
            m = None
        if m == self.mtime:
            return
        self.mtime = m
        data = None
        if m is not None:
            try:
                with open(self.path) as f:
                    data = json.load(f)
            except (OSError, ValueError):
                pass
        self.apply(data, now)
