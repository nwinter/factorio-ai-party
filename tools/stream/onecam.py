"""One story at a time: one camera on air, the other two clients standing by (operator task 2026-10-12, after a
viewer said three cameras at once made it hard to concentrate on any one thing).

- On air: one client fills the left column (layout.json `main`; cuts.py brings it to the front in OBS). It follows
  one agent, never a pair, for at least `onair_dwell` (90 s) and usually a few minutes (`onair_max`).
- Standby: the next subject is framed on a standby client first (a jump, off air), and the cut happens once it is
  there, so viewers never watch a long pan.
- Earlier cuts only for urgent events: an agent's death, a real base loss (not minor_loss: more than three cheap
  pieces, or a turret, a machine, an engineer; one such cut per `loss_recut`), and a segment that takes the camera
  (Space Age launches and landings, spotlight, overview). The replay scene (replays.py) is its own program scene.
  After an urgent shot the story it interrupted comes back (`resume_min`).
- Inset: a minor loss (or a real one inside loss_recut) outside the on-air frame shows as a small inset for its
  length (`inset_hold`) instead of a cut. An attack with nothing lost yet is only a toast (inside the on-air frame,
  the label says it). "Inside the frame" is the client's view at its zoom after the on-air crop (director.in_frame);
  shift01 counted 60 tiles from the subject as on air, so a fight 35 tiles north of Sol got neither a cut nor an
  inset and its replay showed Sol in the base.
- Trio (operator task 2026-10-12, after Nick liked the old one-big-two-small layout because each tile said who was
  doing what): sometimes the program shows all three clients, the one on air in a big tile and the two standbys in
  small tiles (layout-3cam.json's holes), each labelled with its agent and what it does. The director picks it when
  two other agents do notable things far apart from the story on air at once (`trio_ratio`, `trio_apart`), or as a
  periodic "around the base" check-in (`trio_every`); it lasts `trio_hold` (within trio_min..trio_max) and then
  it is one camera again, with the same client on air (no cut). No flicker: at least `trio_gap` of one camera before
  a trio; never while a replay is on air (hold_layout, set by serve.py) or an urgent or segment shot holds the
  camera; the small tiles are framed off air first (like a cut) and the layout switches once both are there. An
  urgent alert or a segment that takes the camera ends a trio at once (one story for it).
- Standing still (a viewer, shift01: "should move on air to next moving player if they stand still too much"): an
  agent's model thinks between actions and its character stands there. A subject on air at least `still_min` whose
  character has not moved or visibly acted for `still_cut` gives way to an agent moving or acting now, if one scores
  at least `still_worth` of it; an agent cut away from for that is not the pick again for `still_block` (urgent
  shots aside). "Thinking" with a still character scores like idle; walking, building, mining, fighting score up.
- Look-ahead (Nick: "we know when an agent is gonna do something interesting based on their dispatched actions"):
  each agent's `plan` (live.py: the action running now as the harness status reports it, with its size and bounds).
  A big visible action (a construct or a path of many pieces, a fight, a rocket or platform action) scores
  `plan_boost`; crafting, waits and reads score `dull`. The standby is framed to fit the action's bounds ahead of the
  cut, the camera on air holds while it runs (no rotation, up to `plan_hold`), zooms to fit its bounds, and once it
  ends the stand-still rule may cut away after `plan_after` instead of `still_cut`.
- Base map (a viewer, shift01: "kind wish there was a map in one of them at times to see the overall base layout"):
  about every `map_every` (10 min) a standby shows Factorio's own map of the whole base (cameras.lua `map`: the
  remote controller's chart; framing from the snapshot's basemap, mapcam.py: the core and its outposts) and the
  program cuts to it for `map_hold` (15 s), labelled "Base map", then back to the story it interrupted. Never during
  an urgent or segment shot, a replay, a trio or an inset. A check-in trio shows the map in one small tile. A client
  that showed the map is released when it is off air (cameras.lua makes it a spectator again).
- Space platforms (Nick: "Do we have the camera look at the space platform sometimes?"): the snapshot's
  space.platforms with a view (live.py PLATFORM_LUA: surface, hub, bounds). A standby shows one platform whole
  (model.platform_shot, a fixed view on its surface), labelled "Starling · in orbit of Nauvis" (or travelling to X):
  - a visit about every `platform_every` (12 min) for `platform_hold` (20 s), the platform shown longest ago first;
    like the base map, never during an urgent or segment shot, a replay, a trio, an inset, a fight, or near a cut;
  - a departure (a platform starts travelling; Sol for a viewer: "continuous view during departure"): on it for
    `depart_hold` (60 s), "Starling · leaving Nauvis for Vulcanus"; only urgent shots and segments come first;
  - an agent's platform action (snapshot `work` on a platform: place_ghosts, paste, deconstruct, inspect, configure,
    launch, drop... with platform=; the character stands on Nauvis): the platform instead of the character, labelled
    "Astra · working on Starling", for `work_hold`, longer while its requests keep coming; then back to the agent.
  The hosts read snapshot onair.platform.
- Attention (Nick: "It would be interesting to follow its attention"): each agent's latest request with a place
  (attention.py, from its journal: inspect, transfer, configure, ghosts, scans...) is its attention point. While the
  agent on air looks or works somewhere the on-air frame does not show (`attn_fresh`, outside the frame, or a platform
  it is not aboard), the last standby shows that spot as the inset, labelled "Sol · placing ghosts 40 m north", for
  `attn_hold`, longer while it keeps at that spot (`attn_max`), following it to a new spot at most every `attn_move`.
  No cut: the story on air stays. Not in the first `attn_min` of a story, within `attn_gap` of the last one, in a fight,
  a trio, a replay, or an urgent, segment or held shot; an alert inset takes its client. The hosts read onair.attention.
- public(): "main" is the camera on air and "inset" the inset while it is up (what viewers see), so the overlay,
  model.py, replays.py, the casters and push_live keep reading cameras.main; in a trio also "cam2" and "cam3", the
  small tiles. program() is what cuts.py applies: which client is on air and which, if any, is the inset; the layout
  ("onecam" or "trio") and, in a trio, which client is in which hole.
"""
import json, re, time

from director import Director, BUILD, FIGHT, HOLDS, WALK, dist, frame_of, in_frame, surface_of
from mapcam import map_shot
from segments import CHEAP, LOSS_RE

# a key battle's enemy (alert texts: "19 lost near (-226, 68): 19 gun turret (by small demolishers)")
BIG_ENEMY = re.compile(r"demolisher|behemoth|big (?:biter|spitter|worm)|segmented|spawner|nest", re.I)


def loss_pieces(text):
    """"19 lost near (-226, 68): 19 gun turret (by small demolishers)" -> 19 (0 for any other text)."""
    m = LOSS_RE.match(text or "")
    return int(m.group(1)) if m else 0

MINOR = CHEAP + ("wall", "chest", "gate")  # a loss of at most MINOR_MAX of these is an inset, not a cut
MINOR_MAX = 3


def minor_loss(text):
    """"2 lost near (10, -66): 2 transport belt (by medium spitters)" -> True: a few cheap pieces (shake12 had dozens
    an hour). A turret, a machine, an engineer, or more than MINOR_MAX pieces is a real loss."""
    m = LOSS_RE.match(text or "")
    if not m:
        return False
    names = [n.strip().split(" ", 1)[-1] for n in m.group(2).split(",")]
    return int(m.group(1)) <= MINOR_MAX and all(n.endswith(MINOR) for n in names)

