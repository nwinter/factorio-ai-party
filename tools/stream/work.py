"""Work an agent does away from its body, for the cameras (docs/STREAM-NOTES.md "Following the work").

Cameras follow bots' bodies, but in Space Age every agent stands on Nauvis while it builds a platform remotely:
place_ghosts / paste / blueprint_place / deconstruct with platform=NAME, built by the platform's hub. The game
journals nothing about who placed a ghost, but the agent's own fh journal does: tools/new-run.sh makes every agent's
fh append each request (action and args) to runs/RUN/AGENT/journal.jsonl, beside the run's stream.json. WorkFeed
tails those files from where they end when the service starts (the past is not replayed), reads only new bytes each
poll, and keeps the requests that place or remove things. live.py then decides which ones land away from the body.
The same rows feed waitcard.py and workcard.py's repeating requests; a bounded tail at startup recovers current waits only, without replaying work.
Every request with a position, area or list also becomes an attention point (attention.py), taken by live.py with
take_attention().

./shot is not here: the shot script calls fh without the journal and always centres on the character.
"""
import json, os, re, time

import attention
from waitcard import WaitFeed
from workcard import RepeatFeed

# Actions whose target can be away from the body: the runtime runs these against a platform's surface when they
# carry platform=NAME (vendor/factorio-harness runtime.lua on_platform), else at the given positions on the body's
# surface (ghosts, paste and deconstruction need no walking).
REMOTE = {"place_ghosts": "building", "paste": "pasting a blueprint", "blueprint_place": "pasting a blueprint",
          "deconstruct": "deconstructing", "cancel_deconstruction": "cancelling deconstruction",
          "remove_ghosts": "removing ghosts"}
# Platform actions that count only with platform=NAME (else they act where the body is): views and settings through
# remote view (runtime.lua on_platform), a rocket launched to the platform, cargo dropped from its hub, its schedule
# and hub requests (space.lua).
ON_PLATFORM = {"inspect": "inspecting", "configure": "configuring", "launch": "launching a rocket to",
               "drop": "dropping cargo from", "platform_schedule": "scheduling", "requests": "setting requests on"}
MAX_READ = 1 << 20  # per file per poll: a burst of observe replies cannot stall the tick
VEHICLE_KEEP = 600.0  # seconds a remote vehicle's last read is kept (the director judges staleness itself)
POS_RE = re.compile(r"\((-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\)")


class VehicleFeed:
    """(d26 batch222 CD, viewer Aurora site:4851: "follow a remotely controlled Spidertron while it moves or fights, using
    its position") Each agent's latest vehicle by remote view, from its journal's `vehicle {remote: true, vehicle}`
    replies (a spidertron's go_to or route read: its position, speed and route; a car or tank's drive: "by remote view:
    tank (-40,-150), unit_number 311799; your character stays at ..."): {vehicle, unit_number, position, speed (km/h,
    when read), target, t (epoch, the reply's)}. Opus's spidertron in shift77: a read about every 5 s while it walks."""

    def __init__(self):
        self.pending = {}  # request id -> (agent, args)
        self.rows = {}     # agent -> the latest row

    def ingest(self, agent, r):
        if not isinstance(r, dict):
            return
        if r.get("event") == "request":
            q = r.get("request") or {}
            args = q.get("args") if isinstance(q.get("args"), dict) else {}
            if q.get("action") == "vehicle" and args.get("remote") is True:
                self.pending[q.get("id")] = (agent, args)
                if len(self.pending) > 256:
                    self.pending.pop(next(iter(self.pending)))
            return
        if r.get("event") != "response":
            return
        resp = r.get("response") or {}
        req = self.pending.pop(resp.get("id"), None)
        res = resp.get("result") if isinstance(resp.get("result"), dict) else None
        if not req or not resp.get("ok") or not res:
            return
        args = req[1]
        row = None
        p = res.get("position")
        if res.get("spidertron") and isinstance(p, dict) and isinstance(p.get("x"), (int, float)):
            route = res.get("route") if isinstance(res.get("route"), list) else []
            goal = res.get("go_to") if isinstance(res.get("go_to"), dict) else (route[0] if route else None)
            row = {"vehicle": str(res["spidertron"]), "unit_number": res.get("unit_number"),
                   "position": {"x": round(float(p["x"]), 1), "y": round(float(p["y"]), 1)},
                   "speed": res.get("speed") if isinstance(res.get("speed"), (int, float)) else None,
                   "target": goal if isinstance(goal, dict) and isinstance(goal.get("x"), (int, float)) else None}
        elif isinstance(res.get("remote"), str) and args.get("drive") is not None:
            m = POS_RE.search(res["remote"])
            name = res["remote"].split(":", 1)[-1].strip().split(" ", 1)[0] if ":" in res["remote"] else "vehicle"
            drive = args.get("drive") if isinstance(args.get("drive"), dict) else None
            if m:
                row = {"vehicle": name, "unit_number": args.get("vehicle") if isinstance(args.get("vehicle"), int) else None,
                       "position": {"x": float(m.group(1)), "y": float(m.group(2))}, "speed": None,
                       "target": drive if drive and isinstance(drive.get("x"), (int, float)) else None}
        if row:
            t = _epoch(r.get("at"))
            if t is not None:
                self.rows[agent] = dict(row, t=t)

    def current(self, agent, now):
        row = self.rows.get(agent)
        return row if row and now - row["t"] <= VEHICLE_KEEP else None


