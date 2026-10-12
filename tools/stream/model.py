"""Rolling stream state built from normalized observations (live or mock).

An observation is a dict:
  tick, paused, game_seconds
  agents: [{name, kind, display_name, color, glyph, motto, position{x,y}, alive, dead_until_tick,
            active (action kind or False), last {kind, outcome, tick}, combat, last_said {text, tick}}]
  chat: [{seq, tick, from, text}]                  (any window; deduplicated by seq)
  research: {current, progress, done [names], top_done [names]}
  produced: {item: total}                          (from tools/pog.py score)
  flows: {item: [per-2-minute counts, oldest first]} (optional, refreshed slowly)
  power: {machines, starved}                       (optional)
  events: [{kind: attack|loss|death|info, agent?, text, key?, ttl?, position?}] (optional)
  board_events: [{seq, tick, by, id, change, title, kind?}] (optional; docs/BOARD-API.md)
  board: {items: [...], open_unowned} (optional, refreshed slowly; docs/BOARD-API.md)
"""
import math, os, re, time
from collections import deque

HALF_LIFE = 75.0  # seconds; interest decays toward 0 with this half-life
ACTION_WEIGHT = {
    "build": 3.0, "place": 3.0, "construct": 3.5, "blueprint": 4.0, "build_blueprint": 4.0, "rotate": 1.0,
    "mine": 1.2, "craft": 1.0, "insert": 1.2, "take": 1.0, "feed": 1.2, "walk": 0.6, "path": 0.6,
    "attack": 6.0, "shoot": 6.0, "kite": 6.0, "research": 2.0, "wait_until": 0.2, "wait": 0.2,
}
SCIENCE = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
           "production-science-pack", "utility-science-pack", "space-science-pack",
           # Space Age: one pack per planet, then promethium from the edge of the system
           "metallurgic-science-pack", "electromagnetic-science-pack", "agricultural-science-pack",
           "cryogenic-science-pack", "promethium-science-pack"]
SPACE_PACKS = SCIENCE[6:]
PLANET_LABELS = {"nauvis": "Nauvis", "vulcanus": "Vulcanus", "fulgora": "Fulgora", "gleba": "Gleba", "aquilo": "Aquilo",
                 "solar-system-edge": "Solar system edge", "shattered-planet": "Shattered Planet"}
# Items the production widget can show, by game stage (0 raw .. 5 rocket). The widget leads with science per minute
# and fills the rest with what is being made now, favouring the stage the factory has reached.
STAGE_ITEMS = [
    (0, ["iron-plate", "copper-plate", "stone-brick", "iron-ore", "copper-ore", "coal", "stone"]),
    (1, ["iron-gear-wheel", "copper-cable", "electronic-circuit", "transport-belt", "inserter"]),
    (2, ["steel-plate", "firearm-magazine", "piercing-rounds-magazine", "stone-wall", "engine-unit"]),
    (3, ["plastic-bar", "sulfur", "advanced-circuit", "battery", "solid-fuel"]),
    (4, ["processing-unit", "electric-engine-unit", "flying-robot-frame", "low-density-structure", "rocket-fuel"]),
    (5, ["rocket-part", "satellite"]),
]
ITEM_STAGE = {n: s for s, names in STAGE_ITEMS for n in names}
# Stage 3 was "Oil": shake5's hosts read it as "the oil is dry" an hour after blue science started
STAGE_LABELS = ["Raw resources", "Automation", "Steel & logistics", "Oil & blue science", "Advanced", "Rocket"]
SCIENCE_STAGE = {"automation-science-pack": 1, "logistic-science-pack": 2, "military-science-pack": 2,
                 "chemical-science-pack": 3, "production-science-pack": 4, "utility-science-pack": 4,
                 "space-science-pack": 5, **{n: 5 for n in SCIENCE[7:]}}
SPARK_ITEMS = [n for _, names in STAGE_ITEMS for n in names] + SCIENCE
VERBS = {"build": "building", "place": "placing", "construct": "constructing", "build_blueprint": "placing blueprint",
         "blueprint": "placing blueprint", "mine": "mining", "craft": "crafting", "insert": "loading", "take": "taking",
         "feed": "feeding", "walk": "walking", "path": "walking", "move_to": "walking", "gather": "gathering",
         "build_path": "building", "repair": "repairing", "deconstruct": "removing", "follow": "following", "shoot": "fighting", "attack": "fighting", "kite": "fighting",
         "rotate": "rotating", "wait_until": "waiting", "wait": "waiting", "research": "researching"}
THINK_WINDOW = 90  # seconds after an action ends during which an inactive agent counts as "thinking"
CHANGELOG_RE = re.compile(r"^\s*(?:server:\s*)?harness (v[\w.]+):\s*(.+)$", re.I)  # operator chat "server: harness vN: ..."
BOARD_STATUS = {"posted": "open", "taken": "claimed", "assigned": "claimed", "started": "doing", "done": "done",
                "blocked": "blocked", "dropped": "dropped", "reopened": "open", "released": "open"}


def board_verb(change):
    """A board event's `change` -> posted | taken | started | done | blocked | dropped | reopened | note | updated.
    The contract leaves `change` loose, so accept "posted", "status:done", "owner:astra", {"status": "done"}, ..."""
    if isinstance(change, dict):
        change = ("status:" + str(change["status"]) if change.get("status") else "owner" if change.get("owner")
                  else "note" if change.get("note") else "")
    c = str(change or "").lower()
    for verb, words in (("posted", ("post", "creat", "new")), ("done", ("done", "complet", "finish")),
                        ("blocked", ("block",)), ("dropped", ("drop", "cancel")), ("started", ("doing", "start")),
                        ("assigned", ("assign",)), ("released", ("release",)),
                        ("taken", ("take", "took", "claim", "owner")), ("reopened", ("open",)), ("note", ("note",))):
        if any(w in c for w in words):
            return verb
    return "updated"


def clean_text(s):
    return re.sub(r"\[/?[a-z-]+(=[^\]]*)?\]", "", s or "")


try:  # eng/audio's local classifier, so the overlay and the casters agree on what is conversation
    from caster import heuristic_kind
except Exception:  # caster.py missing or failing to import: everything from agents counts as talk
    heuristic_kind = None


