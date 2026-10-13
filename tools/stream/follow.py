"""Operator follow: pin the camera on air on one agent (operator task 2026-10-13 12:55, after Nick: "Sol says it's
gonna try to fight a Demolisher on Vulcanus ... is there a good way to ensure we don't miss entirety of key battles
like that?").

  curl -X POST localhost:8787/follow -d '{"agent": "sol", "seconds": 900, "label": "Sol vs the Demolisher", "by": "nick"}'
  curl -X DELETE localhost:8787/follow

  curl -X POST localhost:8787/follow -d '{"agent": "sol", "until_battle": true, "seconds": 1200, "label": "Sol vs the Demolisher"}'
    (Nick 14:47: ends 15 s after a battle with Sol or around Sol is over; seconds is the longest wait for it)

seconds: at most 1800 (default 600). The follow is kept in runs/RUN/director-follow.json ({agent, until, label, by};
until is epoch seconds), so a serve.py restart keeps it; writing or deleting that file by hand works too (the service
reads it again when it changes). While it is on, onecam.py keeps the camera on air on that agent (module doc there).
"""
import json, os, time

MAX_S = 1800.0
DEFAULT_S = 600.0


class FollowControl:
    def __init__(self, director, path=None, agents=()):
        """agents: [(name, display_name)] the follow may name (either, any case)."""
        self.director = director
        self.path = path
        self.agents = list(agents)
        self.mtime = None  # the file's mtime when last read (None: absent)

    def resolve(self, who):
        w = str(who or "").strip().lower()
        for name, disp in self.agents:
            if w in (name.lower(), str(disp or "").lower()):
                return name
        return None

    def apply(self, f, now):
        if f and f.get("agent") and float(f.get("until") or 0) > now:
            self.director.set_follow(f["agent"], float(f["until"]), f.get("label"), f.get("by"), now,
                                     until_battle=bool(f.get("until_battle")))
        else:
            self.director.set_follow(None, 0)

    def write(self, f):
        if not self.path:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(f, fh)
        os.replace(tmp, self.path)
        self.mtime = os.path.getmtime(self.path)
        self.written = f

    def request(self, body, now=None):
        """POST /follow {agent, seconds?, label?, by?} -> (http code, reply)."""
        now = now or time.time()
        name = self.resolve(body.get("agent"))
        if not name:
            return 400, {"error": f"unknown agent {body.get('agent')!r}", "agents": [n for n, _ in self.agents]}
        try:
            secs = float(body.get("seconds") or DEFAULT_S)
        except (TypeError, ValueError):
            return 400, {"error": "seconds must be a number"}
        secs = max(1.0, min(MAX_S, secs))
        label = str(body.get("label") or "").strip()[:80] or None
        f = {"agent": name, "until": round(now + secs, 1), "label": label, "by": str(body.get("by") or "operator")[:40]}
        if body.get("until_battle"):
            f["until_battle"] = True  # seconds: the longest wait for the battle; it ends 15 s after its battle
        self.write(f)
        self.apply(f, now)
        print(f"[follow] {time.strftime('%H:%M:%S', time.localtime(now))} {f['by']}: follow {name} "
              + ("until its battle is over (waiting at most " if f.get("until_battle") else "for ") + f"{int(secs)} s"
              + (")" if f.get("until_battle") else "") + (f" ({label})" if label else ""), flush=True)
        return 200, dict(f, seconds=int(secs))

    def clear(self, now=None):
        """DELETE /follow."""
        now = now or time.time()
        if self.path:
            try:
                os.remove(self.path)
            except FileNotFoundError:
                pass
            self.mtime = None
        self.apply(None, now)
        print(f"[follow] {time.strftime('%H:%M:%S', time.localtime(now))} follow off", flush=True)
        return 200, {"follow": None}

    def sync(self, now=None):
        """Each tick: read the file again when it appeared, changed or went away (a restart, or a hand edit)."""
        if not self.path:
            return
        now = now or time.time()
        try:
            m = os.path.getmtime(self.path)
        except OSError:
            m = None
        if m == self.mtime:
            # the director shortened an until_battle follow (its battle ended): the file says so too, so a restart
            # does not bring the follow back
            d, w = self.director.follow, getattr(self, "written", None)
            if d and w and d.get("ended_by") and float(w.get("until") or 0) > d["until"] + 1:
                self.write(dict(w, until=round(d["until"], 1)))
            return
        self.mtime = m
        f = None
        if m is not None:
            try:
                with open(self.path) as fh:
                    f = json.load(fh)
                self.written = f
                name = self.resolve(f.get("agent"))
                f = dict(f, agent=name) if name else None
            except (OSError, ValueError, AttributeError):
                f = None
        self.apply(f, now)
        if f and float(f.get("until") or 0) > now:
            print(f"[follow] read {self.path}: {f['agent']} until "
                  f"{time.strftime('%H:%M:%S', time.localtime(float(f.get('until') or 0)))}", flush=True)