def _epoch(at):
    from datetime import datetime
    try:
        return datetime.fromisoformat(str(at).replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def target_of(args):
    """-> (platform name or None, {x, y} or None): where a request's work lands."""
    plat = args.get("platform")
    pos = args.get("position")
    if isinstance(pos, dict) and isinstance(pos.get("x"), (int, float)):
        return plat, {"x": float(pos["x"]), "y": float(pos["y"])}
    area = args.get("area")
    if isinstance(area, dict):
        lt, rb = area.get("left_top") or {}, area.get("right_bottom") or {}
        try:
            return plat, {"x": (lt["x"] + rb["x"]) / 2, "y": (lt["y"] + rb["y"]) / 2}
        except (KeyError, TypeError):
            pass
    pts = [e.get("position") for e in args.get("entities") or [] if isinstance(e, dict)]
    pts = [p for p in pts if isinstance(p, dict) and isinstance(p.get("x"), (int, float))]
    if pts:
        return plat, {"x": round(sum(p["x"] for p in pts) / len(pts), 1), "y": round(sum(p["y"] for p in pts) / len(pts), 1)}
    return plat, None


class WorkFeed:
    def __init__(self, run_dir, agents):
        self.run_dir = run_dir
        self.agents = list(agents)
        self.offsets = {}  # agent -> byte offset already read (set to the file's end when first seen)
        self.partial = {}  # agent -> an unfinished last line
        self.waits = WaitFeed()
        self.repeats = RepeatFeed()  # the same request again and again: an agent's own sampling (workcard.py)
        self.vehicles = VehicleFeed()  # (batch222) each agent's vehicle by remote view: where it is (onecam)
        self.attention = []  # every request with an attention point (attention.py) since take_attention()
        self.flare_at = 0.0  # (batch224 AY) when the latest artillery flare request was read: serve.py polls artillery_live

    def take_attention(self):
        out, self.attention = self.attention, []
        return out

    def path(self, agent):
        return os.path.join(self.run_dir, agent, "journal.jsonl")

    def poll(self):
        """New remote-capable requests since the last poll -> [{agent, action, verb, platform, position, at}]."""
        out = []
        for agent in self.agents:
            p = self.path(agent)
            try:
                size = os.path.getsize(p)
            except OSError:
                continue
            bootstrap = agent not in self.offsets or size < self.offsets[agent]
            if bootstrap:  # recover current waits after restart, without replaying old work/attention
                self.waits.reset(agent)
                self.repeats.runs.pop(agent, None)
                self.offsets[agent], self.partial[agent] = max(0, size - MAX_READ), ""
            if size == self.offsets[agent]:
                continue
            with open(p, "rb") as f:
                f.seek(self.offsets[agent])
                data = f.read(MAX_READ)
            if bootstrap and self.offsets[agent]:
                data = data.split(b"\n", 1)[-1]  # discard the bounded tail's partial first row
                self.offsets[agent] = size
            else:
                self.offsets[agent] += len(data)
            text = self.partial.get(agent, "") + data.decode("utf-8", "replace")
            lines = text.split("\n")
            self.partial[agent] = lines.pop()  # "" when the chunk ended on a newline
            for line in lines:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                self.waits.ingest(agent, r)
                self.repeats.ingest(agent, r)
                self.vehicles.ingest(agent, r)  # (a restart's tail too: the director drops a stale read)
                if not isinstance(r, dict):
                    continue
                q = r.get("request") or {}
                if bootstrap or r.get("event") != "request":
                    continue
                args = q.get("args") if isinstance(q.get("args"), dict) else {}
                if q.get("action") == "use_item" and args.get("item") == "artillery-targeting-remote":
                    self.flare_at = time.time()
                att = attention.point(q.get("action"), args)
                if att:
                    self.attention.append(dict(att, agent=agent, at=r.get("at")))
                if q.get("action") not in REMOTE and q.get("action") not in ON_PLATFORM:
                    continue
                plat, pos = target_of(args)
                if q["action"] not in REMOTE and not isinstance(plat, str):
                    continue  # inspect, configure, launch ... on the body's own surface: its camera shows them
                out.append({"agent": agent, "action": q["action"], "verb": REMOTE.get(q["action"]) or
                            ON_PLATFORM[q["action"]], "platform": plat, "position": pos, "at": r.get("at")})
        return out