def chat_lane(entry):
    """'talk' (banter, strategy, emotion, `aloud`, confessionals: the big chat lane), 'notice' (harness notices: votes
    and their results, humans joining and leaving; shown in the chat feed), 'log' (coordinates, counts,
    acknowledgements, server lines: not shown), or 'viewer' (a viewer line relayed into the game chat: the feed shows it
    once, from the viewers list)."""
    frm = (entry.get("from") or "").lower()
    if entry.get("notice"):  # a harness notice ("vote: ...", "players: ..."; votes.lua, players.lua)
        return "notice"
    if entry.get("viewer") or frm.startswith("viewer") or clean_text(entry.get("text")).lower().startswith("viewer "):
        return "viewer"
    if entry.get("confess") or entry.get("aloud"):
        return "talk"
    if not entry.get("agent"):
        return "log"
    if heuristic_kind is None:
        return "talk"
    return "talk" if heuristic_kind(clean_text(entry.get("text")))[0] == "voice" else "log"


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def planet_label(name):
    return PLANET_LABELS.get(name) or (name or "?").replace("-", " ").capitalize()


def where_label(surface, platform=None):
    """An agent's surface for viewers: the platform's name on a platform, else the planet."""
    return platform or planet_label(surface)


def pack_label(item):
    return item.replace("-science-pack", "").replace("-", " ").capitalize() + " science"


def fmt_count(n):
    return f"{n / 1000:.1f}k".replace(".0k", "k") if n >= 1000 else str(int(n))


AT_RE = re.compile(r"^([\w-]+)->([\w-]+) (\d+)%$")


def platform_where(p):
    """A platform row (score + `platforms` detail) for the page: where it is or its route with progress, speed.
    `at` is a location name or "from->to N%" (space.lua); speed is LuaSpacePlatform.speed, shown x60 as km/s."""
    at = p.get("at") or ""
    m = AT_RE.match(at)
    route = {"from": planet_label(m[1]), "to": planet_label(m[2]), "pct": int(m[3])} if m else None
    where = f"{route['from']} → {route['to']}" if route else planet_label(at) if at and at != "in transit" else "in transit"
    speed = p.get("speed")
    return {"name": p.get("name"), "where": where, "route": route, "state": p.get("state"), "paused": bool(p.get("paused")),
            "speed_kms": round(speed * 60) if isinstance(speed, (int, float)) and speed else None, "view": p.get("view")}


def platform_shot(view, margin=10.0):
    """A camera shot of a whole platform from its view (live.py PLATFORM_LUA): the centre of its entities' bounds on
    its surface, at the zoom that fits them. A director client at zoom 1 shows ~60x34 tiles (1920x1080 at 32 px per
    tile), so the zoom is what fits the bounds plus a margin, clamped to cameras.lua's 0.3..4. exact_zoom: the
    director sends it as is (no main/side scaling, which would crop the platform)."""
    b = view.get("bounds") or {}
    hub = view.get("hub") or {"x": 0, "y": 0}
    left, top = b.get("left", hub["x"] - 6), b.get("top", hub["y"] - 6)
    right, bottom = b.get("right", hub["x"] + 6), b.get("bottom", hub["y"] + 6)
    w, h = right - left + margin, bottom - top + margin
    zoom = max(0.3, min(2.0, 60.0 / w, 34.0 / h))
    return {"position": {"x": round((left + right) / 2, 1), "y": round((top + bottom) / 2, 1)}, "surface": view["surface"],
            "zoom": round(zoom, 2), "exact_zoom": True}


def fmt_game_time(sec):
    sec = int(sec)
    return f"{sec // 3600}h{sec // 60 % 60:02d}m"


# Technologies and the buildings they unlock, for the hosts' commentary on what the team has not built yet
# (HOSTS4 item 2: "logistic robotics researched 3 h ago, no roboport built"). Buildings are counted by tools/pog.py's
# score; a technology whose building is not counted there is left out. One table with the harness: its unlocks.lua
# (the agents' shift block, "researched, none built") is read here.
UNLOCKS_LUA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "vendor", "factorio-harness", "mod",
                           "agent-harness_0.1.0", "unlocks.lua")


def load_unlocks(path=UNLOCKS_LUA):
    """unlocks.lua rows `{'tech', {'building', ...}, 'label'},` -> {tech: ((buildings), label)}, in file order."""
    out = {}
    row = re.compile(r"^\s*\{\s*'([^']+)'\s*,\s*\{([^}]*)\}\s*,\s*'([^']+)'\s*\},?\s*$")
    for line in open(path):
        m = row.match(line)
        if m:
            out[m.group(1)] = (tuple(re.findall(r"'([^']+)'", m.group(2))), m.group(3))
    return out


UNLOCKS = load_unlocks()


def tech_label(name):
    if not name:
        return None
    label = name.replace("-", " ").capitalize()
    # shake11's template aired "Planet discovery fulgora": planets keep their capitals
    return re.sub(r"\b(nauvis|vulcanus|fulgora|gleba|aquilo)\b", lambda m: m.group(1).capitalize(), label)


def human_name(name):
    """A prototype name for viewers: 'assembling-machine-2' -> 'Assembling machine 2', 'travel to vulcanus' ->
    'Travel to vulcanus'."""
    return tech_label(str(name)) or ""


def describe_action(kind):
    """'craft:lab' -> 'crafting lab', 'build_blueprint' -> 'placing blueprint'."""
    kind, _, what = str(kind).partition(":")
    verb = VERBS.get(kind, kind.replace("_", " "))
    return f"{verb} {what.replace('-', ' ')}".strip()


class Agent:
    def __init__(self, name, cfg):
        self.name = name
        self.cfg = cfg or {}
        self.kind = self.cfg.get("kind", "bot")
        self.display_name = self.cfg.get("display_name") or name.capitalize()
        self.color = self.cfg.get("color")
        self.glyph = self.cfg.get("glyph")
        self.motto = ""
        self.profile_set = None  # None: unknown (no `profiles`); False: the agent has not called `profile` yet
        self.position = None
        self.where = None  # profiles' text while in a cargo pod ("cargo pod to X")
        self.travel = None  # a bot's ride: ascending | aboard | descending
        self.alive = True
        self.dead_until_tick = None
        self.active = False
        self.action_since = None
        self.last = None
        self.last_activity_t = None  # wall time of the last observed action or speech
        self.combat = False
        self.plan = None  # the action running now with its bounds (live.py `plan`; onecam.py looks ahead with it)
        self.last_said = None
        self.interest = 0.0
        self.interest_t = time.time()
        self.seen = False
        self.died_at = None
        self.connected = True
        self.voice = None  # profile.voice: a voice id from tools/stream/voices.py
        self.voice_description = None  # profile.voice_description: words for a designed voice (voices.py)
        self.pronouns = None  # profile.pronouns, e.g. "he/him": the casters use them (else "they")
        self.avatar = None  # profile.avatar: parts for avatar.js (docs/ART-NOTES.md); None draws the name default
        self.surface = None   # Space Age (status): the surface the body is on, and the platform's name when on one
        self.platform = None

    def bump(self, amount, now):
        self.decay(now)
        self.interest = min(self.interest + amount, 30.0)

    def decay(self, now):
        dt = max(0.0, now - self.interest_t)
        self.interest *= 0.5 ** (dt / HALF_LIFE)
        self.interest_t = now


