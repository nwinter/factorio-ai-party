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
import json, os

import attention
from waitcard import WaitFeed
from workcard import RepeatFeed

# Actions whose target can be away from the body: the runtime runs these against a platform's surface when they
# carry platform=NAME (vendor/factorio-harness runtime.lua on_platform), else at the given positions on the body's
# surface (ghosts, paste and deconstruction need no walking).
REMOTE = {"place_ghosts": "building", "paste": "pasting a blueprint", "blueprint_place": "pasting a blueprint",
          "deconstruct": "deconstructing", "cancel_deconstruction": "cancelling deconstruction"}
# Platform actions that count only with platform=NAME (else they act where the body is): views and settings through
# remote view (runtime.lua on_platform), a rocket launched to the platform, cargo dropped from its hub, its schedule
# and hub requests (space.lua).
ON_PLATFORM = {"inspect": "inspecting", "configure": "configuring", "launch": "launching a rocket to",
               "drop": "dropping cargo from", "platform_schedule": "scheduling", "requests": "setting requests on"}
MAX_READ = 1 << 20  # per file per poll: a burst of observe replies cannot stall the tick


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
        self.attention = []  # every request with an attention point (attention.py) since take_attention()

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
                if not isinstance(r, dict):
                    continue
                q = r.get("request") or {}
                if bootstrap or r.get("event") != "request":
                    continue
                args = q.get("args") if isinstance(q.get("args"), dict) else {}
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
