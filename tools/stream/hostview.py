"""Host view: Nick's own Factorio client on air (Nick, 2026-10-17 16:39, spectating world n from pogwin: "it would be
interesting for the stream viewers to also see my view, so I can show them things").

  curl -X POST http://127.0.0.1:8788/hostview -d '{"on": true, "seconds": 900, "caption": "the new smelting column"}'
  curl -X POST http://127.0.0.1:8788/hostview -d '{"on": false}'      (or DELETE /hostview)

and from the host's own chat (the site's host link or his YouTube channel: viewers.py's host flag), never anyone
else's: "!view", "!view CAPTION", "!view off". Those lines are commands, not chat: they are not shown or relayed.

While on, OBS shows the capture "stream host" (factorio-nick.exe, tools/obs.py) in the on-air hole over the cameras
(cuts.py, program "host"), the director holds (no cut, no inset, no trio; segments and cues wait: onecam.py), and the
page's on-air card reads "NickWinter (host) · CAPTION" (default "showing the stream around"). It ends when turned off,
when his client leaves the game (the poll's connected players: live.py, HOST_PLAYER), or after `seconds` (default
20 min, at most 60). A chat notice line in the stream's chat feed when it starts and ends.

Kept in runs/RUN/director-host.json ({until, caption, by}; until is epoch seconds), so a serve.py restart keeps it;
writing or deleting the file by hand works too.
"""
import json, math, os, re, time

HOST_NAME = "NickWinter (host)"
HOST_PLAYER = "nick"  # his player in the game (tools/win/start-client.ps1 -PlayerName nick)
DEFAULT_CAPTION = "showing the stream around"
DEFAULT_S, MAX_S = 1200.0, 3600.0
COMMAND = re.compile(r"^\s*!view\b\s*(.*?)\s*$", re.I | re.S)


def parse_command(text):
    """A host chat line -> None (not a command), ("off",) or ("on", caption or None)."""
    m = COMMAND.match(text or "")
    if not m:
        return None
    rest = m.group(1).strip()
    if rest.lower() in ("off", "stop", "end"):
        return ("off",)
    return ("on", rest[:80] or None)


class HostControl:
    def __init__(self, director, path=None, notify=None, player=HOST_PLAYER):
        """notify(text): a notice line in the stream's chat feed (model.notice); player: his name in the game."""
        self.director, self.path, self.notify, self.player = director, path, notify, player
        self.mtime = None
        self.on = None  # what was applied: {until, caption, by}
        self.connected = None  # the game's connected player names, last read (sync)

    def label(self, caption):
        return f"{HOST_NAME} · {caption or DEFAULT_CAPTION}"

    def apply(self, data, now, why=None):
        try:
            until = float(data["until"]) if data else None
            host = {"until": until, "caption": str(data.get("caption") or "").strip()[:80] or None,
                    "by": str(data.get("by") or "operator")[:40]} if data and math.isfinite(until) and until > now else None
        except (KeyError, AttributeError, TypeError, ValueError, OverflowError):
            host = None
        if host:
            host["label"] = self.label(host["caption"])
        was = self.on
        self.on = host
        self.director.set_host(host, now)
        if host and not was:
            self.say(f"Nick is showing his view on stream: {host['caption'] or DEFAULT_CAPTION}")
        elif was and not host:
            self.say("Nick's view is off; back to the cameras" + (f" ({why})" if why else ""))
        return host

    def say(self, text):
        print(f"[hostview] {text}", flush=True)
        if self.notify:
            try:
                self.notify(text)
            except Exception as e:  # noqa: BLE001
                print(f"[hostview] notice failed: {type(e).__name__}: {e}", flush=True)

    def write(self, data):
        if not self.path:
            return
        if data is None:
            try:
                os.remove(self.path)
            except FileNotFoundError:
                pass
            self.mtime = None
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, self.path)
        self.mtime = os.stat(self.path).st_mtime_ns

    def start(self, seconds=None, caption=None, by="operator", now=None):
        now = time.time() if now is None else now
        secs = DEFAULT_S if seconds is None else max(10.0, min(MAX_S, float(seconds)))
        data = {"until": round(now + secs, 1), "caption": (str(caption).strip()[:80] or None) if caption else None, "by": str(by)[:40]}
        self.write(data)
        return self.apply(data, now), int(secs)

    def stop(self, why=None, now=None):
        now = time.time() if now is None else now
        self.write(None)
        self.apply(None, now, why)

    def request(self, body, now=None):
        """POST /hostview {on, seconds?, caption?, by?} -> (http code, reply)."""
        now = time.time() if now is None else now
        if not isinstance(body, dict) or not isinstance(body.get("on"), bool):
            return 400, {"error": "expected {\"on\": true|false, \"seconds\"?: 10..3600, \"caption\"?: text}"}
        if not body["on"]:
            self.stop("turned off", now)
            return 200, {"hostview": None}
        try:
            secs = float(body["seconds"]) if body.get("seconds") is not None else None
            if secs is not None and not math.isfinite(secs):
                raise ValueError()
        except (TypeError, ValueError):
            return 400, {"error": "seconds must be a number (10..3600)"}
        if self.connected is not None and self.player not in self.connected:
            return 409, {"error": f"{self.player}'s client is not in the game (connected: {', '.join(self.connected) or 'none'})"}
        host, secs = self.start(secs, body.get("caption"), body.get("by") or "operator", now)
        return 200, {"hostview": dict(host, seconds=secs)}

    def command(self, msg, now=None):
        """A chat message (viewers.py, before the filter): True when it was the host's !view command (consumed)."""
        if not msg.get("host"):
            return False
        cmd = parse_command(msg.get("text"))
        if not cmd:
            return False
        if cmd[0] == "off":
            self.stop("he turned it off", now)
        elif self.connected is not None and self.player not in self.connected:
            self.say(f"!view: {self.player}'s client is not in the game, so there is no view to show")
        else:
            self.start(None, cmd[1], "host chat", now)
        return True

    def sync(self, now=None, connected=None):
        """Each tick: the file again when it changed (a restart, a hand edit); the time limit; his client gone
        (connected: the game's connected player names, None when not read)."""
        now = time.time() if now is None else now
        if connected is not None:
            self.connected = list(connected)
        if self.path:
            try:
                m = os.stat(self.path).st_mtime_ns
            except OSError:
                m = None
            if m != self.mtime:
                self.mtime = m
                data = None
                if m is not None:
                    try:
                        with open(self.path) as f:
                            data = json.load(f)
                    except (OSError, ValueError):
                        pass
                self.apply(data, now)
        if self.on and now >= self.on["until"]:
            self.stop("its time ran out", now)
        elif self.on and connected is not None and self.player not in connected:
            self.stop("his client left the game", now)