class Model:
    def __init__(self, run):
        self.run = run
        self.agents = {}
        for name, cfg in (run.get("agents") or {}).items():
            self.agents[name] = Agent(name, cfg)
        self.chat = deque(maxlen=200)  # chat_window() picks each lane's latest from here
        self.chat_seen = set()
        self.operator_requests = deque(maxlen=5)  # the last few agents' requests to the operator, for the snapshot
        self.alerts = deque(maxlen=30)
        self.alert_keys = {}
        self.tick = 0
        self.paused = False
        self.research = {"current": None, "progress": None, "done": set(), "recent": deque(maxlen=6)}
        self.done_at = {}    # technology -> when this stream saw it finish (unused_unlocks)
        self.research_news = {}  # technology -> {name, label, t}: finished while this stream ran (the research card)
        self.unlocks = {}        # technology -> {unlocks, more} from research.lua's board event
        self.entities = {}   # building counts from the score (unused_unlocks)
        self.entities_counted = set()  # the buildings the score counts (absent from entities means none)
        self.research_started = False
        self.prod_samples = deque(maxlen=400)  # (wall time, game seconds, {item: total})
        self.flows = {}
        self.power = None
        self.darkness = None  # LuaSurface.darkness: 0 day .. ~0.85 midnight (nightlift.py)
        self.basemap = None  # the base as a coarse grid (harness.BASEMAP_LUA), for the site's live map only
        self.board = {"events": deque(maxlen=40), "seen": set(), "items": {}, "open_unowned": None,
                      "changelog": deque(maxlen=5), "available": False}
        # Space Age: score's rockets/planets/platforms plus platform detail (live.py); moments fire once each
        self.space = {"rockets": 0, "planets": [], "platforms": []}
        self.space_seen = None  # moment keys already true; None until the first observation seeds it silently
        self.moments = deque(maxlen=8)
        self.work = deque(maxlen=20)  # work away from the body (live.py observe_work), for the director
        self.fights = {}  # key -> fight still reported (attacked chunk, loss, agent in combat), for replays.py
        self.space_age = bool(run.get("space_age")) or "Space Age" in (run.get("subtitle") or "")
        self.last_obs_t = None
        self.errors = {}

    # ---- ingestion -------------------------------------------------------------------------------------------
    def agent(self, name):
        if name not in self.agents:
            self.agents[name] = Agent(name, (self.run.get("agents") or {}).get(name))
        return self.agents[name]

    def ingest(self, obs, now=None):
        now = now or time.time()
        self.last_obs_t = now
        self.tick = obs.get("tick", self.tick)
        self.paused = bool(obs.get("paused"))
        game_sec = obs.get("game_seconds", self.tick / 60)
        team = self.run.get("agents") or {}
        for a in obs.get("agents", []):
            # cards are the run's team only (stream.json agents, from team.txt); shake8 showed Nick, a human player,
            # as a tenth card ("model ? · profile not set · dead"). Without a team in the run, everyone counts.
            if team and a.get("name") not in team:
                continue
            self._ingest_agent(a, now)
        for m in obs.get("chat", []):
            self._ingest_chat(m, now)
        for c in obs.get("confessions") or []:
            self._ingest_confession(c, now)
        for t in obs.get("tells") or []:
            self._ingest_tell(t, now)
        for r in obs.get("operator_requests") or []:
            self._ingest_operator_request(r, now)
        if obs.get("research"):
            self._ingest_research(obs["research"], now)
        if obs.get("produced") is not None:
            self.prod_samples.append((now, game_sec, dict(obs["produced"])))
        if obs.get("entities") is not None:  # the score's building counts (tools/pog.py), for unused_unlocks
            self.entities = dict(obs["entities"])
            # zeros are left out of the counts, so only a building the score says it counts can be "none built"
            self.entities_counted = set(obs.get("entities_counted") or [])
        if obs.get("flows"):
            self.flows = obs["flows"]
        if obs.get("darkness") is not None:
            self.darkness = obs["darkness"]
        if obs.get("basemap"):
            ore = obs["basemap"].get("ore") or (self.basemap or {}).get("ore")  # ore is read less often: keep the last
            self.basemap = dict(obs["basemap"], ore=ore) if ore else obs["basemap"]
        if obs.get("power"):
            self._ingest_power(obs["power"], now)
        for e in obs.get("board_events") or []:
            self._ingest_board_event(e, now)
        if obs.get("board") is not None:  # after the events: a `board` read is the authoritative item state
            self._ingest_board(obs["board"])
        for e in obs.get("events", []):
            self._ingest_event(e, now)
        if obs.get("space") is not None:
            # a platform counts once its hub exists: shake7's "First space platform: Solstice" fired on the record the
            # New platform button makes (waiting_for_starter_pack), before any rocket. Rows without the field (older
            # score reads) count as before.
            sp = dict(obs["space"])
            sp["platforms"] = [p for p in sp.get("platforms") or []
                               if p.get("hub", True) and p.get("state") != "waiting_for_starter_pack"]
            self.space = sp
        if obs.get("space") is not None or any(a.get("surface") for a in obs.get("agents", [])):
            self._space_moments(now)
        for w in obs.get("work") or []:
            self._ingest_work(w, now)
        self.errors = obs.get("errors", {})

    def platform_view(self, name):
        """A platform's camera view (live.py PLATFORM_LUA: surface, hub, bounds), or None before it is read."""
        return next((p.get("view") for p in self.space.get("platforms") or [] if p.get("name") == name and p.get("view")), None)

    def _ingest_work(self, w, now):
        """Work away from an agent's body (live.py observe_work) -> a labelled item the director can cut to."""
        if w.get("agent") not in self.agents:
            return
        ag = self.agents[w["agent"]]
        who = ag.display_name or w["agent"]
        item = {"id": f"work-{w['agent']}-{w.get('at') or now}", "agent": w["agent"], "action": w.get("action"),
                "t": now, "platform": w.get("platform"), "position": w.get("position"), "surface": w.get("surface")}
        if w.get("platform"):
            view = self.platform_view(w["platform"])
            if not view:
                return  # its surface is not known yet (the platform read runs every 15 s): nothing to cut to
            item.update(surface=view["surface"], view=view,
                        label=f"{who} {w.get('verb') or 'building'} on {w['platform']} (from the ground)")
        else:
            if not w.get("position"):
                return
            p = w["position"]
            item["label"] = f"{who} {w.get('verb') or 'building'} at ({round(p['x'])}, {round(p['y'])}) (from afar)"
        if any(x["agent"] == item["agent"] and x.get("platform") == item["platform"] and now - x["t"] < 20
               for x in self.work):
            return  # one request after another on the same job: one item
        self.work.append(item)
        ag.bump(1.0, now)

    def _fight(self, key, kind, position, now, text, agent=None, loss=False):
        """A fight still being reported (live.py re-reports an attacked chunk every poll while its last hit is under 30
        game seconds old, a loss for ~2 minutes, an agent's combat flag while it lasts): `last` is when it was last
        seen, so replays.py can wait until it has been quiet before airing anything about it."""
        f = self.fights.get(key)
        if not f:
            f = self.fights[key] = {"key": key, "kind": kind, "first": now, "losses": [], "text": text, "agent": agent}
        f.update(last=now, position={k: position[k] for k in ("x", "y", "surface", "extent") if k in position})
        if loss:
            f["losses"].append(now)  # when a loss alert first came in: the moment something was destroyed (+ poll lag)
            f["text"] = text
        for k in [k for k, v in self.fights.items() if now - v["last"] > 300]:
            del self.fights[k]

    def fights_snapshot(self, now):
        return [dict(f, losses=list(f["losses"])) for f in self.fights.values() if now - f["last"] < 240]

    def work_snapshot(self, now):
        return [dict(w, age_s=round(now - w["t"], 1)) for w in self.work if now - w["t"] < 60]

    def _ingest_agent(self, a, now):
        ag = self.agent(a["name"])
        for key in ("kind", "display_name", "color", "glyph", "motto", "voice", "voice_description", "pronouns"):
            if a.get(key):
                setattr(ag, key, a[key])
        if "avatar" in a:
            ag.avatar = a["avatar"] if isinstance(a["avatar"], dict) else None
        if "profile_set" in a:
            ag.profile_set = a["profile_set"]
        if a.get("position"):
            ag.position = a["position"]
        if a.get("surface"):
            ag.surface, ag.platform = a["surface"], a.get("platform")
        # Bot travel (harness): ascending | aboard | descending, and the pod's text ("cargo pod to X"); None once landed.
        for key in ("travel", "where"):
            if key in a:
                setattr(ag, key, a[key])
        # A bot riding a cargo pod or aboard a platform has no body; it is not dead.
        alive = a.get("alive", True) or bool(a.get("travel"))
        connected = a.get("connected", True)
        if ag.seen and ag.alive and not alive and connected and ag.connected:
            ag.died_at = now
            ag.bump(5, now)
            self.alert("death", f"{ag.display_name} died", key=f"death:{ag.name}:{int(now // 30)}", agent=ag.name)
        ag.alive = alive
        ag.connected = connected
        ag.dead_until_tick = a.get("dead_until_tick")
        active = a.get("active") or False
        if active and active != ag.active:
            ag.action_since = now
            ag.bump(ACTION_WEIGHT.get(str(active).split(":")[0], 1.0), now)
        if active:
            ag.last_activity_t = now
            # sustained work keeps a little interest alive
            ag.bump(0.04 * ACTION_WEIGHT.get(str(active).split(":")[0], 1.0), now)
        elif ag.active and not active:
            ag.last_activity_t = now
        ag.active = active
        if a.get("last"):
            ag.last = a["last"]
        combat = bool(a.get("combat"))
        if combat and ag.position:  # an agent's own fight, seen on every poll while it lasts (replays.py)
            self._fight(f"attack:{ag.name}", "attack", ag.position, now, f"{ag.display_name} is under attack", agent=ag.name)
        if combat and not ag.combat:
            ag.bump(6, now)
            self.alert("attack", f"{ag.display_name} is under attack", key=f"attack:{ag.name}", agent=ag.name, ttl=60,
                       position=ag.position)
        ag.combat = combat
        if "plan" in a:
            ag.plan = a["plan"] if active else None
        said = a.get("last_said")
        if said and said.get("text") and (not ag.last_said or said.get("tick") != ag.last_said.get("tick")):
            if ag.seen:
                ag.bump(2, now)
                ag.last_activity_t = now
            ag.last_said = dict(said, t=now)
        ag.seen = True

    def _ingest_chat(self, m, now):
        key = m.get("seq") or (m.get("tick"), m.get("from"), m.get("text"))
        if key in self.chat_seen:
            return
        self.chat_seen.add(key)
        sender = self._match_sender(m.get("from", ""))
        entry = {"seq": m.get("seq"), "tick": m.get("tick"), "from": m.get("from"), "agent": sender,
                 "text": m.get("text", ""), "t": m.get("t", now)}
        if m.get("aloud"):  # the agent asked for this line to be voiced on stream (tools/stream/caster.py)
            entry["aloud"] = True
        if m.get("viewer"):  # a viewer's line the operator relayed into the game chat (audience.lua)
            entry["viewer"] = m["viewer"]
        if m.get("notice"):  # a harness notice: the agents' mute votes and their results (audience.lua)
            entry["notice"] = True
        entry["lane"] = chat_lane(entry)
        self.chat.append(entry)
        cl = None if sender else CHANGELOG_RE.match(clean_text(entry["text"]))
        if cl:
            self._changelog(cl.group(2).strip(), m.get("tick"), entry["t"], version=cl.group(1))
        if sender and m.get("t", now) > now - 30:
            ag = self.agents[sender]
            ag.bump(2, now)
            ag.last_activity_t = now

    def chat_window(self, talk=12, other=8, tells=24):
        """The last `talk` conversation lines, the last `tells` tells (enough for the page to fold a burst) and the
        last `other` log / viewer lines, in arrival order: one kind must not push another off the page."""
        msgs = list(self.chat)
        keep = {id(m) for m in [m for m in msgs if m.get("lane") == "talk"][-talk:]}
        keep |= {id(m) for m in [m for m in msgs if m.get("lane") == "tell"][-tells:]}
        keep |= {id(m) for m in [m for m in msgs if m.get("lane") not in ("talk", "tell")][-other:]}
        return [m for m in msgs if id(m) in keep]

    def _ingest_confession(self, c, now):
        """audience.lua `confessions` (operator read): {seq, tick, from, text}, an agent talking to the viewers only."""
        key = ("confess", c.get("seq"))
        if key in self.chat_seen:
            return
        self.chat_seen.add(key)
        sender = self._match_sender(c.get("from", ""))
        entry = {"seq": f"c{c.get('seq')}", "tick": c.get("tick"), "from": c.get("from"), "agent": sender,
                 "text": c.get("text", ""), "t": c.get("t", now), "confess": True, "lane": "talk"}
        self.chat.append(entry)
        if sender:
            self.agents[sender].bump(2.5, now)

    def _ingest_tell(self, t, now):
        """tells.lua `tells` (operator read): {seq, tick, from, to (names or "team"), text}, what an agent sent to
        teammates outside the game chat: the team's main channel (shake7: ~540 tells to ~100 chat lines). Lane "tell":
        the page shows them in the chat feed as direct lines ("Sol → Astra", `to_shown` and `body`); `text` stays
        "-> Astra: ..." for the site's live feed and the logs. Never voiced."""
        key = ("tell", t.get("seq"))
        if key in self.chat_seen:
            return
        self.chat_seen.add(key)
        sender = self._match_sender(t.get("from", ""))
        to = t.get("to")
        names = ["team"] if to == "team" else [n for n in (to or []) if isinstance(n, str)]
        shown = ", ".join("team" if n == "team" else (self.agents[m].display_name or n) if (m := self._match_sender(n))
                          else n for n in names)
        entry = {"seq": f"t{t.get('seq')}", "tick": t.get("tick"), "from": t.get("from"), "agent": sender,
                 "text": f"\u2192 {shown}: {t.get('text', '')}", "t": t.get("t", now), "tell": True, "lane": "tell",
                 "to_shown": shown, "to": names, "body": t.get("text", "")}
        self.chat.append(entry)
        if sender:
            self.agents[sender].bump(1, now)

    def _ingest_operator_request(self, r, now):
        """An agent's request to the operator (tells.lua `operator`; live.py's rows {t, seq, agent, text}): shown on
        the ticker like a tell ("Astra → operator: ..."), kept among the snapshot's last few. Never voiced."""
        key = ("operator", r.get("seq"))
        if key in self.chat_seen:
            return
        self.chat_seen.add(key)
        sender = self._match_sender(r.get("agent", ""))
        text = r.get("text", "")
        entry = {"seq": f"o{r.get('seq')}", "tick": r.get("tick"), "from": r.get("agent"), "agent": sender,
                 "text": f"→ operator: {text}", "t": r.get("t", now), "tell": True, "operator": True, "lane": "tell",
                 "to_shown": "operator", "to": ["operator"], "body": text}
        self.chat.append(entry)
        self.operator_requests.append({"seq": r.get("seq"), "t": entry["t"], "agent": sender or r.get("agent"),
                                       "display_name": self.agents[sender].display_name if sender else None, "text": text})
        if sender:
            self.agents[sender].bump(1, now)

    def _match_sender(self, frm):
        frm = (frm or "").lower()
        for name, ag in self.agents.items():
            aliases = {name, (ag.display_name or "").lower(), f"pog-{name}"}
            aliases |= {s.lower() for s in ag.cfg.get("aliases", [])}
            if frm in aliases:
                return name
        return None

    def _ingest_research(self, r, now):
        done = set(r.get("done") or [])
        res = self.research
        if not self.research_started:
            # seed "recent" with the most advanced technologies already finished (no timestamps known)
            for name in reversed(r.get("top_done") or []):
                res["recent"].appendleft({"name": name, "label": tech_label(name), "t": None})
            self.research_started = True
        else:
            for name in sorted(done - res["done"]):
                self.done_at[name] = now
                res["recent"].appendleft({"name": name, "label": tech_label(name), "t": now})
                self.alert("research", f"Research complete: {tech_label(name)}", key=f"research:{name}", ttl=40)
                self.research_news[name] = {"name": name, "label": tech_label(name), "t": now}
                # credit whoever has been busiest lately (labs are fed by the team; this keeps cameras lively)
                live = [a for a in self.agents.values() if a.alive and a.last_activity_t]
                for a in sorted(live, key=lambda a: -a.last_activity_t)[:2]:
                    a.bump(2.5, now)
        res["done"] = done
        res["current"] = r.get("current")
        res["progress"] = r.get("progress")

    def unused_unlocks(self, now=None):
        """Researched technologies whose building the team has none of, oldest first: [{tech, unlocks, built,
        researched}], researched being "N minutes ago" or "before this stream" (already done when the stream
        started). For the hosts' commentary to viewers only; nothing here goes to the agents."""
        if not self.entities_counted:
            return []
        now = now or time.time()
        out = []
        for tech, (names, label) in UNLOCKS.items():
            if tech not in self.research["done"] or any(self.entities.get(n) for n in names) or \
                    not all(n in self.entities_counted for n in names):
                continue
            t = self.done_at.get(tech)
            out.append((t or 0, {"tech": tech_label(tech), "unlocks": label, "built": 0,
                                 "researched": f"{round((now - t) / 60)} minutes ago" if t else "before this stream"}))
        out.sort(key=lambda x: x[0])
        return [x for _, x in out][:4]

    def _ingest_board(self, b):
        """`board` read: current items (newest first) and the open unowned request count."""
        board = self.board
        board["available"] = True
        items = (b.get("items") or []) if isinstance(b, dict) else (b or [])
        if isinstance(b, dict) and b.get("open_unowned") is not None:
            board["open_unowned"] = b["open_unowned"]
        if isinstance(b, dict) and "plan" in b:  # the team plan (board_plan): goals and who is on what
            board["plan"] = b["plan"] or None
        for it in items:
            if it.get("id") is not None:
                board["items"][it["id"]] = it
        if len(board["items"]) > 400:
            for key in sorted(board["items"], key=lambda k: board["items"][k].get("updated_tick") or 0)[:-300]:
                del board["items"][key]

    def _who(self, name):
        if not name:
            return None
        return name if name in self.agents else self._match_sender(name)

    def _ingest_board_event(self, e, now):
        board = self.board
        board["available"] = True
        key = e.get("seq") if e.get("seq") is not None else (e.get("tick"), e.get("id"), str(e.get("change")))
        if key in board["seen"]:
            return
        board["seen"].add(key)
        verb = board_verb(e.get("change"))
        it = board["items"].get(e.get("id")) or {}
        kind = e.get("kind") or it.get("kind")
        # keep the item cache moving between (slower) `board` reads, so claims and the request count stay current
        if e.get("id") is not None:
            it = board["items"].setdefault(e["id"], {"id": e["id"]})
            it["title"] = e.get("title") or it.get("title")
            it["kind"] = kind
            if "status" in e:  # eng/board events carry the item's status, owner and requester after the change
                for k in ("status", "owner", "requested_by"):
                    it[k] = e.get(k)
            else:
                status = "claimed" if verb == "posted" and kind == "claim" else BOARD_STATUS.get(verb)
                if status:
                    it["status"] = status
                if verb == "posted":
                    it.setdefault("requested_by", e.get("by"))
                    if kind == "claim":
                        it["owner"] = e.get("by")
                elif verb == "taken":
                    it["owner"] = e.get("by")
                elif verb in ("reopened", "released"):
                    it["owner"] = None
            it["updated_tick"] = e.get("tick")
            if board["open_unowned"] is not None and kind == "request":
                board["open_unowned"] = None  # recount from items until the next `board` read
        if verb in ("note", "updated") or (kind == "harness" and verb not in ("posted", "done")):
            return  # notes and operator bookkeeping are noise on stream
        if kind == "plan":
            return  # plan edits show as the plan line itself (board_snapshot)
        agent = self._who(e.get("by"))
        recent = e.get("t", now) > now - 30
        title = e.get("title") or it.get("title") or ""
        if kind == "research":  # a finished technology (research.lua): no item, by "research"
            self._tech_unlocks(title, e.get("text"), now)
            title = tech_label(title)
        entry = {"seq": e.get("seq"), "tick": e.get("tick"), "by": e.get("by"), "agent": agent, "id": e.get("id"),
                 "verb": verb, "title": clean_text(title), "kind": kind,
                 "owner": it.get("owner"), "owner_agent": self._who(it.get("owner")), "t": e.get("t", now)}
        board["events"].append(entry)
        if agent and recent:
            self.agents[agent].bump({"done": 1.5, "posted": 1.0, "taken": 1.0}.get(verb, 0.5), now)
            self.agents[agent].last_activity_t = now
        if kind == "harness" and verb == "done":
            self._changelog(entry["title"], e.get("tick"), entry["t"])

    UNLOCKS_RE = re.compile(r"^unlocks: (.*?)(?:, \+(\d+) more)?$")

    def _tech_unlocks(self, name, text, now):
        """research.lua's board event for a finished technology carries "unlocks: a, b, +N more" (recipe names,
        "travel to vulcanus", "rare quality"). Kept per technology: the event can come before or after the score
        shows the technology done, and a replayed old event must not make a card (research_news comes from the
        score)."""
        m = self.UNLOCKS_RE.match(str(text or ""))
        if not name or not m:
            return
        names = [n.strip() for n in m.group(1).split(",") if n.strip()]
        self.unlocks[name] = {"unlocks": [human_name(n) for n in names], "more": int(m.group(2) or 0)}

    def research_news_snapshot(self, now):
        """Technologies finished in the last 30 s (seen in the score), with what they unlock when the board said:
        the stream's "Research complete" card (overlay.js renderResearchCard)."""
        for k in [k for k, v in self.research_news.items() if now - v["t"] > 120]:
            del self.research_news[k]
        out = []
        for name, n in sorted(self.research_news.items(), key=lambda kv: kv[1]["t"]):
            if now - n["t"] <= 30:
                u = self.unlocks.get(name) or {}
                out.append(dict(n, unlocks=u.get("unlocks") or [], more=u.get("more") or 0, age_s=round(now - n["t"], 1)))
        return out

    def _changelog(self, text, tick, t, version=None):
        """A harness request marked done (title, no version) and the operator's chat line "harness vN: what"
        usually arrive together: merge them into one changelog line."""
        cl = self.board["changelog"]
        if any(c["text"] == text and c["version"] == version for c in cl):
            return
        if cl and abs((t or 0) - (cl[-1]["t"] or 0)) < 180 and bool(version) != bool(cl[-1]["version"]):
            last = cl[-1]
            if version:
                last.update(version=version, text=text, request=last["text"])
            else:
                last["request"] = text
            return
        cl.append({"text": text, "version": version, "request": None if version else text, "tick": tick, "t": t})

    def board_snapshot(self):
        b = self.board
        items = list(b["items"].values())
        claims = [it for it in items if it.get("kind") == "claim" and it.get("status") in ("open", "claimed", "doing")]
        claims.sort(key=lambda it: -(it.get("updated_tick") or 0))
        unowned = b["open_unowned"]
        if unowned is None:
            unowned = sum(1 for it in items if it.get("kind") == "request" and it.get("status") == "open"
                          and not it.get("owner"))
        doing = sum(1 for it in items if it.get("kind") in ("task", "request") and it.get("status") in ("claimed", "doing"))
        return {
            "available": b["available"],
            "events": list(b["events"])[-8:],
            "open_unowned": unowned,
            "in_progress": doing,
            "claims": [{"id": it.get("id"), "title": clean_text(it.get("title") or ""), "owner": it.get("owner"),
                        "agent": self._who(it.get("owner"))} for it in claims[:6]],
            "claims_total": len(claims),
            "changelog": list(b["changelog"])[-2:],
            "plan": self.plan_snapshot(),
        }

    def plan_snapshot(self):
        """The team plan for the board widget: goals, each agent's line (agent name matched to its card), last edit."""
        p = self.board.get("plan")
        if not isinstance(p, dict) or not (p.get("goals") or p.get("doing")):
            return None
        doing = []
        for line in p.get("doing") or []:
            name, _, text = str(line).partition(": ")
            doing.append({"agent": self._who(name), "name": name, "text": clean_text(re.sub(r" \(set by [^)]*\)$", "", text))})
        return {"goals": clean_text(p.get("goals") or ""), "doing": doing, "edited": p.get("edited")}

    def _ingest_power(self, p, now):
        self.power = p
        machines, starved = p.get("machines") or 0, p.get("starved") or 0
        if machines >= 10 and starved / machines > 0.25 and not self.paused:
            self.alert("power", f"Low power: {starved} of {machines} machines starved", key="power", ttl=90)

    def _ingest_event(self, e, now):
        ag = self.agents.get(e.get("agent")) if e.get("agent") else None
        if e["kind"] == "attack" and ag:
            ag.bump(6, now)
        p = e.get("position")
        fresh = e.get("key") not in self.alert_keys or now - self.alert_keys[e["key"]] >= e.get("ttl", 60)
        if p and e["kind"] in ("attack", "loss"):
            self._fight(e.get("key") or f"{e['kind']}:{p['x']},{p['y']}", e["kind"], p, now, e["text"],
                        loss=e["kind"] == "loss" and fresh)
        if p and fresh:  # a fight somewhere: pull cameras toward agents near it
            for other in self.agents.values():
                if other.position and math.hypot(other.position["x"] - p["x"], other.position["y"] - p["y"]) <= 60:
                    other.bump(4, now)
        self.alert(e["kind"], e["text"], key=e.get("key") or f"{e['kind']}:{e['text']}", agent=e.get("agent"),
                   ttl=e.get("ttl", 60), position=p)

    def alert(self, kind, text, key=None, agent=None, ttl=45, position=None):
        now = time.time()
        key = key or f"{kind}:{text}"
        if key in self.alert_keys and now - self.alert_keys[key] < ttl:
            return
        self.alert_keys[key] = now
        self.alerts.append({"id": f"{key}:{int(now)}", "key": key, "kind": kind, "text": text, "agent": agent,
                            "t": now, "until": now + min(ttl, 40), "position": position})

    # ---- derived ---------------------------------------------------------------------------------------------
    def activity(self, ag, now):
        if not ag.connected:
            return "offline"
        if not ag.alive:
            return "dead"
        if ag.active:
            return "acting"
        if ag.last_activity_t and now - ag.last_activity_t < THINK_WINDOW and not self.paused:
            return "thinking"
        return "idle"

    def action_text(self, ag):
        if not ag.connected:
            return "client offline"
        if not ag.alive:
            if ag.dead_until_tick and ag.dead_until_tick > self.tick:
                return f"respawning in {math.ceil((ag.dead_until_tick - self.tick) / 60)} s"
            return "dead"
        if ag.active:
            return describe_action(ag.active)
        if ag.last and ag.last.get("kind"):
            outcome = ag.last.get("outcome")
            return f"last: {ag.last['kind'].replace('_', ' ')}" + (f" ({outcome.replace('_', ' ')})" if outcome else "")
        return ""

    def location(self, ag):
        # Space Age: a bot in a cargo pod says so (bot travel); a platform or another planet is named
        if ag.travel in ("ascending", "descending"):
            return ag.where or "cargo pod"
        if ag.platform:
            return where_label(ag.surface, ag.platform)
        p = ag.position
        if not p:
            return None
        if ag.surface and ag.surface != "nauvis":  # landmarks and "m from spawn" are Nauvis coordinates
            return where_label(ag.surface, ag.platform)
        best = None
        for lm in self.run.get("landmarks", []):
            d = math.hypot(p["x"] - lm["x"], p["y"] - lm["y"])
            if d <= lm.get("r", 30) and (best is None or d < best[0]):
                best = (d, lm["name"])
        if best:
            return best[1]
        d = math.hypot(p["x"], p["y"])
        if d < 25:
            return "spawn"
        ang = math.degrees(math.atan2(-p["y"], p["x"])) % 360  # Factorio y grows southward
        dirs = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]
        return f"{int(round(d / 10) * 10)} m {dirs[int((ang + 22.5) // 45) % 8]}"

    # ---- Space Age -------------------------------------------------------------------------------------------
    def _space_moments(self, now):
        """First rocket, first platform, a platform's first arrival at a planet other than Nauvis, the first landing
        on such a planet (an agent's body there, or our entities). Each fires once as a moment (segments.py turns it
        into a space_moment segment) and an alert; whatever is already true when the service starts is seeded."""
        sp = self.space
        found = []
        if sp.get("rockets"):
            found.append(("rocket", {"kind": "first_rocket", "title": "First rocket launched",
                                     "facts": {"rockets": sp["rockets"]}}))
        plats = sp.get("platforms") or []
        if plats:
            p = plats[0]
            found.append(("platform", {"kind": "first_platform", "title": f"First space platform: {p['name']}",
                                       "facts": {"platform": p["name"], "where": platform_where(p)["where"]}}))
        for p in plats:
            loc = p.get("at") if p.get("at") in PLANET_LABELS else None
            if loc and loc != "nauvis":
                found.append((f"orbit:{loc}", {"kind": "orbit", "title": f"{p['name']} reaches {planet_label(loc)}",
                                               "facts": {"platform": p["name"], "planet": planet_label(loc)},
                                               "planet": loc}))
        landed = {s: None for s in sp.get("planets") or [] if s != "nauvis"}
        for ag in self.agents.values():
            if ag.surface and ag.surface != "nauvis" and not ag.platform and ag.alive:
                landed[ag.surface] = landed.get(ag.surface) or ag
        for planet, ag in landed.items():
            who = ag.display_name if ag else None
            found.append((f"landing:{planet}", {
                "kind": "landing", "planet": planet, "agent": ag.name if ag else None,
                "title": f"{who} lands on {planet_label(planet)}" if who else f"First foothold on {planet_label(planet)}",
                "facts": {"planet": planet_label(planet), "agent": who,
                          "planets_reached": len({"nauvis", *landed})}}))
        if self.space_seen is None:
            self.space_seen = {k for k, _ in found}
            return
        for key, m in found:
            if key in self.space_seen:
                continue
            self.space_seen.add(key)
            m.update(id=f"m-{key}", key=key, t=now, game_time=fmt_game_time(self.tick / 60))
            m["facts"]["game_time"] = m["game_time"]
            self.moments.append(m)
            self.alert("space", m["title"], key=f"space:{key}", agent=m.get("agent"), ttl=40)

    def space_snapshot(self, sci):
        sp = self.space
        packs = [dict(p, label=pack_label(p["item"])) for p in sci.get("packs") or [] if p["item"] in SPACE_PACKS]
        planets = [planet_label(s) for s in sp.get("planets") or []]
        plats = [platform_where(p) for p in sp.get("platforms") or []]
        away = sorted({where_label(a.surface, a.platform) for a in self.agents.values() if a.surface and a.surface != "nauvis"})
        active = bool(sp.get("rockets") or plats or packs or len(planets) > 1 or away)
        bits = []
        if len(planets) > 1:
            bits.append(f"{len(planets)} planets")
        if plats:
            bits.append(f"{len(plats)} platform" + ("s" if len(plats) > 1 else ""))
        sci_total = sum(p.get("total") or 0 for p in packs)
        if sci_total:
            bits.append(f"{fmt_count(sci_total)} space-age science")
        elif sp.get("rockets"):
            bits.append(f"{sp['rockets']} rocket" + ("s" if sp["rockets"] > 1 else ""))
        return {"space_age": self.space_age or active, "active": active, "rockets": sp.get("rockets") or 0,
                "planets": planets, "platforms": plats, "science": packs, "away": away,
                "summary": " · ".join(bits) if active else None, "moments": list(self.moments)}

    def _rates(self):
        """Per-minute rates over the last ~2.5 game minutes from `score` total deltas (score's items only)."""
        if len(self.prod_samples) < 2:
            return {}
        t1, g1, p1 = self.prod_samples[-1]
        for t0, g0, p0 in self.prod_samples:
            if g1 - g0 <= 150:
                break
        if g1 <= g0:
            return {}
        return {k: (p1.get(k, 0) - p0.get(k, 0)) * 60.0 / (g1 - g0) for k in p1}

    def _item_row(self, n, latest, rate):
        series = self.flows.get(n)
        if series:
            series = [round(c / 2.0, 1) for c in series]  # 2-minute buckets -> per minute
        else:
            series = self._series_from_totals(n)
        total = latest.get(n) or (round(sum(self.flows.get(n) or [])) or 0)
        r = rate[n] if n in rate else (sum(series[-2:]) / len(series[-2:]) if series else None)
        return {"item": n, "total": total, "rate": None if r is None else round(r, 1), "series": series}

    def production(self, now):
        """Items for the production widget, most relevant first (up to 12, science packs excluded: see science())."""
        latest = self.prod_samples[-1][2] if self.prod_samples else {}
        rate = self._rates()
        stage = self.stage(latest)
        rows = []
        for n in ITEM_STAGE:
            if not (latest.get(n, 0) > 0 or sum(self.flows.get(n) or []) > 0):
                continue
            row = self._item_row(n, latest, rate)
            recent = sum((self.flows.get(n) or [])[-3:]) > 0 or (row["rate"] or 0) > 0
            if not recent:
                continue
            d = stage - ITEM_STAGE[n]
            w = 3.0 if d <= 0 else 2.0 if d == 1 else 1.0 if d == 2 else 0.5
            if n in ("iron-plate", "copper-plate"):
                w = max(w, 2.0)  # the base of everything stays on screen
            row["stage"] = ITEM_STAGE[n]
            row["score"] = round(w * (1 + math.log10(1 + max(0.0, row["rate"] or 0))), 3)
            rows.append(row)
        rows.sort(key=lambda r: -r["score"])
        return rows[:12]

    def stage(self, latest=None):
        """Furthest stage the factory has produced anything from (0 raw .. 5 rocket)."""
        latest = latest if latest is not None else (self.prod_samples[-1][2] if self.prod_samples else {})
        made = [n for n in list(ITEM_STAGE) + SCIENCE if latest.get(n, 0) > 0 or sum(self.flows.get(n) or []) > 0]
        return max([ITEM_STAGE.get(n, SCIENCE_STAGE.get(n, 0)) for n in made] or [0])

    def science(self, now):
        """Headline: science packs made per minute (all colours), with the per-pack split and a per-minute series."""
        latest = self.prod_samples[-1][2] if self.prod_samples else {}
        rate = self._rates()
        packs = []
        for n in SCIENCE:
            if latest.get(n, 0) > 0 or sum(self.flows.get(n) or []) > 0:
                packs.append(self._item_row(n, latest, rate))
        spm = round(sum(p["rate"] or 0 for p in packs), 1) if packs else None
        width = max((len(p["series"]) for p in packs), default=0)
        series = [round(sum((p["series"][i - width + len(p["series"])] if i - width + len(p["series"]) >= 0 else 0)
                            for p in packs), 1) for i in range(width)]
        stage = self.stage(latest)
        return {"spm": spm, "series": series, "stage": stage, "stage_label": STAGE_LABELS[stage],
                "packs": [{"item": p["item"], "rate": p["rate"], "total": p["total"]} for p in packs]}

    def _series_from_totals(self, item, buckets=30):
        if len(self.prod_samples) < 2:
            return []
        out = []
        prev = None
        for t, g, p in self.prod_samples:
            if prev and g > prev[0]:
                out.append(max(0.0, (p.get(item, 0) - prev[1]) * 60.0 / (g - prev[0])))
            prev = (g, p.get(item, 0))
        if len(out) > buckets:
            k = len(out) / buckets
            out = [sum(out[int(i * k):int((i + 1) * k)]) / max(1, int((i + 1) * k) - int(i * k)) for i in range(buckets)]
        return [round(v, 1) for v in out]

    def snapshot(self, now, cameras=None):
        cams_by_agent = {}
        for slot, cam in (cameras or {}).items():
            for name in cam.get("agents") or []:
                cams_by_agent.setdefault(name, slot)
        agents = []
        for ag in self.agents.values():
            ag.decay(now)
            agents.append({
                "name": ag.name, "kind": ag.kind, "display_name": ag.display_name, "color": ag.color,
                "glyph": ag.glyph, "motto": ag.motto, "profile_set": ag.profile_set, "model": ag.cfg.get("model"), "harness": ag.cfg.get("harness"),
                "role": ag.cfg.get("role"), "alive": ag.alive, "activity": self.activity(ag, now),
                "action": self.action_text(ag), "active": ag.active, "position": ag.position,
                "location": self.location(ag), "travel": ag.travel,
                "interest": round(ag.interest, 2),
                "last_said": ag.last_said, "camera": cams_by_agent.get(ag.name), "seen": ag.seen, "voice": ag.voice,
                "voice_description": ag.voice_description, "pronouns": ag.pronouns, "avatar": ag.avatar, "combat": ag.combat, "died_at": ag.died_at, "plan": ag.plan,
                "surface": ag.surface, "where": where_label(ag.surface, ag.platform) if ag.surface else None,
                "on_platform": bool(ag.platform),
            })
        res = self.research
        science = self.science(now)
        return {
            "now": now, "tick": self.tick, "paused": self.paused, "game_time": fmt_game_time(self.tick / 60),
            "title": self.run.get("title"), "subtitle": self.run.get("subtitle"),
            # this shift's start and end and when the next is expected (start-team.sh), for the site's offline state
            "shift": self.run.get("shift"),
            "agents": agents,
            "chat": self.chat_window(),
            "operator_requests": list(self.operator_requests),
            "research": {"current": res["current"], "label": tech_label(res["current"]), "progress": res["progress"],
                         "done_count": len(res["done"]), "recent": list(res["recent"])[:4]},
            "unused_unlocks": self.unused_unlocks(now),
            "research_news": self.research_news_snapshot(now),
            "darkness": self.darkness,
            "basemap": self.basemap,
            "production": self.production(now),
            "science": science,
            "space": self.space_snapshot(science),
            "work": self.work_snapshot(now),
            "fights": self.fights_snapshot(now),
            "alerts": [a for a in self.alerts if a["until"] > now][-3:],
            "board": self.board_snapshot(),
            "cameras": cameras or {},
            "errors": self.errors,
        }