ONECAM = {
    "onair_dwell": 90.0,    # the subject on air holds at least this long (urgent events excepted)
    "onair_max": 240.0,     # after this, cut to the best other agent if it is at least rotate_ratio as interesting
    "ready_s": 1.5,         # a standby client this long on its new subject is framed (it jumps there) and may cut
    "inset_hold": 20.0,     # an inset stays up this long after its alert
    "onair_edge": 3.0,      # tiles: an alert inside the on-air frame (this far from its border) needs no cut or inset
    "loss_recut": 180.0,    # a loss within this long of the last loss cut is an inset, not a cut
    "resume_min": 30.0,     # back from an urgent shot, the story it interrupted holds at least this much longer
    "view_frac": 1.0,       # share of the client's width the on-air hole shows (serve.py: from layout.json's crop)
    "work_cut": False,      # work away from the body was a side camera's shot; no side cameras now
    "trio": True,           # sometimes one big tile and two small ones (module doc)
    "trio_hold": 90.0,      # a trio lasts this long ...
    "trio_min": 60.0,       # ... kept within these bounds (run config may set trio_hold)
    "trio_max": 120.0,
    # simulate.py --cams onecam (mock9, 2 h): ratio 0.6 and gap 300 s made a trio every ~6.5 min (a quarter of the
    # airtime); 0.9 and 480 s, one about every 10 min (~13%), with one camera the default
    "trio_gap": 480.0,      # at least this long on one camera before a trio (and after the start)
    "trio_every": 900.0,    # a check-in trio after this long without one, if two other agents are worth a tile
    "trio_ratio": 0.9,      # busy: two other agents each score at least this share of the subject on air ...
    "trio_apart": 40.0,     # ... and are this many tiles from it and from each other (distinct things)
    "trio_near": 20.0,      # a check-in needs its agents at least this far apart (else the tiles show one spot)
    "trio_zoom": 1.3,       # the small tiles are framed this much closer
    "trio_frac": 1.0,       # the big tile's share of a client's width (layout-3cam.json main is 16:9: no crop)
    "trio_force": False,    # mock screenshots: a trio whenever three agents can fill it, held
    # shift01 16:19-16:56 with 25 / 30 / 8: a cut about every 30 s, against one story at a time (operator 16:56)
    "still_cut": 30.0,      # the character on air has not moved or visibly acted this long ...
    "still_min": 60.0,      # ... and has been on air this long: cut to an agent moving or acting now
    "still_moved": 0.5,     # tiles: less than this between polls is standing still
    "moving_s": 6.0,        # "moving now": moved or visibly acted within this long
    "still_worth": 0.5,     # the moving agent must score at least this share of the one on air
    "still_block": 60.0,    # an agent cut away from for standing still is not the pick again for this long
    "still_factor": 0.5,    # "thinking" with a character still for still_cut scores like idle
    "move_boost": 1.25,     # walking, building, mining, fighting now
    "plan_boost": 1.6,      # a big visible action dispatched or running (module doc)
    "dull": 0.75,           # crafting, waits, reads
    "plan_hold": 300.0,     # the camera on air holds a big action this long at most
    "plan_after": 20.0,     # once it ends, standing still this long is enough to cut away
    "map_every": 600.0,     # a "Base map" shot about this often (0: never)
    "map_first": 300.0,     # the first one this long after the start
    "map_hold": 15.0,       # seconds on the map
    "map_trio": True,       # a check-in trio shows the map in one small tile
    "map_gap": 30.0,        # no base map within this long after another cut (16:44:05 came 2 s after one)
    # Space platforms (Nick, 21:25: "Do we have the camera look at the space platform sometimes?"; module doc)
    "platform_every": 720.0,  # a platform visit about this often while a platform has a surface (0: never)
    "platform_first": 420.0,  # the first one this long after the start (the base map's comes at 300 s)
    "platform_hold": 20.0,    # seconds on a visit
    "depart_hold": 60.0,      # a platform leaving for another planet: on it this long (Sol for awoo3391, 21:23)
    "depart_late": 30.0,      # a departure seen this long ago (a replay, an urgent shot in the way) is not shown
    "work_hold": 25.0,        # an agent's platform action shows the platform this long ...
    "work_max": 90.0,         # ... more while its requests keep coming, up to this
    "work_fresh": 12.0,       # a platform action dispatched within this long is news
    "work_gap": 180.0,        # the same agent's work on the same platform is shown again after this long
    "work_ratio": 0.8,        # an agent off air: its platform action takes over if it scores this share of the one on air
    # Fights (a viewer at 16:45: "dont move 'on air' away from agents under attack"): while the agent on air is
    # shooting or under attack, or the fight on air is still reported, no cut away but an urgent one; an attack shot
    # holds until its fight has been quiet fight_quiet; an agent under attack is a strong pick.
    "attack_hold": 30.0,
    "fight_quiet": 15.0,
    "fight_near": 40.0,     # tiles (plus half the fight's extent): a fight this close to a spot is the one there
    "fight_hold_max": 180.0,
    "fight_boost": 2.5,
    # Key battles (Nick, 12:54, Sol vs a Demolisher: "is there a good way to ensure we don't miss entirety of key
    # battles like that?"; module doc): a big enemy, a big loss, or a long fight is a story held on air
    "battle": True,
    "battle_losses": 10,    # a loss of this many pieces makes a fight a key battle ...
    "battle_long": 30.0,    # ... and so does an attack still going on after this long
    "battle_near": 60.0,    # tiles (plus half the extents): fights this close are one battle
    "battle_after": 20.0,   # held until the battle has been quiet this long (no attack, no agent in combat) ...
    "battle_loss_after": 45.0,  # ... and no loss for this long (losses come in as pieces die: 12:58 had 35 s gaps)
    "battle_max": 900.0,    # at most this long
    # Attention (Nick, 2026-10-13 12:00: "can we give a better feel in the stream for what they are paying attention
    # to?"; module doc): the agent on air looks or works away from its character -> the spot in the inset beside it
    "attention": True,
    "attn_fresh": 15.0,     # a request with a place dispatched within this long is where the agent looks now
    "attn_min": 20.0,       # the agent has been on air this long first (a cut settles before an inset)
    "attn_gap": 45.0,       # this long between attention insets
    "attn_hold": 15.0,      # an attention inset stays up this long after the request ...
    "attn_max": 45.0,       # ... more while the agent keeps at that spot, up to this
    "attn_same": 12.0,      # tiles: a request this close to the inset's spot is the same job
    "attn_move": 8.0,       # the inset moves to a new spot at most this often
    "attn_zoom": 1.2,       # a single spot; an area is fitted (no closer than this)
}
VISIBLE = FIGHT | BUILD | WALK | {"mine", "gather", "craft", "construct", "kite", "repair", "pickup", "drive", "shoot"}
DULL = {"craft", "wait_until", "sleep", "inspect", "feed", "insert", "take", "transfer", "research", "fuel", "observe"}
BIG = {"construct": 4, "build_path": 8, "build_blueprint": 4, "blueprint": 4}  # kind -> pieces that make it big


def plan_kind(a):
    return str((a.get("plan") or {}).get("kind") or a.get("active") or "").split(":")[0]


def big_plan(a):
    """A visible action worth a camera: a construct or a path of BIG pieces, a fight, a rocket or platform action."""
    k = plan_kind(a)
    if a.get("combat") or k in FIGHT or k == "kite":
        return True
    if any(w in k for w in ("rocket", "platform", "launch", "cargo")):
        return True
    p = a.get("plan") or {}
    size = p.get("remaining") if p.get("remaining") is not None else p.get("total")
    return k in BIG and (size or 0) >= BIG[k]


def plan_extent(a):
    """Tiles a view must span to show the agent and its action's bounds, or None without bounds."""
    b = (a.get("plan") or {}).get("bounds")
    if not b or not a.get("position"):
        return None
    cx, cy = (b["left"] + b["right"]) / 2, (b["top"] + b["bottom"]) / 2
    return max(b["right"] - b["left"], b["bottom"] - b["top"]) + 2 * dist(a["position"], {"x": cx, "y": cy})


def onair_doing(snap, name):
    """What the agent on air is doing, for the label "Following Luna · fixing the north wall": its line in the
    team plan, else the board item it claimed, else its current action."""
    board = snap.get("board") or {}
    for d in (board.get("plan") or {}).get("doing") or []:
        if name in (d.get("agent"), d.get("name")) and d.get("text"):
            return d["text"]
    for c in board.get("claims") or []:
        if c.get("agent") == name and c.get("title"):
            return c["title"]
    a = next((a for a in snap.get("agents") or [] if a["name"] == name), {})
    if a.get("activity") == "acting" and a.get("action"):
        return a["action"].replace("_", " ")
    return ""


def onair_info(snap, cams):
    """snapshot["onair"]: who viewers are watching, for the hosts (caster.py prefers that agent) and the page."""
    main = (cams or {}).get("main") or {}
    agents = main.get("agents") or []
    name = agents[0] if len(agents) == 1 and not main.get("attack") else None
    a = next((a for a in snap.get("agents") or [] if a["name"] == name), {}) if name else {}
    plat = main.get("platform")  # a space platform on air: {name, why (visit, departure, work), label, agent?}
    doing = main.get("follow") or ("in battle" if main.get("battle") and name else "") or (f"working on {plat['name']}" if plat and name else
                                   onair_doing(snap, name) if name else "")
    return {"agent": name, "display_name": a.get("display_name") or name, "doing": doing, "platform": plat,
            "since": main.get("since"), "client": main.get("client"), "attack": main.get("attack"),
            "follow": main.get("follow"),  # an operator follow's label on air ("Sol vs the Demolisher"), for the hosts
            "battle": main.get("battle"),  # a key battle on air (onecam watch_battle)
            "inset": ((cams or {}).get("inset") or {}).get("attack"),
            # where the agent on air is looking, in the inset beside it: {agent, kind, text, platform, position}
            "attention": ((cams or {}).get("inset") or {}).get("attention"),
            # the base map: on air, or in a trio's small tile (the hosts: "here's the whole base")
            "map": "on air" if main.get("map") else "tile" if any(r.get("map") for r in (cams or {}).values()) else None}


class OneCam(Director):
    def __init__(self, slots, sender, log_path, **tuning):
        tuning = dict(ONECAM, **{k: v for k, v in tuning.items() if v is not None})
        super().__init__(slots, sender, log_path, **tuning)
        self.cfg["side_scale"] = self.cfg["main_scale"]  # every client may go on air: framed the same
        self.onair = slots[0]["slot"] if slots else None
        self.onair_since = time.time()
        self.inset = None    # {"slot", "until"}
        self.pending = None  # {"slot", "reason"}: a standby framing an urgent shot, cut to once ready
        self.last_alert = -1e9
        self.last_program_cut = -1e9  # (Director.last_cut counts every camera command; here only cuts on air)
        self.resume = None     # {"subject", "since"}: the story an urgent shot interrupted, taken up again after it
        self.last_loss = None  # {"t", "position"} of the last loss that cut
        self.cuts = []       # (t, slot, reason)
        self.mode = "onecam"   # or "trio"
        self.mode_since = None  # None: since the start (self.started)
        self.trio = None       # {"tiles": {"cam2": client slot, "cam3": ...}, "agents", "why", "until"} while on
        self.trio_pending = None  # the same while its small tiles are being framed
        self.last_trio = -1e9  # when the last trio ended
        self.hold_layout = False  # serve.py: a replay is on air; no layout change now
        self.layouts = []      # (t, mode, why)
        self.motion = {}       # name -> {"pos", "still_since", "moved"}: when each character last moved or acted
        self.still_block = {}  # name -> until when it is not the pick (cut away from for standing still)
        self.plan_end = {}     # name -> when its last big action ended
        self.was_big = set()
        self.last_map = None   # when the last base map went on air (None: map_first after the start)
        self.basemap = None    # the snapshot's basemap (mapcam.map_shot frames the map camera from it)
        self.maps = []         # (t, where): base map shots, on air or in a trio tile
        self.fight_list = []   # the snapshot's fights still reported (fight_t: when each last went on)
        self.plat_rows = {}    # name -> the snapshot's platform row (model.platform_where: where, route, view)
        self.plat_moving = {}  # name -> travelling at the last look (a departure: False -> True)
        self.plat_shown = {}   # name -> when it was last on air
        self.last_platform = None  # when the last visit went on air (None: platform_first after the start)
        self.departure = None  # {"name", "t", "label"}: a departure seen, not on air yet
        self.work_shown = {}   # (agent, platform) -> when its work went on air
        self.platforms = []    # (t, name, why): platform shots ("visit", "departure", "work")
        self.follow = None     # an operator follow: {agent, until, label, by, since} (set_follow)
        self.fol = None        # the agent it pins on air at this step, or None
        self.battle = None     # a key battle held on air (watch_battle): {key, why, label, position, surface, ...}
        self.battles = []      # (t, key, why, label): key battles seen
        self.last_attn = -1e9  # when the last attention inset ended
        self.attns = []        # (t, agent, text): attention insets (a new spot is a new row)

    # -- clients ----------------------------------------------------------------------------------------------
    def slot(self, name):
        return next(s for s in self.slots if s["slot"] == name)

    def standbys(self):
        busy = {self.onair, self.inset and self.inset["slot"]}
        return [s for s in self.slots if s["slot"] not in busy]

    def next_slot(self):
        """The standby that frames the next subject (the first one; the other takes insets)."""
        sb = self.standbys()
        if self.pending:
            return self.slot(self.pending["slot"])
        return sb[0] if sb else None

    def program(self):
        out = {"onair": self.onair, "inset": self.inset and self.inset["slot"], "layout": self.mode}
        if self.trio:
            out["tiles"] = dict(self.trio["tiles"], main=self.onair)
        return out

    def onair_frac(self):
        return self.cfg["trio_frac"] if self.mode == "trio" else self.cfg["view_frac"]

    def cut(self, slot, reason, now):
        if slot == self.onair:
            return
        self.onair = slot
        self.onair_since = now
        self.last_program_cut = now
        self.pending = None
        cur = self.state.get(slot)
        if cur:
            cur["since"] = now
        self.cuts.append((now, slot, reason))
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"cut to {slot}: {reason}",
                                    "target": cur and {k: cur[k] for k in ("agents", "zoom") if k in cur}}) + "\n")
        who = "+".join(cur["agents"]) if cur and cur.get("agents") else (cur or {}).get("subject", "-")
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} ON AIR {slot}: {who}  <- {reason}", flush=True)

    def frame_on(self, slot, target, reason, scores, now):
        """Send a shot to a standby client: off air, so it jumps there (no easing) and the cut can follow at once."""
        self.apply(slot, dict(target, jump=True, since=now, framed=now), reason, scores, now)

    def urgent(self, target, reason, scores, now):
        """Frame on a standby, cut once it is there (step); with one client, take the on-air one. The story on air is
        remembered and taken up again when the urgent shot is over (direct)."""
        self.leave_trio(reason, now)
        self.trio_pending = None
        cur = self.state.get(self.onair)
        if cur and cur.get("subject") in scores and not self.pending:
            self.resume = {"subject": cur["subject"], "since": self.onair_since}
        cp = (cur or {}).get("platform") or {}
        if cp.get("why") == "departure" and now < cur.get("until", 0) and not reason.startswith("platform"):
            # a departure cut short by an urgent shot: back to it after, for what is left of it (maybe_departure)
            self.departure = {"name": cp["name"], "t": now, "label": cp["label"], "until": cur["until"]}
        nxt = self.next_slot()
        if not nxt:
            self.apply(self.slot(self.onair), dict(target, jump=True, since=now, framed=now), reason, scores, now)
            return
        self.frame_on(nxt, target, reason, scores, now)
        self.pending = {"slot": nxt["slot"], "reason": reason}

    def ready(self, slot, now):
        t = self.state.get(slot)
        return bool(t) and now - t.get("framed", t.get("since", now)) >= self.cfg["ready_s"]

    # -- alerts -----------------------------------------------------------------------------------------------
    def attack_target(self, snapshot, by_name, scores, now):
        """Director.attack_target, spaced on any alert handled (a cut or an inset), not on cuts alone."""
        saved = self.last_attack_cut
        self.last_attack_cut = self.last_alert
        try:
            return super().attack_target(snapshot, by_name, scores, now)
        finally:
            self.last_attack_cut = saved

    def fight_zoom(self, extent):
        return round(max(0.4, super().fight_zoom(extent) * self.cfg["view_frac"]), 2)

    def near_onair(self, subject, position, by_name):
        """Do viewers see this now: the agent on air is in it, or its position is inside the on-air frame."""
        cur = self.state.get(self.onair)
        if not cur:
            return False
        if cur.get("platform"):
            return False  # a platform shot: its agent's character is on Nauvis, out of the picture
        if subject and subject in (cur.get("agents") or []):
            return True
        return bool(position) and in_frame(frame_of(cur, self.onair_frac()), position, by_name,
                                           self.cfg["onair_edge"])

    def on_alert(self, attack, by_name, scores, now):
        subject, position, al = attack
        if al["kind"] == "attack" and not self.near_onair(subject, position, by_name):
            return  # an attack with nothing lost yet, away from the story: its toast says it (losses inset or cut)
        self.last_alert = now
        self.last_attack_alert = al
        if subject:
            target = {"agents": [subject], "follow": subject, "zoom": self.cfg["attack_zoom"], "subject": subject,
                      "solo_zoom": self.cfg["attack_zoom"]}
        else:
            death = al["kind"] == "death"
            target = {"agents": [], "subject": "@attack", "position": position, "surface": position.get("surface"),
                      "until": now + self.cfg["death_hold" if death else "attack_hold"]}
            if death:
                target["zoom"] = self.cfg["death_zoom"]
            else:
                target.update(zoom=self.fight_zoom(position.get("extent")), exact_zoom=True)
        target.update(label=al["text"], kind=al["kind"], attack_t=now, fight=al.get("key"))
        big = al["kind"] == "death" or (al["kind"] == "loss" and not minor_loss(al["text"]))
        if self.fol and subject != self.fol:
            big = False  # an operator follow: other agents' urgent events are insets or toasts, never cuts
        elif self.battle and not self.fol and not (subject and subject == self.battle.get("agent")) and \
                not self.in_battle(position):
            big = False  # a key battle on air: the same for anything elsewhere
        if big and al["kind"] == "loss" and self.last_loss and now - self.last_loss["t"] < self.cfg["loss_recut"]:
            big = False  # viewers saw a loss a moment ago: an inset keeps the story on air
        if self.mode == "trio" and not big and not self.near_onair(subject, position, by_name):
            return  # no inset over the tiles: its toast says it (a big one ends the trio in urgent())
        cur = self.state.get(self.onair)
        if self.near_onair(subject, position, by_name) and not (al["kind"] == "death" and not subject):
            # the camera on air already shows it: label it and stay through the fight
            cur.update(label=al["text"], kind=al["kind"], attack_t=now, fight=al.get("key"))
            self.onair_since = max(self.onair_since, now - self.cfg["onair_dwell"] + self.cfg["attack_hold"])
            self.last_attack_cut = now
            self.last_attack_framed = {"t": now, "how": "follow" if subject else "position"}
            return
        if big:
            if subject:  # the agent in the fight holds the camera for the fight, then normal directing resumes
                target["hold_until"] = now + self.cfg["attack_hold"]
            self.urgent(target, f"{al['kind']}: {al['text']}", scores, now)
            if al["kind"] == "loss" and position:
                self.last_loss = {"t": now, "position": position}
            self.last_attack_cut = now  # serve.py: a segment gives way, replays.py looks at the alert
            self.last_attack_framed = {"t": now, "how": "follow" if subject else "position"} \
                if (subject or al["kind"] != "death") else None
            return
        # an attack (or one cheap building lost) far from the story on air: a small inset for its length
        sb = [s for s in self.standbys() if not (self.pending and s["slot"] == self.pending["slot"])]
        if self.inset:
            slot = self.slot(self.inset["slot"])
        elif len(sb) >= 2 or (sb and not self.pending and len(self.slots) == 2):
            slot = sb[-1]
        else:
            return  # no client free for it
        if self.inset and self.inset.get("why") == "attention":
            self.last_attn = now  # an alert takes the attention inset's client
        self.frame_on(slot, dict(target, until=now + self.cfg["inset_hold"]), f"inset: {al['text']}", scores, now)
        self.inset = {"slot": slot["slot"], "until": now + self.cfg["inset_hold"]}

    # -- main loop --------------------------------------------------------------------------------------------
    # -- standing still and the look-ahead -----------------------------------------------------------------------
    def track(self, agents, now):
        for a in agents:
            m = self.motion.get(a["name"])
            p = a.get("position")
            acting = a.get("combat") or plan_kind(a) in VISIBLE
            if m is None:
                self.motion[a["name"]] = m = {"pos": p, "still_since": now, "moved": now}
            if p and m["pos"] and dist(p, m["pos"]) >= self.cfg["still_moved"]:
                m["pos"], m["moved"] = p, now
            elif p and not m["pos"]:
                m["pos"] = p
            if acting:
                m["moved"] = now
            big = big_plan(a)
            if a["name"] in self.was_big and not big:
                self.plan_end[a["name"]] = now
            (self.was_big.add if big else self.was_big.discard)(a["name"])

    def still_s(self, name, now):
        m = self.motion.get(name)
        return now - m["moved"] if m else 0.0

    def scores(self, agents, now):
        out = super().scores(agents, now)
        cfg = self.cfg
        for a in agents:
            n = a["name"]
            if n not in out:
                continue
            k = plan_kind(a)
            if a.get("combat") or k in FIGHT:
                f = cfg["fight_boost"]  # under attack or shooting: a strong pick
            elif big_plan(a):
                f = cfg["plan_boost"]
            elif k in DULL:
                f = cfg["dull"]
            elif a.get("combat") or k in VISIBLE:
                f = cfg["move_boost"]
            elif a.get("activity") == "thinking" and self.still_s(n, now) >= cfg["still_cut"]:
                f = cfg["still_factor"]  # thinking, character standing there: like idle
            else:
                f = 1.0
            out[n] = round(out[n] * f, 3)
        return out

    @staticmethod
    def fight_t(f):
        """When a fight last went on: an attack's last report; a loss entry's newest loss (live.py re-reports a loss
        alert for ~2 minutes, so its `last` says nothing). shift01 16:44: losses near (-85, -110) went from 4 to 31
        pieces while the camera had already gone back."""
        if f.get("kind") == "loss":
            return max(f.get("losses") or [-1e9])
        return f.get("last", -1e9)

    def fight_fresh(self, position, now, agent=None):
        """A fight still going on at this spot (or this agent's own): reported within fight_quiet."""
        for f in self.fight_list:
            if now - self.fight_t(f) >= self.cfg["fight_quiet"]:
                continue
            if agent and f.get("agent") == agent:
                return True
            q = f.get("position")
            if position and q and (q.get("surface") or "nauvis") == (position.get("surface") or "nauvis") and \
                    dist(q, position) <= self.cfg["fight_near"] + (q.get("extent") or 0) / 2:
                return True
        return False

    def fighting(self, name, by_name, now):
        """The agent is shooting, under attack, or in a fight still reported."""
        a = by_name.get(name) or {}
        return bool(a.get("combat") or plan_kind(a) in FIGHT or self.fight_fresh(None, now, agent=name))

    def plan_zoom(self, a):
        """The zoom that fits the agent and its action's bounds, or None."""
        ext = plan_extent(a) if big_plan(a) else None
        return self.fight_zoom(ext) if ext else None

    def step(self, snapshot, now=None, segment=None):
        now = now or time.time()
        agents = snapshot["agents"]
        by_name = {a["name"]: a for a in agents}
        self.track(agents, now)
        self.basemap = snapshot.get("basemap") or self.basemap
        self.fight_list = list(snapshot.get("fights") or [])
        scores = self.scores(agents, now)
        ranked = sorted(scores, key=lambda n: -scores[n])
        if not self.slots:
            return {}
        if self.pending and self.ready(self.pending["slot"], now):
            self.cut(self.pending["slot"], self.pending["reason"], now)
        if self.inset and now >= self.inset["until"]:
            if self.inset.get("why") == "attention":
                self.last_attn = now
            self.inset = None
        fol = self.fol = self.following(by_name, now)
        self.watch_battle(by_name, now)
        pinned = fol or self.battle  # an operator follow, or a key battle: nothing else takes the camera
        attack = self.attack_target(snapshot, by_name, scores, now)
        if attack:
            self.on_alert(attack, by_name, scores, now)
        cur = self.state.get(self.onair)
        urgent_hold = cur and cur.get("subject") == "@attack" and now < cur.get("until", 0)
        if segment and not attack and not urgent_hold and not pinned:  # (a follow or a battle: no segment cuts in)
            pend = self.state.get(self.pending["slot"]) if self.pending else None
            if (not cur or cur.get("seg") != segment["id"]) and not (pend and pend.get("seg") == segment["id"]):
                follow = segment.get("follow")
                if follow and follow not in by_name:
                    follow = None
                target = {"agents": [follow] if follow else [], "subject": "@segment", "zoom": segment["zoom"],
                          "seg": segment["id"], "until": segment["until"], "segment": segment["label"]}
                if follow:
                    target["follow"] = follow
                elif segment.get("position"):
                    target.update(position=segment["position"], surface=segment.get("surface"),
                                  exact_zoom=bool(segment.get("exact_zoom")))
                if follow or "position" in target:
                    self.urgent(target, f"segment: {segment['label']}", scores, now)
        elif cur and cur.get("subject") == "@segment" and (not segment or cur.get("seg") != segment["id"]):
            cur["until"] = 0  # the segment ended or was cut: back to normal directing
        self.watch_platforms(snapshot, now)
        if pinned:  # an operator follow, or a key battle: on air, nothing else takes the camera
            self.leave_trio(f"follow {fol}" if fol else f"battle: {self.battle['label']}", now)
            self.trio_pending = None
            if fol:
                self.follow_direct(fol, by_name, scores, now)
            else:
                self.battle_direct(by_name, scores, now)
        elif self.mode == "trio":
            self.maybe_departure(scores, now, segment)
            self.tiles(by_name, scores, now)
        else:
            self.maybe_departure(scores, now, segment)
            self.direct(by_name, scores, ranked, now)
            self.maybe_work(snapshot, by_name, scores, now, segment)
            self.maybe_attention(by_name, scores, now, segment)
            self.maybe_map(scores, now, segment)
            self.maybe_platform(scores, now, segment)
            self.maybe_trio(by_name, scores, ranked, now)
        self.release_maps(now)
        shown = [self.onair, self.inset and self.inset["slot"]] + list((self.trio or {}).get("tiles", {}).values())
        for t in (self.state.get(s) for s in shown if s):
            for n in (t or {}).get("agents") or []:
                self.last_on_air[n] = now
        return self.public(now)

    # -- operator follow ---------------------------------------------------------------------------------------
    def set_follow(self, agent, until, label=None, by=None, now=None):
        """The operator pins the camera on air on one agent until `until` (serve.py POST /follow, or
        runs/RUN/director-follow.json); agent None ends it."""
        self.follow = {"agent": agent, "until": float(until), "label": label or None, "by": by or "operator",
                       "since": now or time.time()} if agent else None

    def following(self, by_name, now):
        """The agent an operator follow pins on air now, or None (off, over, or the agent is gone)."""
        f = self.follow
        if not f or now >= f["until"]:
            return None
        return f["agent"] if f["agent"] in by_name else None

    def follow_info(self, now):
        """snapshot["follow"]: {agent, label, until, remaining_s, by}, or None."""
        f = self.follow
        if not f or now >= f["until"]:
            return None
        return {"agent": f["agent"], "label": f["label"], "until": round(f["until"], 1),
                "remaining_s": int(f["until"] - now), "by": f["by"]}

    def follow_direct(self, name, by_name, scores, now):
        """An operator follow: the camera on air stays on `name` (zoom follows its activity); if it is elsewhere, a
        standby is framed on the agent and the program cuts to it. No rotation, trio, base map, platform shot,
        attention inset or segment meanwhile; other agents' urgent events are insets (on_alert)."""
        cur = self.state.get(self.onair) or {}
        if self.pending:
            if (self.state.get(self.pending["slot"]) or {}).get("subject") == name:
                return  # its own fight being framed: the cut comes within ready_s
            self.pending = None
        if cur.get("subject") == name:
            self.keep(cur, by_name, now)
            return
        label = self.follow["label"] or name
        z = self.zoom_for(by_name[name], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
        shot = {"agents": [name], "follow": name, "zoom": z, "solo_zoom": z, "subject": name}
        nxt = self.next_slot()
        if not nxt:  # one client: retarget it on air
            self.apply(self.slot(self.onair), dict(shot, since=now), f"follow: {label}", scores, now)
            self.onair_since = now
            return
        t = self.state.get(nxt["slot"])
        if not t or t.get("subject") != name:
            self.frame_on(nxt, shot, f"standby: follow {name}", scores, now)
        elif self.ready(nxt["slot"], now):
            self.cut(nxt["slot"], f"follow: {label}", now)
            self.resume = None

    # -- key battles -------------------------------------------------------------------------------------------
    def fight_spot(self, f, by_name):
        """A fight's position with its surface (an agent's own fight: the agent's surface)."""
        p = dict(f.get("position") or {})
        if not p.get("surface"):
            a = by_name.get(f.get("agent")) or {}
            p["surface"] = surface_of(a) if a else "nauvis"
        return p

    def key_fight(self, f, now):
        """Why a fight going on now is a key battle (a big enemy, a big loss, an attack past battle_long), or None."""
        cfg = self.cfg
        if now - self.fight_t(f) >= cfg["fight_quiet"] or not f.get("position"):
            return None
        text = f.get("text") or ""
        if BIG_ENEMY.search(text):
            return "big enemy"
        if loss_pieces(text) >= cfg["battle_losses"]:
            return "big loss"
        if f.get("kind") != "loss" and now - f.get("first", now) >= cfg["battle_long"]:
            return "long fight"
        return None

    def in_battle(self, p, b=None):
        b = b or self.battle
        if not b or not p or p.get("x") is None:
            return False
        if (p.get("surface") or b["surface"]) != b["surface"]:
            return False
        return dist(p, b["position"]) <= self.cfg["battle_near"] + (b.get("extent") or 0) / 2 + (p.get("extent") or 0) / 2

    def battle_agent(self, b, by_name):
        """The agent fighting in it: alive, on its surface, in combat (or its own fight reported), nearest first."""
        own = {k.split(":", 1)[1] for k in b.get("fresh", ()) if k.startswith("attack:")}
        best = None
        for a in by_name.values():
            p = a.get("position")
            if not a.get("alive", True) or not p or surface_of(a) != b["surface"]:
                continue
            if not (a.get("combat") or plan_kind(a) in FIGHT or a["name"] in own):
                continue
            d = dist(p, b["position"])
            if d <= self.cfg["battle_near"] + (b.get("extent") or 0) / 2 and (best is None or d < best[0]):
                best = (d, a["name"])
        return best[1] if best else None

    def watch_battle(self, by_name, now):
        """Start, grow and end the key battle from the snapshot's fights (a battle: the fights near the first one)."""
        cfg = self.cfg
        if not cfg["battle"]:
            return
        b = self.battle
        if not b:
            for f in sorted(self.fight_list, key=lambda f: f.get("first", now)):
                why = self.key_fight(f, now)
                if not why:
                    continue
                p = self.fight_spot(f, by_name)
                b = self.battle = {"key": f["key"], "why": why, "position": {"x": p["x"], "y": p["y"]},
                                   "surface": p["surface"], "extent": p.get("extent") or 0, "since": now,
                                   "first": min(f.get("first", now), now), "last": self.fight_t(f), "keys": set(),
                                   "lost": 0, "label": "", "agent": None}
                cur = self.state.get(self.onair)
                if cur and cur.get("subject") in by_name:
                    self.resume = {"subject": cur["subject"], "since": self.onair_since}  # back to it afterwards
                self.battles.append((now, f["key"], why, f.get("text")))
                print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} BATTLE ({why}): {f.get('text')}",
                      flush=True)
                break
            if not b:
                return
        b["fresh"] = set()
        for f in self.fight_list:
            p = self.fight_spot(f, by_name)
            if now - self.fight_t(f) >= cfg["fight_quiet"] or not self.in_battle(dict(p, extent=0), b):
                continue
            b["keys"].add(f["key"])
            b["fresh"].add(f["key"])
            b["first"] = min(b["first"], f.get("first", now))
            b["last"] = max(b["last"], self.fight_t(f))
            k = "last_loss" if f.get("kind") == "loss" else "last_attack"
            b[k] = max(b.get(k, -1e9), self.fight_t(f))
            # the battle's area grows to cover its fights (a raid along a turret line)
            r = max(b["extent"] / 2, dist(p, b["position"]) + (p.get("extent") or 0) / 2)
            b["extent"] = round(min(2 * r, 120.0), 1)
            if loss_pieces(f.get("text")) >= b["lost"]:  # live.py's loss alerts count up through a raid
                b["lost"], b["loss_text"] = loss_pieces(f.get("text")), f["text"]
        b["agent"] = self.battle_agent(b, by_name)
        who = (by_name.get(b["agent"]) or {}).get("display_name") or b["agent"]
        b["label"] = (f"{who} in battle" if who else "Battle") + \
            (f" · {b['loss_text']}" if b.get("loss_text") else "")
        if b["agent"]:
            b["last_attack"] = now  # its agent still fighting in it
        quiet = now - b.get("last_attack", -1e9) >= cfg["battle_after"] and \
            now - b.get("last_loss", -1e9) >= cfg["battle_loss_after"]
        if quiet or now - b["since"] >= cfg["battle_max"]:
            print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} battle over after "
                  f"{int(now - b['since'])} s: {b['label']}", flush=True)
            self.battle = None

    def battle_target(self, b, by_name):
        """The battle's shot, chosen once (shift06 13:29: the combat flag flickered and the camera cut between Astra
        and the area view every few seconds): its agent while it is alive in the battle's area, then the area for
        good."""
        if "follow" not in b:
            b["follow"] = b["agent"]
        n = b["follow"]
        if n:
            a = by_name.get(n) or {}
            if not (a.get("alive", True) and a.get("position") and surface_of(a) == b["surface"] and
                    dist(a["position"], b["position"]) <= self.cfg["battle_near"] + b["extent"] / 2):
                b["follow"] = n = None  # dead or gone from it: the area from now on
        if n:
            ext = b["extent"] + 2 * dist(by_name[n]["position"], b["position"])
            z = min(self.cfg["attack_zoom"], self.fight_zoom(ext))
            return {"agents": [n], "follow": n, "zoom": z, "solo_zoom": z, "exact_zoom": True, "subject": n,
                    "battle": b["key"]}
        return {"agents": [], "subject": "@battle", "position": dict(b["position"]), "surface": b["surface"],
                "zoom": self.fight_zoom(b["extent"]), "exact_zoom": True, "battle": b["key"]}

    def battle_direct(self, by_name, scores, now):
        """A key battle: the camera on air on it (its agent followed, else a fixed view on the battle's area) until it
        has been quiet battle_after. A death or loss shot inside the battle holds as usual; the zoom follows the
        battle's extent. Other agents' urgent events are insets (on_alert)."""
        b = self.battle
        cur = self.state.get(self.onair) or {}
        cpos = dict(cur.get("position") or {}, surface=cur.get("surface")) if cur.get("position") else None
        if cur.get("subject") in HOLDS and now < cur.get("until", 0) and self.in_battle(cpos):
            return  # a loss or death shot of this battle
        if self.pending:
            p = self.state.get(self.pending["slot"]) or {}
            ppos = dict(p.get("position") or {}, surface=p.get("surface")) if p.get("position") else None
            if p.get("battle") == b["key"] or self.in_battle(ppos) or (b["agent"] and p.get("subject") == b["agent"]):
                return  # being framed: the cut comes within ready_s
            self.pending = None
        want = self.battle_target(b, by_name)
        same = cur.get("subject") == want["subject"] and (
            cur.get("battle") == b["key"] or want["subject"] != "@battle" or self.in_battle(cpos))
        if same:  # on it already: reframed in place (zoom, centre), never a cut
            cur["battle"] = b["key"]
            if abs(cur["zoom"] - want["zoom"]) >= self.cfg["zoom_delta"] or \
                    (cpos and dist(cpos, want.get("position") or cpos) > 8):
                self.apply(self.slot(self.onair), dict(cur, **{k: v for k, v in want.items()}, since=cur.get("since", now)),
                           f"battle: zoom {want['zoom']}", scores, now, quiet=True)
            return
        nxt = self.next_slot()
        if not nxt:
            self.apply(self.slot(self.onair), dict(want, since=now), f"battle: {b['label']}", scores, now)
            self.onair_since = now
            return
        t = self.state.get(nxt["slot"])
        if not t or t.get("subject") != want["subject"] or t.get("battle") != b["key"]:
            self.frame_on(nxt, want, f"standby: battle {b['key']}", scores, now)
        elif self.ready(nxt["slot"], now):
            self.cut(nxt["slot"], f"battle ({b['why']}): {b['label']}", now)

    def battle_info(self, now):
        """snapshot["battle"]: the key battle on now (the hosts; replays.py covers it from its first sign), or None."""
        b = self.battle
        if not b:
            return None
        cur = self.state.get(self.onair) or {}
        return {"key": b["key"], "why": b["why"], "label": b["label"], "agent": b["agent"], "first": round(b["first"], 1),
                "since": round(b["since"], 1), "last": round(b["last"], 1), "lost": b["lost"],
                "position": dict(b["position"], surface=b["surface"]), "extent": b["extent"],
                "on_air": cur.get("battle") == b["key"] or bool(b["agent"] and b["agent"] in (cur.get("agents") or []))}

    # -- attention ---------------------------------------------------------------------------------------------
    def attention_far(self, a, by_name, now):
        """The agent's attention point (snapshot agents[].attention, model.py) when it is fresh and somewhere the
        on-air frame does not show: a spot on its surface outside the frame, or a platform it is not aboard."""
        att = a.get("attention") or {}
        if not att.get("far") or (att.get("age_s") or 0) > self.cfg["attn_fresh"]:
            return None
        if att.get("platform"):
            view = (self.plat_rows.get(att["platform"]) or {}).get("view") or {}
            return att if view.get("surface") else None
        if not att.get("position"):
            return None
        pt = dict(att["position"], surface=att.get("surface") or "nauvis")
        cur = self.state.get(self.onair)
        if cur and in_frame(frame_of(cur, self.onair_frac()), pt, by_name, self.cfg["onair_edge"]):
            return None
        return att

    def attention_target(self, att, name, who, until):
        """A fixed shot of the attention spot for the inset, labelled "Sol placing ghosts 40 m north" (the page shows
        "Sol · placing ghosts 40 m north")."""
        if att.get("platform"):
            from model import platform_shot
            shot = platform_shot(self.plat_rows[att["platform"]]["view"])
        else:
            ext = att.get("extent") or 0
            z = min(self.cfg["attn_zoom"], Director.fight_zoom(self, ext)) if ext else self.cfg["attn_zoom"]
            shot = {"position": dict(att["position"]), "surface": att.get("surface") or "nauvis", "zoom": z,
                    "exact_zoom": True}
        return dict(shot, agents=[name], subject="@attention", until=until, work=f"{who} {att['text']}",
                    attention={"agent": name, "kind": att["kind"], "text": att["text"], "platform": att.get("platform"),
                               "position": att.get("position")})

    def maybe_attention(self, by_name, scores, now, segment=None):
        """The agent on air looks or works away from its character: that spot in the inset for attn_hold, longer
        while it keeps at it (attn_max), moved along when it goes to a new spot (at most every attn_move). No cut:
        the story on air stays; never during a fight, an urgent, segment or held shot, a replay, or a trio, and
        attn_gap between insets."""
        cfg = self.cfg
        if not cfg["attention"] or self.mode != "onecam":
            return
        cur = self.state.get(self.onair) or {}
        subj = cur.get("subject")
        ins = self.inset
        if ins and ins.get("why") == "attention":
            a = by_name.get(ins["agent"])
            if subj != ins["agent"] or not a or self.hold_layout or self.pending:
                self.inset, self.last_attn = None, now  # the story on air moved on: the inset goes with it
                return
            att = self.attention_far(a, by_name, now)
            if not att:
                return  # it runs out at `until`
            cap = ins["since"] + cfg["attn_max"]
            same = att.get("platform") == ins.get("platform") and (
                att.get("platform") or dist(att["position"], ins["position"]) <= cfg["attn_same"])
            t = self.state.get(ins["slot"]) or {}
            if same:
                ins["until"] = min(max(ins["until"], now + cfg["attn_hold"]), cap)
                t["until"] = ins["until"]
                who = a.get("display_name") or ins["agent"]
                t["work"] = f"{who} {att['text']}"  # "inspecting" -> "taking iron plate" at the same spot
                t["attention"] = dict(t.get("attention") or {}, kind=att["kind"], text=att["text"])
            elif now - ins["moved"] >= cfg["attn_move"] and now < cap - cfg["attn_move"]:
                self.show_attention(ins["slot"], ins["agent"], a, att, scores, now, since=ins["since"])
            return
        if ins or self.pending or self.trio_pending or self.hold_layout or segment or subj not in scores:
            return
        if now - self.onair_since < cfg["attn_min"] or now - self.last_attn < cfg["attn_gap"] or \
                now < cur.get("hold_until", 0) or self.fighting(subj, by_name, now):
            return
        att = self.attention_far(by_name[subj], by_name, now)
        sb = self.standbys()
        if not att or len(sb) < 2:
            return  # (the first standby frames the next subject; the last one takes insets)
        self.show_attention(sb[-1]["slot"], subj, by_name[subj], att, scores, now)

    def show_attention(self, slot, name, a, att, scores, now, since=None):
        cfg = self.cfg
        since = now if since is None else since
        until = min(now + cfg["ready_s"] + cfg["attn_hold"], since + cfg["attn_max"])
        t = self.attention_target(att, name, a.get("display_name") or name, until)
        self.frame_on(self.slot(slot), t, f"attention: {t['work']}", scores, now)
        self.inset = {"slot": slot, "until": until, "why": "attention", "agent": name, "since": since, "moved": now,
                      "position": att.get("position"), "platform": att.get("platform")}
        self.attns.append((now, name, att["text"]))

    # -- base map ----------------------------------------------------------------------------------------------
    def map_target(self, hole, until, frac):
        shot = map_shot(self.basemap, hole=hole, frac=frac)
        if not shot:
            return None
        return {"agents": [], "subject": "@map", "map": True, "position": shot["position"], "surface": "nauvis",
                "zoom": shot["zoom"], "exact_zoom": True, "until": until, "map_size": shot["size"]}

    def maybe_map(self, scores, now, segment=None):
        cfg = self.cfg
        if not cfg["map_every"] or len(self.slots) < 2 or self.mode != "onecam":
            return
        last = self.last_map if self.last_map is not None else self.started - cfg["map_every"] + cfg["map_first"]
        if now - last < cfg["map_every"]:
            return
        cur = self.state.get(self.onair)
        if (self.hold_layout or self.pending or self.inset or self.trio_pending or segment or
                (cur and cur.get("subject") in HOLDS and now < cur.get("until", 0)) or
                now - self.last_program_cut < cfg["map_gap"] or
                any(now - self.fight_t(f) < cfg["fight_quiet"] for f in self.fight_list)):
            return  # (a fight going on anywhere: an urgent cut may come, the map would be cut short)
        t = self.map_target((1208, 1032), now + cfg["ready_s"] + cfg["map_hold"], cfg["view_frac"])
        if not t:
            return
        self.last_map = now
        self.maps.append((now, "on air"))
        self.urgent(t, "base map", scores, now)

    # -- space platforms ---------------------------------------------------------------------------------------
    @staticmethod
    def travelling(row):
        return bool(row.get("route")) or row.get("state") == "on_the_path"

    def platform_label(self, name, why="visit"):
        """"Starling · in orbit of Nauvis", "Starling · travelling to Vulcanus (42%) · 72 km/s", "Starling · leaving
        Nauvis for Vulcanus"; the hub's health when it is hurt."""
        row = self.plat_rows.get(name) or {}
        route = row.get("route")
        if why == "departure" and route:
            text = f"{name} · leaving {route['from']} for {route['to']}"
        elif route:
            text = f"{name} · travelling to {route['to']}" + (f" ({route['pct']}%)" if route.get("pct") else "")
        elif self.travelling(row) or not row.get("where"):
            text = f"{name} · in transit"
        else:
            text = f"{name} · in orbit of {row['where']}" + (" · paused" if row.get("paused") else "")
        if route and row.get("speed_kms"):
            text += f" · {row['speed_kms']} km/s"
        hp = (row.get("view") or {}).get("hub_health")
        if isinstance(hp, (int, float)) and hp < 100:
            text += f" · hub {round(hp)}%"
        return text

    def watch_platforms(self, snapshot, now):
        """The snapshot's platforms; one that starts travelling (it was seen still) is a departure."""
        rows = [p for p in (snapshot.get("space") or {}).get("platforms") or [] if p.get("name")]
        if not rows and not snapshot.get("space"):
            return  # no space data in this snapshot (the director keeps what it saw)
        self.plat_rows = {p["name"]: p for p in rows}
        for p in rows:
            moving = self.travelling(p)
            if moving and self.plat_moving.get(p["name"]) is False and p.get("view"):
                self.departure = {"name": p["name"], "t": now, "label": self.platform_label(p["name"], "departure")}
                print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} departure: "
                      f"{self.departure['label']}", flush=True)
            self.plat_moving[p["name"]] = moving

    def platform_target(self, name, why, until, agent=None, label=None):
        from model import platform_shot
        view = (self.plat_rows.get(name) or {}).get("view")
        if not view or not view.get("surface"):
            return None
        t = dict(platform_shot(view), agents=[agent] if agent else [], subject="@platform", until=until,
                 platform={"name": name, "why": why, "label": label or self.platform_label(name, why)})
        if agent:
            t["platform"]["agent"] = agent
        return t

    def show_platform(self, t, scores, now):
        p = t["platform"]
        self.plat_shown[p["name"]] = now
        self.platforms.append((now, p["name"], p["why"]))
        self.urgent(t, f"platform {p['why']}: {p['label']}", scores, now)

    def plat_busy(self, now, segment):
        """An urgent or segment shot holds the camera, or something is being framed: no platform shot now."""
        cur = self.state.get(self.onair)
        return bool(self.hold_layout or self.pending or self.trio_pending or segment or
                    (cur and cur.get("subject") in HOLDS and now < cur.get("until", 0)) or
                    (cur and now < cur.get("hold_until", 0)))  # an agent in the fight an urgent cut went to

    def maybe_departure(self, scores, now, segment=None):
        d = self.departure
        if not d or len(self.slots) < 2:
            return
        if (now > d["until"] - self.cfg["platform_hold"] / 2) if d.get("until") else now - d["t"] > self.cfg["depart_late"]:
            self.departure = None  # a replay or an urgent shot was in the way the whole time: the moment has passed
            return
        cur = self.state.get(self.onair)
        if cur and cur.get("platform", {}).get("name") == d["name"] and now < cur.get("until", 0) and not self.pending:
            cur["until"] = max(cur["until"], now + self.cfg["depart_hold"])  # on air already (a visit): stay
            cur["platform"] = dict(cur["platform"], why="departure", label=d["label"])
            self.departure = None
            return
        if self.plat_busy(now, segment) and not (cur and cur.get("subject") == "@map"):
            return  # (the base map gives way to a departure)
        t = self.platform_target(d["name"], "departure", d.get("until") or now + self.cfg["ready_s"] + self.cfg["depart_hold"],
                                 label=d["label"])
        self.departure = None
        if t:
            self.show_platform(t, scores, now)

    def maybe_platform(self, scores, now, segment=None):
        """A visit: about every platform_every while a platform can be shown, the one shown longest ago."""
        cfg = self.cfg
        plats = sorted(n for n, p in self.plat_rows.items() if (p.get("view") or {}).get("surface"))
        if not cfg["platform_every"] or not plats or len(self.slots) < 2 or self.mode != "onecam":
            return
        last = self.last_platform if self.last_platform is not None else \
            self.started - cfg["platform_every"] + cfg["platform_first"]
        if now - last < cfg["platform_every"]:
            return
        if (self.plat_busy(now, segment) or self.inset or now - self.last_program_cut < cfg["map_gap"] or
                any(now - self.fight_t(f) < cfg["fight_quiet"] for f in self.fight_list)):
            return
        name = min(plats, key=lambda n: (self.plat_shown.get(n, -1e9), n))
        t = self.platform_target(name, "visit", now + cfg["ready_s"] + cfg["platform_hold"])
        if t:
            self.last_platform = now
            self.show_platform(t, scores, now)

    def maybe_work(self, snapshot, by_name, scores, now, segment=None):
        """An agent's platform action (snapshot work with a platform view): the platform instead of the character, if
        the agent is on air or scores near the one on air; held while its requests keep coming."""
        cfg = self.cfg
        fresh = {}
        for w in snapshot.get("work") or []:
            if w.get("platform") and w.get("agent") in by_name and now - w.get("t", -1e9) < cfg["work_fresh"] and \
                    w["t"] > fresh.get(w["agent"], {}).get("t", -1e9):
                fresh[w["agent"]] = w
        if not fresh or len(self.slots) < 2:
            return
        cur = self.state.get(self.onair)
        cp = (cur or {}).get("platform") or {}
        if cp.get("why") == "work" and now < cur.get("until", 0):
            w = fresh.get(cp.get("agent"))
            if w and w["platform"] == cp["name"] and now - cur.get("since", now) < cfg["work_max"]:
                cur["until"] = max(cur["until"], min(now + cfg["work_hold"], cur["since"] + cfg["work_max"]))
            return
        if self.plat_busy(now, segment) or self.mode != "onecam":
            return
        subj = (cur or {}).get("subject")
        for agent, w in sorted(fresh.items(), key=lambda kv: -kv[1]["t"]):
            if now - self.work_shown.get((agent, w["platform"]), -1e9) < cfg["work_gap"]:
                continue
            if self.fighting(agent, by_name, now):
                continue
            if agent != subj:
                if subj not in scores or now - self.onair_since < cfg["onair_dwell"] or \
                        now - self.last_program_cut < cfg["cut_spacing"] or self.fighting(subj, by_name, now) or \
                        big_plan(by_name[subj]) or scores.get(agent, 0) < scores[subj] * cfg["work_ratio"]:
                    continue
            who = by_name[agent].get("display_name") or agent
            name = w["platform"]
            if name not in self.plat_rows and w.get("view"):
                self.plat_rows[name] = {"name": name, "view": w["view"]}
            t = self.platform_target(name, "work", now + cfg["ready_s"] + cfg["work_hold"], agent=agent,
                                     label=f"{who} · working on {name}")
            if not t:
                continue
            t["work"] = f"{who} working on {name}"
            self.work_shown[(agent, name)] = now
            self.show_platform(t, scores, now)
            if agent != subj:
                self.resume = {"subject": agent, "since": now}  # then the agent's own character
            return

    def release_maps(self, now):
        """A client that showed the map and is off air now (not about to be shown either) is released: cameras.lua
        makes it a spectator again on its 5 s recheck, until the director gives it its next subject."""
        keep = {self.onair, self.inset and self.inset["slot"], self.pending and self.pending["slot"]}
        for p in (self.trio, self.trio_pending):
            keep |= set((p or {}).get("tiles", {}).values())
        for s in self.slots:
            t = self.state.get(s["slot"])
            if t and t.get("map") and s["slot"] not in keep:
                self.apply(s, None, "map over", {}, now, quiet=True)

    # -- trio: one big tile and two small ones ------------------------------------------------------------------
    def trio_pick(self, subj, by_name, scores, ranked, now):
        """-> (two agents for the small tiles, why) or None: busy (two others score near the story on air and are far
        from it and each other) or a check-in (trio_every since the last trio)."""
        def apart(a, b, d):
            pa, pb = by_name[a].get("position"), by_name[b].get("position")
            return (by_name[a].get("surface") or "nauvis") != (by_name[b].get("surface") or "nauvis") or \
                not (pa and pb) or dist(pa, pb) >= d
        cfg = self.cfg
        for d, need, why in ((cfg["trio_apart"], max(1e-6, scores.get(subj, 0) * cfg["trio_ratio"]), "busy"),
                             (cfg["trio_near"], 0, "check-in")):
            if why == "check-in" and not cfg["trio_force"] and now - max(self.last_trio, self.started) < cfg["trio_every"]:
                continue
            pick = []
            for n in ranked:
                if n == subj or scores[n] < need or not apart(n, subj, d) or any(not apart(n, p, d) for p in pick):
                    continue
                pick.append(n)
                if len(pick) == 2:
                    return pick, why
        return None

    def maybe_trio(self, by_name, scores, ranked, now):
        """One camera long enough, nothing urgent: frame two standbys for a trio, switch once both are there."""
        cfg = self.cfg
        if not cfg["trio"] or len(self.slots) < 3:
            return
        cur = self.state.get(self.onair)
        subj = cur.get("subject") if cur else None
        blocked = (self.hold_layout or self.pending or self.inset or subj not in scores or
                   self.fighting(subj, by_name, now) or
                   (not cfg["trio_force"] and now - self.since_mode() < cfg["trio_gap"]))
        p = self.trio_pending
        if blocked:
            self.trio_pending = None
            return
        if p:
            if any(a not in scores for a in p["agents"]):
                self.trio_pending = None
            elif all(self.ready(s, now) for s in p["tiles"].values()):
                hold = min(cfg["trio_max"], max(cfg["trio_min"], cfg["trio_hold"]))
                self.trio = dict(p, until=1e18 if cfg["trio_force"] else now + hold)
                self.trio_pending = None
                self.set_mode("trio", f"{p['why']}: {', '.join(p['agents'])}", now)
            return
        found = self.trio_pick(subj, by_name, scores, ranked, now)
        sb = self.standbys()
        if not found or len(sb) < 2:
            return
        pick, why = found
        tiles = {}
        if why == "check-in" and cfg["map_trio"]:  # one small tile shows the whole base on the map
            t = self.map_target((596, 336), 1e18, 1.0)
            if t:
                self.frame_on(sb[1], t, "trio tile: base map", scores, now)
                self.trio_pending = {"tiles": {"cam2": sb[0]["slot"], "cam3": sb[1]["slot"]}, "agents": pick[:1],
                                     "why": why, "map": True}
                pick = pick[:1]
                tiles["cam3"] = sb[1]["slot"]
                self.maps.append((now, "trio tile"))
        for hole, slot, name in zip(("cam2", "cam3"), sb, pick):
            z = round((self.zoom_for(by_name[name], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]) * cfg["trio_zoom"], 2)
            t = self.state.get(slot["slot"])
            if not (t and t.get("subject") == name):
                self.frame_on(slot, {"agents": [name], "follow": name, "zoom": z, "solo_zoom": z, "subject": name},
                              f"trio tile: {name}", scores, now)
            tiles[hole] = slot["slot"]
        self.trio_pending = {"tiles": tiles, "agents": pick, "why": why, "map": "cam3" in tiles and len(pick) == 1}

    def tiles(self, by_name, scores, now):
        """In a trio: the big tile keeps its story (zoom follows), the small tiles their agents; over at `until`, or at
        once when an agent in it is gone."""
        cur = self.state.get(self.onair)
        gone = (not cur or cur.get("subject") not in scores) or any(a not in scores for a in self.trio["agents"])
        if gone or now >= self.trio["until"]:
            self.leave_trio("an agent left" if gone else f"after {int(now - self.since_mode())} s", now)
            return
        self.keep(cur, by_name, now)

    def since_mode(self):
        return self.started if self.mode_since is None else self.mode_since

    def leave_trio(self, why, now):
        if self.mode != "trio":
            return
        self.trio = None
        self.last_trio = now
        self.set_mode("onecam", why, now)

    def set_mode(self, mode, why, now):
        self.mode, self.mode_since = mode, now
        self.layouts.append((now, mode, why))
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"layout {mode}: {why}", "target": None,
                                    "tiles": (self.trio or {}).get("tiles")}) + "\n")
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} LAYOUT {mode}  <- {why}", flush=True)

    def layout_info(self):
        """snapshot["onair"]["layout"]: what the program shows, for the hosts and the page."""
        out = {"mode": self.mode, "since": round(self.since_mode(), 1)}
        if self.trio:
            out.update(why=self.trio["why"], agents=list(self.trio["agents"]), until=round(self.trio["until"], 1))
        return out

    def direct(self, by_name, scores, ranked, now):
        """The story on air: keep it (zoom follows the activity), or pick the next subject on a standby and cut."""
        cur = self.state.get(self.onair)
        if self.pending:
            return  # an urgent shot is being framed; the cut comes within ready_s
        if self.trio_pending:  # the standbys are being framed for a trio: hold the story
            if cur and cur.get("subject") in scores:
                self.keep(cur, by_name, now)
            return
        if cur and cur.get("subject") == "@attack" and now >= cur.get("until", 0) and \
                now - cur.get("attack_t", now) < self.cfg["fight_hold_max"] and \
                self.fight_fresh(cur.get("position"), now):
            cur["until"] = now + 1  # the fight on air is still reported: stay until it has been quiet fight_quiet
        if cur and cur.get("subject") in HOLDS and now < cur.get("until", 0):
            return
        if cur and cur.get("subject") in scores and now - cur.get("attack_t", -1e9) < self.cfg["fight_hold_max"] and \
                (now < cur.get("hold_until", 0) or (cur.get("hold_until") and self.fighting(cur["subject"], by_name, now))):
            self.keep(cur, by_name, now)  # the agent on air in its fight: no "back to" while it goes on
            return
        subj = cur.get("subject") if cur else None
        need = subj not in scores  # nothing on air, a hold that ended, or the subject died or left
        inset_agents = set((self.state.get(self.inset["slot"]) or {}).get("agents") or []) if self.inset else set()
        blocked = {n for n, t in self.still_block.items() if now < t}
        others = [n for n in ranked if n != subj and n not in inset_agents and n not in blocked]
        cand = others[0] if others else None
        want = None
        resumed = None
        if need:
            r, self.resume = self.resume, None
            if r and r["subject"] in scores and r["subject"] not in inset_agents and \
                    subj in (None, "@attack", "@segment", "@map", "@platform", "@battle"):
                want, resumed = r["subject"], r  # back to the story the urgent shot interrupted
                self.resume = r  # kept until the cut back happens
            else:
                want = ranked[0] if ranked else None
            if want is None:
                return
        else:
            held = now - self.onair_since
            cfg = self.cfg
            holding = (big_plan(by_name[subj]) and held < cfg["plan_hold"]) or \
                self.fighting(subj, by_name, now)  # its big action runs, or it fights: stay
            if cand and not holding and held >= cfg["onair_dwell"] and now - self.last_program_cut >= cfg["cut_spacing"]:
                if scores[cand] > scores[subj] * cfg["switch_margin"] + cfg["switch_bias"]:
                    want = cand
                    reason = f"{cand} {scores[cand]} beats {subj} {scores[subj]}" + \
                        (f" ({plan_kind(by_name[cand])} ahead)" if big_plan(by_name[cand]) else "")
                elif held >= cfg["onair_max"] and scores[cand] >= scores[subj] * cfg["rotate_ratio"]:
                    want = cand
                    reason = f"rotate after {int(held)} s"
            still = self.still_s(subj, now)
            ended = now - self.plan_end.get(subj, -1e9) < cfg["onair_dwell"]
            if not want and not holding and held >= cfg["still_min"] and \
                    still >= (cfg["plan_after"] if ended else cfg["still_cut"]):
                moving = [n for n in others if self.still_s(n, now) < cfg["moving_s"]
                          and scores[n] >= scores[subj] * cfg["still_worth"]]
                if moving:
                    want = cand = moving[0]
                    why = f"{plan_kind(by_name[want])} ahead" if big_plan(by_name[want]) else "moving"
                    reason = f"{subj} still {int(still)} s; {want} {why}"
                    self.still_block[subj] = now + cfg["still_block"]
            self.keep(cur, by_name, now)
        nxt = self.next_slot()
        lead = want or cand
        if nxt and lead:
            t = self.state.get(nxt["slot"])
            fit = self.plan_zoom(by_name[lead])  # framed on its action's bounds ahead of the cut
            z = fit or self.zoom_for(by_name[lead], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            if not t or t.get("subject") != lead or abs(t["zoom"] - z) >= self.cfg["zoom_delta"]:
                keep_framed = t and t.get("subject") == lead
                shot = {"agents": [lead], "follow": lead, "zoom": z, "solo_zoom": z, "subject": lead,
                        "jump": True, "since": now, "framed": t["framed"] if keep_framed else now}
                if fit:
                    shot.update(exact_zoom=True, plan_fit=fit)
                self.apply(nxt, shot, f"standby: {lead}" + (f" ({plan_kind(by_name[lead])} bounds)" if fit else ""),
                           scores, now, quiet=True)
        if want and nxt and self.state[nxt["slot"]].get("subject") == want and self.ready(nxt["slot"], now):
            self.cut(nxt["slot"], reason if not need else f"back to {want}" if resumed else
                     (f"{subj} unavailable" if subj else "initial"), now)
            self.want[nxt["slot"]] = (self.state[nxt["slot"]]["zoom"], now)
            if resumed:
                self.resume = None
                self.onair_since = max(resumed["since"], now - self.cfg["onair_dwell"] + self.cfg["resume_min"])
        elif want and not nxt and need:  # one client only: retarget it on air
            z = self.zoom_for(by_name[want], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            self.apply(self.slot(self.onair), {"agents": [want], "follow": want, "zoom": z, "solo_zoom": z,
                                               "subject": want, "since": now}, "initial", scores, now)
            self.onair_since = now

    def keep(self, cur, by_name, now):
        """Zoom follows the on-air subject's activity once it has lasted zoom_settle (no pairs on air); while a big
        action with bounds runs, the zoom fits them."""
        subj = cur["subject"]
        fit = self.plan_zoom(by_name[subj])
        if fit or cur.get("plan_fit"):
            if fit and cur.get("plan_fit") and abs(fit - cur["plan_fit"]) < self.cfg["zoom_delta"]:
                return  # fitted already
            target = {k: v for k, v in cur.items() if k not in ("jump", "exact_zoom", "plan_fit")}
            if fit:
                target.update(zoom=fit, exact_zoom=True, plan_fit=fit)
                reason = f"zoom {fit} (fits {plan_kind(by_name[subj])})"
            else:  # the action ended: back to the activity's zoom
                target.update(zoom=self.cfg["solo_zoom"], solo_zoom=self.cfg["solo_zoom"])
                reason = "zoom (action over)"
            self.apply(self.slot(self.onair), target, reason, {}, now)
            return
        want = self.zoom_for(by_name[subj], self.cfg["solo_zoom"])
        if want is None:
            want = cur.get("solo_zoom", cur["zoom"])
        w = self.want.get(self.onair)
        if not w or abs(w[0] - want) > 1e-6:
            self.want[self.onair] = w = (want, now)
        zoom = want if now - w[1] >= self.cfg["zoom_settle"] else cur.get("solo_zoom", cur["zoom"])
        if abs(zoom - cur["zoom"]) >= self.cfg["zoom_delta"] - 1e-9 and now - cur.get("sent", 0) >= self.cfg["zoom_settle"]:
            act = str(by_name[subj].get("active") or "").split(":")[0]
            target = {k: v for k, v in cur.items() if k != "jump"}
            target.update(zoom=zoom, solo_zoom=zoom)
            self.apply(self.slot(self.onair), target, f"zoom {zoom} ({act or by_name[subj].get('activity') or 'idle'})",
                       {}, now)

    def public(self, now=None):
        now = now or time.time()
        out = {}
        rows = [("main", self.onair), ("inset", self.inset and self.inset["slot"])]
        if self.trio:
            rows += sorted(self.trio["tiles"].items())
        for key, slot in rows:
            t = self.state.get(slot) if slot else None
            if not t:
                continue
            s = self.slot(slot)
            row = {"agents": t["agents"], "zoom": t["zoom"], "since": self.onair_since if key == "main" else t["since"],
                   "player": s["player"], "pair": False, "client": slot}
            fr = frame_of(t, self.onair_frac() if key == "main" else 1.0)  # inset and small tiles are 16:9: no crop
            if fr:
                row["frame"] = fr  # replays.py: what the program shows
            if t.get("label") and now - t.get("attack_t", now) < self.cfg["attack_hold"]:
                row.update(attack=t["label"], alert=t.get("kind") or "attack")
                if t.get("fight"):
                    row["fight"] = t["fight"]
            if t.get("segment") and now < t.get("until", 0):
                row["segment"] = t["segment"]
            if t.get("surface") and t["surface"] != "nauvis":
                row["surface"] = t["surface"]
            if t.get("map"):
                row["map"] = "Base map"  # the page's label; the hosts' onair.map
            if t.get("platform"):  # {name, why, label, agent?}: a visit and a work shot read the latest row
                p = dict(t["platform"])
                if p["why"] == "visit":
                    p["label"] = self.platform_label(p["name"])
                row["platform"] = p
                if t.get("work"):
                    row["work"] = t["work"]  # the page: "Astra · working on Starling"
            if t.get("attention"):  # the inset on where the agent on air is looking: "Sol · placing ghosts 40 m north"
                row.update(work=t["work"], attention=t["attention"])
            if key == "main" and self.battle and t.get("battle") == self.battle["key"]:
                row["battle"] = self.battle["label"]  # "Sol in battle · 44 lost near (-237, 64): 40 gun turret ..."
            f = self.follow
            if key == "main" and f and f["label"] and now < f["until"] and f["agent"] in (t.get("agents") or []):
                row["follow"] = f["label"]  # the on-air card: "Following Sol · Sol vs the Demolisher"
            out[key] = row
        return out
