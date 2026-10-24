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
  (model.platform_shot, a fixed view on its surface), labelled "Starling · in orbit of Nauvis" (or travelling to X);
  framed out to its turrets' range, and in flight a closer view that pans bow to stern (d20 batch50; pan_step); a ship
  whose closer pan would take more than model.LONG_VIEWS view heights (Asterion, 275 tiles long) is framed whole at
  the zoom that fits (at least 0.3), panned over the shot, and a visit or edge shot holds until that pan has gone bow
  to stern at one view height in PAN_VIEW_S (d22 batch99 BI4, viewer Foobator):
  - a visit about every `platform_every` (12 min) for `platform_hold` (20 s), the platform shown longest ago first;
    like the base map, never during an urgent or segment shot, a replay, a trio, an inset, a fight, or near a cut;
  - a departure (a platform starts travelling; Sol for a viewer: "continuous view during departure"): on it for
    `depart_hold` (60 s), "Starling · leaving Nauvis for Vulcanus"; only urgent shots and segments come first. Only
    news takes the camera (d22 batch83 AS1, Nick 09:28: "so many routine flights now that it's pretty repetitive";
    shift57 had 24 departure cuts in 3 hours, Cinder Nauvis->Gleba 7 of them): a maiden flight, a route the platform
    has not flown in `depart_news_h` (6 game hours: model.route_last, kept in space-memory.json and seeded from the
    chronicle), a leg to or from the solar system edge or the shattered planet, or a planet new to the platform.
    Anything else is routine: on air for `depart_routine_hold` (25 s) at most once per `depart_routine_every` (20 min)
    across all platforms and once per `depart_route_every` (2 h) for one route, else in the inset when it is free and
    nothing else is up, at most once per `depart_inset_every` (10 min) and once per `depart_inset_route_every` (2 h)
    for one route (AS2), else not shown; each decision is logged with its reason ("departure routine (inset): Cinder
    Nauvis->Gleba flown 41 min ago");
  - an agent's platform action (snapshot `work` on a platform: place_ghosts, paste, deconstruct, inspect, configure,
    launch, drop... with platform=; the character stands on Nauvis): the platform instead of the character, labelled
    "Astra · working on Starling", for `work_hold`, longer while its requests keep coming; then back to the agent.
  - a platform in danger (viewer joonazan, d15 10:45: "show the ship only when something happens, e.g. ammo running
    dry"; maybe_danger): its card's danger (model.platform_danger: a hub hit in the last minute or buildings lost on it
    in the last 2 minutes, from status alerts' platform_hits and loss events; else an ammo type that runs out before the
    arrival, from the platforms read's ammo_rates), labelled with the reason ("Wayfarer under fire: 3 buildings lost",
    "Wayfarer ammo for 2 min"); under fire it holds `danger_hold` (20 s) after the latest hit or loss, at most
    `danger_max` (120 s); ammo holds `ammo_hold` (15 s); the same platform again after `danger_gap` (5 min) unless it got
    worse. It takes the camera from a visit, work or departure (a departure comes back after), never from an operator
    hold or follow, a battle, an incoming group, an urgent attack shot, a segment or a replay;
  - a ship entering the dense asteroids of a leg to or from the solar system edge (d20 batch57 S3, viewer Foobator;
    maybe_edge, edgedense.py: Aquilo to the edge from 39.7% of the way, back from 8.1%): once per leg, as a platform in
    danger is shown, for `platform_hold`, labelled "Bastion · dense asteroids near the solar system edge"; a danger shot
    takes it over;
  - POST /platform holds a whole ship for the operator's requested time (platformcam.py persists it). It overrides
    an agent follow; other urgent events are insets. A followed agent aboard also gets this whole-ship view.
    In flight it widens ahead of the ship for asteroids; held shots refresh when the bounds or flight state change.
  The hosts read snapshot onair.platform.
- Cloud (viewer Joonazan, 13:00: "can you show a shot of Gleba's spore cloud?"): Factorio's map of one surface's
  pollution or spore cloud (clouds.py frames every polluted chunk and the nests it reached; the overlay draws the
  cells in the pollutant's map colour), labelled "Spores on Gleba", for `cloud_hold` (20 s). The operator calls it
  (serve.py POST /cloud {surface?, seconds?}; it waits out a segment, a key battle or a followed group, and an
  operator follow refuses it). The director picks it on its own (`cloud_auto`) when a cloud reaches nests it had
  not reached before (the harness's pollution_reached_nest news; pentapods on Gleba), at most every `cloud_every`,
  with the base map's guards. Unlike the base map it is no terrain frame for the site (onair.map stays None;
  onair.cloud says what is on air).
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
import json, os, re, time

from director import Director, BUILD, FIGHT, HOLDS, WALK, dist, frame_of, in_frame, surface_of
import clouds
from mapcam import map_shot
from segments import CHEAP, LOSS_RE

COORD_RE = re.compile(r"\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)")


def infer_look(text, platforms):
    """A spoken line without say look= (Nick, 14:11: Sol's "first Vulcanus -> Nauvis delivery is loaded up and ready to
    go home"): one of our platforms named in it looks at that platform, else one "(x, y)" in it looks there (on the
    speaker's surface); two platforms or two spots: no look."""
    t = text or ""
    named = [p for p in platforms if re.search(r"(?<!\w)" + re.escape(p) + r"(?!\w)", t, re.I)]
    if len(named) == 1:
        return {"platform": named[0], "inferred": True}
    if named:
        return None
    pts = COORD_RE.findall(t)
    if len(pts) == 1:
        return {"position": {"x": float(pts[0][0]), "y": float(pts[0][1])}, "inferred": True}
    return None


def human_enemy(e):
    return str(e.get("name") or "enemy").replace("-", " ").capitalize()


def lead_point(trail, cfg):
    """(d23 batch124 CG1) Where a moving group will be cfg incoming_lead seconds on: trail [(t, {x, y})] oldest first,
    its velocity over the last incoming_lead_window seconds; at most incoming_lead_max tiles ahead; its last position
    when it moves under incoming_lead_min tiles a second (or with one read)."""
    t1, p1 = trail[-1]
    old = [q for q in trail if t1 - q[0] <= cfg["incoming_lead_window"]]
    t0, p0 = old[0]
    here = {"x": p1["x"], "y": p1["y"]}
    if t1 - t0 <= 0:
        return here
    vx, vy = (p1["x"] - p0["x"]) / (t1 - t0), (p1["y"] - p0["y"]) / (t1 - t0)
    speed = (vx * vx + vy * vy) ** 0.5
    if speed < cfg["incoming_lead_min"]:
        return here
    ahead = min(cfg["incoming_lead_max"], speed * cfg["incoming_lead"])
    return {"x": round(p1["x"] + vx / speed * ahead, 1), "y": round(p1["y"] + vy / speed * ahead, 1)}


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
    "inset_min": 8.0,       # an alert's inset is not replaced by another alert's inside this (a death or agent may)
    "inset_repeat": 120.0,  # an alert of a fight whose inset went up this recently is a repeat (no new inset)
    # (d22 batch89 AY5) one place, one inset a while: "Base under attack near (-144, -560): laser turret" went up 38
    # times in shift55 and 38 in shift56, a median 322 s apart, each a new alert key; an alert within inset_area tiles
    # of an inset shown less than inset_area_gap s ago is skipped unless it is worse (a loss after an attack, a death,
    # more pieces lost)
    "inset_area": 64.0,
    "inset_area_gap": 600.0,
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
    "cloud_hold": 20.0,     # seconds on a cloud shot (module doc); the operator's call may say otherwise (5..120)
    "cloud_auto": True,     # the director shows a cloud that reached new nests
    "cloud_every": 1800.0,  # at most one such shot this often
    "cloud_late": 600.0,    # a cloud shot not on air this long after it was due (or called) is dropped
    # Space platforms (Nick, 21:25: "Do we have the camera look at the space platform sometimes?"; module doc)
    "platform_every": 720.0,  # a platform visit about this often while a platform has a surface (0: never)
    "platform_first": 420.0,  # the first one this long after the start (the base map's comes at 300 s)
    "platform_hold": 20.0,    # seconds on a visit
    # A platform in danger (viewer joonazan, d15 10:45: "show the ship only when something happens, e.g. ammo running
    # dry"): its card's danger (model.platform_danger: hub hit or buildings lost lately, or ammo out before arrival)
    "danger_hold": 20.0,      # under fire: on it until this long after the latest hit or loss
    "danger_max": 120.0,      # ... at most this long in one go
    "danger_gap": 300.0,      # the same platform's danger again after this long, sooner only if it got worse
    "ammo_hold": 15.0,        # running out of ammo: on it this long
    "depart_hold": 60.0,      # a platform leaving for another planet: on it this long (Sol for awoo3391, 21:23)
    "depart_late": 30.0,      # a departure seen this long ago (a replay, an urgent shot in the way) is not shown
    # (d22 batch83 AS1, Nick 09:28) only news takes the camera; routine departures are rationed (module doc)
    "depart_news_h": 6.0,             # a route the platform has not flown in this many game hours is news
    "depart_routine_every": 1200.0,   # a routine departure on air at most this often, all platforms together
    "depart_route_every": 7200.0,     # ... and the same platform and route at most this often
    "depart_routine_hold": 25.0,      # a routine departure on air (or in the inset) this long
    "depart_inset": True,             # a routine departure off the main camera may go in a free inset ...
    # (d22 batch83 AS2, operator 09:47: 53 insets in shift57's 3 hours were the same repetition, smaller)
    "depart_inset_every": 600.0,      # ... at most this often, all platforms together
    "depart_inset_route_every": 7200.0,  # ... and the same platform and route at most this often
    # A maiden flight (viewer Foobator, d17 14:24: "please show new ships on their maiden flight"): a platform's first
    # departure since it was built (model.py's maiden_flight moment, from the chronicle), also with one camera
    "maiden_hold": 105.0,     # on it this long: the departure and the first minute and a half of flight
    "maiden_late": 90.0,      # a maiden moment older than this when the director sees it is not shown
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
    # which fights become battles and which groups are followed: a threat score against the run's own history and an
    # hourly budget (threats.py; Nick 13:45: no fixed thresholds)
    "threat_budget": 4.0,   # followed groups and battle holds per hour, the highest scores
    "threat_floor": 1.5,    # the bar never falls below this (an agent briefly attacked by a few small biters: ~1.2)
    "threat_weights": None,  # {size, tier, agent, outpost, new_dir, pieces, duration} (threats.WEIGHTS)
    "battle_spacing": 120.0,  # no new battle within this long of the last one's end
    "incoming": True,       # follow an enemy group on its way (harness attack_groups_live) when it scores enough
    "incoming_spacing": 600.0,  # at most one followed group this often
    "incoming_max": 240.0,  # following a group at most this long before contact
    "incoming_zoom": 0.7,   # a wide view: the group and what it heads for
    "incoming_contact": 12.0,  # tiles from our nearest building: contact (or the group attacking, or a fight there)
    # a followed group that turns back or stops short ends the follow (Nick d20 07:14: a group came toward Nauvis,
    # went back to the wilderness and sat there, and the camera stayed on it until incoming_max)
    "incoming_away": 40.0,  # tiles farther from our nearest building than its closest approach: turned back
    # (d23 batch124 CG1, Nick 10:00: "the biters just move for a little bit and then stopped": the 09:53 group stood
    # 44 s on air before the cut; all 12 groups followed in shift62-63 stopped or turned back short) stopped: moved
    # under incoming_still_tiles over the last incoming_still seconds (at least 80% of it read), not while gathering
    "incoming_still": 12.0,
    "incoming_still_tiles": 8.0,
    # (CG1: "as the camera followed them, it tended to lag their position rather than lead it") each pan aims where the
    # group will be incoming_lead seconds on (its velocity over the last incoming_lead_window s): the reads come about
    # every 3 s and the camera eases each move, so aiming at the last position kept it a read behind; at most
    # incoming_lead_max tiles ahead, none under incoming_lead_min tiles a second
    "incoming_lead": 4.0,
    "incoming_lead_window": 6.0,
    "incoming_lead_max": 48.0,
    "incoming_lead_min": 0.5,
    "battle_near": 60.0,    # tiles (plus half the extents): fights this close are one battle
    # held until the battle has been quiet this long (no attack, no agent in combat) and no loss for battle_loss_after;
    # 14:19:30 Sol's demolisher died in ~5 s and the hold ran 52 s (45 s after the last loss). Shorter, with a battle
    # that picks up again when its area fights within battle_spacing (12:58's raid came in waves 35 s apart).
    "follow_after_battle": 15.0,  # an operator follow {until_battle} ends this long after its battle
    "battle_resume": 45.0,  # a fight in the area of the battle that ended this recently resumes it (the next wave)
    # a big enemy on its way (harness big_enemies_live; Nick 14:44: "The demolisher approaching should be good in a PIP
    # camera"): the inset follows it while the program is on what it threatens
    "enemy_pip": True,
    "enemy_eta": 180.0,     # closing on our buildings and at most this many seconds away (its speed decides)
    "enemy_zoom": 0.6,
    "enemy_contact": 20.0,  # tiles from our nearest building: contact, the battle hold takes it from there
    "enemy_away": 10.0,     # not closing for this long: it turned away
    "battle_after": 15.0,
    "battle_loss_after": 25.0,
    "battle_max": 900.0,    # at most this long
    # Spoken-line cues (Nick, 14:11: an agent's line "can suggest the director look at something ... at lower
    # priority, but enough to cut over if something else more interesting isn't happening"; module doc)
    "cues": True,
    "cue_after": 4.0,       # a cue holds for the line's length plus this
    "cue_max": 40.0,        # (a line counted at most this long)
    "cue_agent_gap": 180.0,  # one shown cue per agent this often
    "cue_gap": 45.0,        # shown cues together at most this often
    "cue_late": 3.0,        # a line that started playing longer ago than this is no cue (missed tick, a restart)
    # Artillery impacts (viewer Foobator, 2026-10-17 12:48: "if there is only one arty shell in flight and nothing else
    # interesting has happened, can you show the impact on screen"): the harness's artillery_live shells (serve.py
    # reads it every half second while a piece is loaded with targets in range) -> a cut to the target before the shell
    # lands, held through the impact, then back to the story; below every urgent shot, battle, operator hold, segment
    # and fight (maybe_artillery)
    "artillery": True,
    "arty_gap": 180.0,      # an artillery shot at most this often
    "arty_lead": 0.6,       # a shell landing sooner than this is let go (the cut would come after it)
    "arty_after": 4.0,      # held this long after the (last) impact
    "arty_max": 20.0,       # an artillery shot at most this long, more shells landing there or not
    "arty_near": 32.0,      # tiles: a later shell landing this close to the shot's target extends it
    "arty_zoom": 0.8,
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
    # Surface balance (viewer awoo3391, 19:34: "the camera feed needs a real priority system"; 8 of 9 agents on Nauvis,
    # so rotation by agent showed Nauvis while Gemini landed on Fulgora and Sol worked Vulcanus): on-air seconds per
    # surface over the last surface_window; a surface other than Nauvis with an agent on it is due surface_share of
    # the time, more while the planet is new to the run (plus surface_new_share, fading over surface_new_hours from the
    # first time an agent was seen there). An agent on a surface under its share scores up to 1 + surface_bonus
    # (scaled by how far under); a Nauvis agent scores 1 - nauvis_penalty while another surface is under its share.
    # Only the story choice uses scores: urgent shots, battles, follows, incoming groups, segments and the dwell rules
    # come first as before. surface_bonus 0 turns it off.
    "surface_window": 1800.0,
    "surface_share": 0.3,     # 0.25 until 2026-10-14 06:45 (viewers twice: less Nauvis)
    "surface_new_share": 0.25,  # 0.10 until 2026-10-13 23:20 (viewers asked for more of a new planet, Gleba)
    "surface_new_hours": 6.0,   # 3.0 until 2026-10-14 00:02: Gleba (reached 23:28) stays new past the 03:30 change
    "surface_bonus": 1.5,
    "nauvis_penalty": 0.35,   # 0.15 until 2026-10-14 06:45
    "surface_total": 0.85,   # the other surfaces' targets together at most this (scaled down): Nauvis keeps 15% (0.75 until 2026-10-14 06:45)
    "surface_floor": 300.0,  # seconds: shares over at least this much time (a fresh start does not swing at once)
    "surface_warmup": 180.0,  # seconds of air history before the balance applies (no swing right after a restart)
    # A planet new to the run (novelty > 0) under surface_new_floor of its target share: the story pick goes to its
    # best-scoring agent, whatever the scores (viewer awoo3391, 23:46: "why arent we watching gleba right now"; Sol
    # landed on Gleba at ~23:20 and "astra 33.48 beats sol 3.603" took the camera back: a factor of at most
    # 1 + surface_bonus could not lift 3.6 over 33). Urgent shots, battles, follows, incoming groups and the dwell
    # rules still come first; once the planet has the floor the factor applies as before. 0 turns it off.
    "surface_new_floor": 0.5,
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
    plat = main.get("platform")  # {name, why (visit, departure, work, operator, follow), label, agent?}
    doing = main.get("follow") or ("in battle" if main.get("battle") and name else "") or (f"working on {plat['name']}" if plat and name else
                                   onair_doing(snap, name) if name else "")
    if plat and plat.get("why") == "follow":
        doing = " · ".join(x for x in (main.get("follow"), f"aboard {plat['name']}") if x)
    return {"agent": name, "display_name": a.get("display_name") or name, "doing": doing, "platform": plat,
            "since": main.get("since"), "client": main.get("client"), "attack": main.get("attack"),
            "follow": main.get("follow"),  # an operator follow's label on air ("Sol vs the Demolisher"), for the hosts
            "look": main.get("look"),  # an operator position shot on air: {label, by, surface, position} (lookcam.py)
            "battle": main.get("battle"),  # a key battle on air (onecam watch_battle)
            "incoming": main.get("incoming"),  # an enemy group followed on its way (onecam watch_incoming)
            "inset": ((cams or {}).get("inset") or {}).get("attack"),
            # where the agent on air is looking, in the inset beside it: {agent, kind, text, platform, position}
            "attention": ((cams or {}).get("inset") or {}).get("attention"),
            # the base map: on air, or in a trio's small tile (the hosts: "here's the whole base"); a cloud shot is
            # not the base map (mapframes.py takes the base map's terrain frames)
            "map": "on air" if main.get("map") and not main.get("cloud") else
                   "tile" if any(r.get("map") and not r.get("cloud") for r in (cams or {}).values()) else None,
            # a pollution or spore cloud on Factorio's map (onecam cloud shot): {surface, label, why}
            "cloud": main.get("cloud")}


class OneCam(Director):
    def __init__(self, slots, sender, log_path, **tuning):
        tuning = dict(ONECAM, **{k: v for k, v in tuning.items() if v is not None})
        if len(slots) < 3:
            tuning["trio"] = False  # three tiles need three clients (POG_CAMS=1: one camera, Sunday 2026-10-18)
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
        self.surface_air = []      # (t, surface, seconds): what the program showed, for the surface balance
        self.surface_seen = {}     # surface -> when an agent was first seen there (how new the planet is)
        self.surface_t = None      # the last step's time (on-air seconds are counted between steps)
        self.surface_terms = {}    # agent -> its surface factor this step (1.0: none)
        self.surface_log = None    # {"share": {surface: %}, "target": {surface: %}} for the score line
        self.surface_due = None    # {"surface", "share", "target"} (%): a new planet under its floor gets the story
        self.surface_ticks = {}    # surface -> game tick an agent first stood there (surface-seen.json, kept)
        self.surface_known = set()  # planets the run reached before ticks were kept (space-memory.json): not new
        self.surface_memory = None  # runs/RUN/surface-seen.json (set_surface_memory)
        self.game_tick = None      # the snapshot's game tick
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
        self.clouds = {}       # surface -> the snapshot's cloud row (clouds.normalise)
        self.cloud_seen = None  # reached-nest keys seen (None until the first clouds: those are old news)
        self.cloud_due = None  # {"surface", "t", "nests"}: a cloud that reached new nests, not on air yet
        self.cloud_req = None  # {"surface", "t", "seconds", "by"}: the operator's call (POST /cloud)
        self.last_cloud = -1e9  # when the director last put a cloud on air on its own
        self.cloud_shots = []  # (t, surface, why)
        self.fight_list = []   # the snapshot's fights still reported (fight_t: when each last went on)
        self.plat_rows = {}    # name -> the snapshot's platform row (model.platform_where: where, route, view)
        self.plat_moving = {}  # name -> travelling at the last look (a departure: False -> True)
        self.plat_shown = {}   # name -> when it was last on air
        self.last_platform = None  # when the last visit went on air (None: platform_first after the start)
        self.departure = None  # {"name", "t", "label", "until"?, "maiden"?, "news"?, "route"?, "why"?}: seen, not on air yet
        self.route_source = None  # (AS1) the model (serve.py): route_last and platform_visited across restarts
        self.route_ticks = {}     # (name, from, to) -> game ticks of the departures this director saw
        self.routine_main = []    # (t, route): routine departures that went on air
        self.routine_inset_t = []  # (t, route): routine departures that went in the inset (AS2)
        self.departs = []         # (t, name, decision, why): each departure's decision (main, inset, none)
        self.maiden_done = set()  # maiden_flight moment ids already taken (once per platform)
        self.work_shown = {}   # (agent, platform) -> when its work went on air
        self.danger_seen = {}  # platform -> (when its danger shot went on air or was last held, its level then)
        self.edge_legs = {}    # platform -> {leg: (origin, dest), shown}: an edge leg's dense part (maybe_edge)
        self.platforms = []    # (t, name, why): platform shots ("visit", "departure", "work")
        self.follow = None     # an operator follow: {agent, until, label, by, since} (set_follow)
        self.fol = None        # the agent it pins on air at this step, or None
        self.platform_follow = None  # POST /platform: {name, until, label, by}; kept by PlatformControl
        self.plat = None       # the operator's platform available to pin this step (takes priority over fol)
        self.look_hold = None  # POST /look: {surface, position, zoom, until, label, by}; kept by LookControl (lookcam.py)
        self.host_hold = None  # POST /hostview or the host's !view: {until, caption, label, by}; HostControl (hostview.py)
        self.look = None       # that look while it lasts (takes priority over plat and fol)
        self.battle = None     # a key battle held on air (watch_battle): {key, why, label, position, surface, ...}
        self.battles = []      # (t, key, why, label): key battles seen
        self.last_battle_end = -1e9
        self.last_alert_cut = -1e9  # the last cut an alert made (the attack_spacing between alert cuts)
        self.inset_keys = {}        # alert key -> when its inset went up (repeats of a fight drop)
        self.inset_spots = []       # (AY5) {position, t, worse} of the insets shown lately, by place
        self.last_battle = None  # the battle that ended last (it resumes within battle_spacing)
        self.cues_seen = set()  # voice clip ids already judged
        self.cue_last = {}      # agent -> when its last cue was shown
        self.last_cue = -1e9
        self.cues = []          # (t, agent, decision, label)
        self.arty_seen = set()  # artillery shell keys already judged
        self.last_arty = -1e9
        self.artys = []         # (t, decision, why, label)
        self.fight_cands = {}  # fight episode -> {score, t, pieces, text, taken?}: candidates for a battle
        self.incoming = None   # a followed enemy group: {id, since, label, score, until}
        self.last_incoming = -1e9
        self.groups_seen = set()
        from threats import Threats
        self.threats = Threats(None, weights=self.cfg.get("threat_weights"), log=self.log_threat,
                               budget=self.cfg["threat_budget"], floor=self.cfg["threat_floor"])
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
        if self.hosting(getattr(self, "step_t", None) or time.time()):
            out["host"] = True  # cuts.py: the host's capture over the cameras
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

    def retarget(self, target, reason, scores, now):
        """One client (POG_CAMS=1, Sunday 2026-10-18): no standby to frame on, so a cut moves the client on air to the
        new subject at once (a jump, as a standby's framing would) and counts as a program cut."""
        slot = self.slot(self.onair)
        self.apply(slot, dict(target, jump=True, since=now, framed=now), reason, scores, now)
        self.onair_since = self.last_program_cut = now
        self.cuts.append((now, slot["slot"], reason))
        if self.log_path:  # the program row a cut between clients writes (simulate.py and the logs read both alike)
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"move {slot['slot']}: {reason}",
                                    "target": {k: target[k] for k in ("agents", "zoom") if k in target}}) + "\n")
        who = "+".join(target.get("agents") or []) or target.get("subject", "-")
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} ON AIR {slot['slot']}: {who}  <- {reason} "
              f"(one client: moved)", flush=True)

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
            self.departure = {"name": cp["name"], "t": now, "label": cp["label"], "until": cur["until"],
                              "maiden": cp.get("maiden")}
        nxt = self.next_slot()
        if not nxt:
            self.apply(self.slot(self.onair), dict(target, jump=True, since=now, framed=now), reason, scores, now)
            return
        self.frame_on(nxt, target, reason, scores, now)
        self.pending = {"slot": nxt["slot"], "reason": reason}

    def ready(self, slot, now):
        t = self.state.get(slot)
        need = self.pending.get("ready_s") if self.pending and self.pending["slot"] == slot else None
        return bool(t) and now - t.get("framed", t.get("since", now)) >= (self.cfg["ready_s"] if need is None else need)

    def next_wake(self, now):
        """Seconds until the director should step again sooner than serve.py's 1 s tick (a cut timed to land before
        an artillery shell), else None."""
        soon = None
        if self.pending and self.pending.get("ready_s") is not None:
            t = self.state.get(self.pending["slot"]) or {}
            soon = max(0.05, t.get("framed", now) + self.pending["ready_s"] - now)
        lk = self.look_hold  # (CK1) a look's cut at its moment
        if lk and lk.get("cut_at") and lk.get("aired") is None and lk["cut_at"] > now - 1:
            soon = min(soon if soon is not None else 1e9, max(0.005, lk["cut_at"] - now))
        return soon

    # -- alerts -----------------------------------------------------------------------------------------------
    def attack_target(self, snapshot, by_name, scores, now):
        """Director.attack_target without its spacing: every fresh alert comes through (a viewer, 18:19: "please show
        all attacks in the pop up window"); on_alert spaces the cuts (attack_spacing after the last alert cut) and
        drops only repeats of a fight already shown."""
        saved = self.last_attack_cut
        self.last_attack_cut = -1e9
        try:
            return super().attack_target(snapshot, by_name, scores, now)
        finally:
            self.last_attack_cut = saved

    def inset_repeat(self, al, position, now):
        """A fight the PIP showed lately: its alert key within inset_repeat s, or the spot the inset shows now."""
        key = al.get("key")
        if key and now - self.inset_keys.get(key, -1e9) < self.cfg["inset_repeat"]:
            return True
        ins = self.inset or {}
        p = ins.get("position")
        return bool(ins.get("why") == "alert" and p and position and
                    (p.get("surface") or "nauvis") == (position.get("surface") or "nauvis") and dist(p, position) <= 40)

    INSET_KIND = {"attack": 0, "loss": 1, "death": 2}

    def inset_worse(self, al):
        """(AY5) how bad an alert is, to compare with an earlier inset at its place: its kind, then pieces lost."""
        return (self.INSET_KIND.get(al.get("kind"), 0), loss_pieces(al.get("text")))

    def inset_area_repeat(self, al, position, now):
        """(AY5) an inset shown within inset_area tiles less than inset_area_gap s ago, this alert no worse: its age."""
        if not position:
            return None
        self.inset_spots = [sp for sp in self.inset_spots if now - sp["t"] < self.cfg["inset_area_gap"]]
        worse = self.inset_worse(al)
        for sp in self.inset_spots:
            p = sp["position"]
            if (p.get("surface") or "nauvis") == (position.get("surface") or "nauvis") and \
                    dist(p, position) <= self.cfg["inset_area"] and worse <= sp["worse"]:
                return now - sp["t"]
        return None

    def fight_zoom(self, extent):
        return round(max(0.4, super().fight_zoom(extent) * self.cfg["view_frac"]), 2)

    def fire_zoom(self, a):
        """(d22 batch93 BC2, viewer Foobator 13:33: "could the camera on spidertrons zoom out a bit more when rockets are
        fired? half the action is not on cam") An agent driving a spidertron with rockets loaded and enemies within its
        guns' reach (status vehicle_fire; it fires at them on its own): the exact zoom that frames it and the farthest of
        them (a fight shot's fit and limits, fight_zoom, of twice that distance), when that is wider than its follow zoom
        on the main camera; else None."""
        vf = (a or {}).get("vehicle_fire")
        if not isinstance(vf, dict) or not vf.get("targets") or not vf.get("ammo"):
            return None
        far = vf.get("farthest") or vf.get("range")
        if not isinstance(far, (int, float)) or far <= 0:
            return None
        fit = self.fight_zoom(2.0 * far)
        base = self.zoom_for(a, self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
        return fit if fit < base * self.cfg["main_scale"] - 1e-9 else None

    @staticmethod
    def fire_text(a):
        vf = a.get("vehicle_fire") or {}
        return (f"its {str(vf.get('vehicle') or 'spidertron').replace('-', ' ')} fires: {vf.get('targets')}"
                f"{'+' if vf.get('more') else ''} enemies within {vf.get('range'):g} tiles, the farthest {vf.get('farthest')} out")

    def apply(self, slot, target, reason, scores, now, quiet=False):
        """(BC2) A follow shot of an agent whose spidertron fires (fire_zoom): sent at the wider fit."""
        if target is not None and target.get("follow") and not target.get("exact_zoom") and not target.get("map"):
            a = (getattr(self, "agents_now", None) or {}).get(target["follow"])
            fit = self.fire_zoom(a) if a else None
            scale = self.cfg["main_scale"] if slot is self.slots[0] else self.cfg["side_scale"]
            if fit and fit < target["zoom"] * scale - 1e-9:
                target = dict(target, zoom=fit, exact_zoom=True, fire_fit=fit, solo_zoom=target.get("solo_zoom", target["zoom"]))
                reason = f"{reason} (zoom {fit}: {self.fire_text(a)})"
        return super().apply(slot, target, reason, scores, now, quiet=quiet)

    def near_onair(self, subject, position, by_name):
        """Do viewers see this now: the agent on air is in it, or its position is inside the on-air frame."""
        cur = self.state.get(self.onair)
        if not cur:
            return False
        if cur.get("platform"):
            a = by_name.get(subject) or {}
            point = dict(a["position"], surface=surface_of(a)) if a.get("position") else position
            return in_frame(frame_of(cur, self.onair_frac()), point, by_name, self.cfg["onair_edge"])
        if subject and subject in (cur.get("agents") or []):
            return True
        return bool(position) and in_frame(frame_of(cur, self.onair_frac()), position, by_name,
                                           self.cfg["onair_edge"])

    def on_alert(self, attack, by_name, scores, now):
        subject, position, al = attack
        # (an attack with nothing lost yet, away from the story, gets the inset now: below)
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
        if self.look or self.plat or (self.fol and subject != self.fol):
            big = False  # an operator follow: other agents' urgent events are insets or toasts, never cuts
        elif self.battle and not self.fol and not (subject and subject == self.battle.get("agent")) and \
                not self.in_battle(position):
            big = False  # a key battle on air: the same for anything elsewhere
        elif self.incoming and not self.fol and not self.battle:
            big = False  # a group followed on its way: its own contact becomes the battle; the rest are insets
        if big and al["kind"] == "loss" and self.last_loss and now - self.last_loss["t"] < self.cfg["loss_recut"]:
            big = False  # viewers saw a loss a moment ago: an inset keeps the story on air
        if big and al["kind"] != "death" and now - self.last_alert_cut < self.cfg["attack_spacing"]:
            big = False  # an alert cut a moment ago: this one is an inset (deaths cut regardless)
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
            self.last_alert_cut = now
            self.last_attack_framed = {"t": now, "how": "follow" if subject else "position"} \
                if (subject or al["kind"] != "death") else None
            return
        # The PIP (a viewer, 18:19: "please show all attacks in the pop up window"): every real attack, enemies hitting
        # our buildings or an agent, gets the inset unless something more important holds it; only friendly fire
        # (13:37-13:54: 1-3 pipes burned by our own flamers) and repeats of a fight already shown drop. The threat
        # score is logged for tuning, it no longer decides.
        def skip(why, score=None, parts=None):
            self.log_threat({"t": round(now, 1), "threat": f"{al['kind']} inset", "key": al.get("key") or al["text"],
                             "score": score, "parts": parts or {}, "decision": "skip", "why": why})
        score, parts = (self.threats.score_fight(loss_pieces(al["text"]), al["text"], False, 0)
                        if al["kind"] == "loss" else (None, {}))
        if "friendly fire" in al["text"]:
            return skip("friendly fire (its toast only)", score, parts)
        if al["kind"] != "death" and self.inset_repeat(al, position, now):
            ins = self.inset or {}
            if ins.get("why") == "alert":
                ins["until"] = max(ins["until"], now + self.cfg["inset_hold"] / 2)  # still going: up a little longer
            return skip("the same fight as an inset shown lately", score, parts)
        if al["kind"] != "death" and not subject:
            age = self.inset_area_repeat(al, position, now)
            if age is not None:
                return skip(f"an inset {int(age)} s ago within {int(self.cfg['inset_area'])} tiles, this one no worse", score, parts)
        ins = self.inset or {}
        urgent_kind = al["kind"] == "death" or bool(subject)  # a death, an agent under attack
        if ins.get("why") == "enemy" and not urgent_kind:
            return skip("the PIP follows a big enemy coming in", score, parts)
        if ins.get("why") == "alert" and now - ins.get("t", -1e9) < self.cfg["inset_min"] and \
                (not urgent_kind or ins.get("urgent")):
            return skip(f"another alert's inset is up ({int(now - ins['t'])} s)", score, parts)
        sb = [s for s in self.standbys() if not (self.pending and s["slot"] == self.pending["slot"])]
        if self.inset:
            slot = self.slot(self.inset["slot"])
        elif len(sb) >= 2 or (sb and not self.pending and len(self.slots) == 2):
            slot = sb[-1]
        else:
            return skip("no client free for an inset", score, parts)
        if self.inset and self.inset.get("why") == "attention":
            self.last_attn = now  # an alert takes the attention inset's client
        self.frame_on(slot, dict(target, until=now + self.cfg["inset_hold"]), f"inset: {al['text']}", scores, now)
        self.inset = {"slot": slot["slot"], "until": now + self.cfg["inset_hold"], "why": "alert", "t": now,
                      "position": position or (by_name.get(subject) or {}).get("position"), "urgent": urgent_kind}
        if al.get("key"):
            self.inset_keys[al["key"]] = now
        if position and not subject:
            self.inset_spots.append({"position": position, "t": now, "worse": self.inset_worse(al)})
        if score is not None:
            self.log_threat({"t": round(now, 1), "threat": "loss inset", "key": al.get("key") or al["text"],
                             "score": score, "parts": parts, "decision": "take", "why": "a real loss away from the story"})

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
        self.surface_terms = self.surface_factors(agents, out, now)
        for n, f in self.surface_terms.items():
            out[n] = round(out[n] * f, 3)
        return out

    # -- surface balance ---------------------------------------------------------------------------------------
    @staticmethod
    def surface_of(a):
        return str((a or {}).get("surface") or "nauvis").lower()

    @staticmethod
    def balance_surface(a):
        """The planet an agent stands on, for the surface balance: its body's surface (the harness reads the body, not
        a remote view); None aboard a platform or riding a cargo pod (no body on a planet: a platform has its own
        shots, a pod is in the sky) and on a platform's surface (platform-N)."""
        a = a or {}
        s = str(a.get("surface") or "nauvis").lower()
        if a.get("travel") or a.get("on_platform") or s.startswith("platform-"):
            return None
        return s

    def onair_surface(self, by_name):
        """The surface the program shows: the followed agent's, else the shot's own (a fixed view, a platform, the map)."""
        cur = self.state.get(self.onair)
        if not cur:
            return None
        who = cur.get("follow") or (cur.get("agents") or [None])[0]
        if who and who in by_name:
            return self.surface_of(by_name[who])
        return str(cur.get("surface") or (cur.get("position") or {}).get("surface") or "nauvis").lower()

    def set_surface_memory(self, path):
        """Keep the game tick at which an agent first stood on each planet in the run folder (serve.py:
        runs/RUN/surface-seen.json) and read it back through the run's resumed-from chain, so a restart or the next
        shift of the same world does not make every planet new again (a restart at 23:27:52 gave Fulgora, reached
        shifts before, a new planet's 38%). Novelty counts surface_new_hours of game time from that tick (the game
        does not run between shifts). A planet the run reached before ticks were kept (space-memory.json, here or up
        the chain) is not new."""
        self.surface_memory = path
        name, folder = os.path.basename(path), os.path.dirname(os.path.abspath(path))
        for _ in range(20):  # this run, then the runs it resumed from
            try:
                with open(os.path.join(folder, name)) as f:
                    for s, t in (json.load(f) or {}).items():
                        if isinstance(t, (int, float)) and (s not in self.surface_ticks or t < self.surface_ticks[s]):
                            self.surface_ticks[s] = t
            except (OSError, ValueError, AttributeError):
                pass
            try:
                with open(os.path.join(folder, "space-memory.json")) as f:
                    self.surface_known.update(str(p).lower() for p in (json.load(f) or {}).get("reached") or [])
            except (OSError, ValueError, AttributeError):
                pass
            try:
                with open(os.path.join(folder, "resumed-from")) as f:
                    prev = f.read().split()[0]
            except (OSError, IndexError):
                break
            folder = os.path.join(os.path.dirname(folder), prev)

    def save_surface_memory(self):
        if not self.surface_memory:
            return
        try:
            tmp = self.surface_memory + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.surface_ticks, f, sort_keys=True)
            os.replace(tmp, self.surface_memory)
        except OSError as e:
            print(f"[director] surface memory not saved: {e}", flush=True)

    def novelty(self, s, now):
        """1 when an agent first stood on the planet, 0 after surface_new_hours: game time from the kept tick, else
        0 for a planet the run reached before ticks were kept, else wall time since this service first saw it."""
        hours = self.cfg["surface_new_hours"]
        if not hours:
            return 0.0
        if s in self.surface_ticks and self.game_tick is not None:
            age_h = max(0.0, self.game_tick - self.surface_ticks[s]) / 216000.0
        elif s in self.surface_known:
            return 0.0
        else:
            age_h = (now - self.surface_seen.get(s, now)) / 3600.0
        return max(0.0, 1.0 - age_h / hours)

    def account_surface(self, by_name, now):
        """Count the seconds since the last step to the surface on air; forget what is older than surface_window."""
        for a in by_name.values():
            s = self.balance_surface(a)
            if s and a.get("alive") and a.get("seen", True):
                self.surface_seen.setdefault(s, now)
                if s != "nauvis" and s not in self.surface_ticks and s not in self.surface_known and \
                        self.game_tick is not None:
                    self.surface_ticks[s] = self.game_tick  # a planet new to the run: its first tick is kept
                    self.save_surface_memory()
        last, self.surface_t = self.surface_t, now
        s = self.onair_surface(by_name)
        if last is not None and s and now > last:
            self.surface_air.append((now, s, min(now - last, 10.0)))
        cut = now - self.cfg["surface_window"]
        while self.surface_air and self.surface_air[0][0] < cut:
            self.surface_air.pop(0)

    def surface_shares(self, now):
        total = {}
        for _, s, dt in self.surface_air:
            total[s] = total.get(s, 0.0) + dt
        span = max(sum(total.values()), self.cfg["surface_floor"])
        return {s: v / span for s, v in total.items()}

    def surface_factors(self, agents, scored, now):
        """agent -> score factor: up for an agent on an under-served surface other than Nauvis, down for a Nauvis agent
        while one is under-served; {} when the balance is off or every surface is served."""
        cfg = self.cfg
        self.surface_due = None
        if not cfg["surface_bonus"] or not scored or sum(dt for _, _, dt in self.surface_air) < cfg["surface_warmup"]:
            self.surface_log = None
            return {}
        share = self.surface_shares(now)
        live = {self.balance_surface(a) for a in agents if a["name"] in scored}
        target, novelty = {}, {}
        for s in live - {"nauvis", None}:
            novelty[s] = self.novelty(s, now)
            target[s] = cfg["surface_share"] + cfg["surface_new_share"] * novelty[s]
        whole = sum(target.values())
        if cfg["surface_total"] and whole > cfg["surface_total"]:
            target = {s: t * cfg["surface_total"] / whole for s, t in target.items()}
        short = {s: t for s, t in target.items() if share.get(s, 0.0) < t}
        # A new planet under its floor: the one furthest under (share against target) gets the story (direct()).
        floor = cfg.get("surface_new_floor") or 0.0
        due = [(share.get(s, 0.0) / t, s) for s, t in target.items() if novelty[s] > 0 and share.get(s, 0.0) < floor * t]
        if due:
            s = min(due)[1]
            self.surface_due = {"surface": s, "share": round(100 * share.get(s, 0.0)), "target": round(100 * target[s])}
        out = {}
        for a in agents:
            n, s = a["name"], self.balance_surface(a)
            if n not in scored:
                continue
            if s in short:
                out[n] = round(1.0 + cfg["surface_bonus"] * (short[s] - share.get(s, 0.0)) / short[s], 3)
            elif s == "nauvis" and short:
                out[n] = round(1.0 - cfg["nauvis_penalty"], 3)
        self.surface_log = {"share": {s: round(100 * v) for s, v in sorted(share.items())},
                            "target": {s: round(100 * v) for s, v in sorted(target.items())}} if target else None
        if self.surface_log and self.surface_due:  # the director log names the planet under its floor
            self.surface_log["due"] = self.surface_due["surface"]
        return out

    def surface_note(self, name, by_name):
        """' (surface fulgora 4% of 35%: x2.3)' for a cut the balance helped, else ''."""
        f = self.surface_terms.get(name)
        if not f or f <= 1.0 or not self.surface_log:
            return ""
        s = self.balance_surface(by_name.get(name))
        return (f" (surface {s} {self.surface_log['share'].get(s, 0)}% of {self.surface_log['target'].get(s, 0)}%:"
                f" x{f})")

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
        self.step_t = now
        agents = snapshot["agents"]
        by_name = {a["name"]: a for a in agents}
        self.agents_now = by_name  # (BC2) apply's spidertron fit reads the agent it frames
        self.track(agents, now)
        if isinstance(snapshot.get("tick"), (int, float)) and snapshot["tick"] > 0:
            self.game_tick = snapshot["tick"]
        self.account_surface(by_name, now)
        self.basemap = snapshot.get("basemap") or self.basemap
        self.watch_clouds(snapshot, now)
        self.fight_list = list(snapshot.get("fights") or [])
        scores = self.scores(agents, now)
        ranked = sorted(scores, key=lambda n: -scores[n])
        if not self.slots:
            return {}
        self.watch_platforms(snapshot, now)
        # Host view (hostview.py; Nick 16:39: "it would be interesting for the stream viewers to also see my view"):
        # his own client's capture is on air over the cameras; nothing cuts, no inset (it would sit over his view), no
        # trio, segments and cues wait. The cameras stay where they are and the story goes on after it.
        if self.hosting(now):
            self.inset, self.pending, self.trio_pending = None, None, None
            self.leave_trio("host view", now)
            return self.public(now)
        # (after host view: a maiden flight waits for it like a segment, and is shown after if still within maiden_late)
        self.watch_maiden(snapshot, now)
        self.look = self.looking(now)
        self.plat = self.platform_following(now)
        self.fol = self.following(by_name, now)
        held = self.operator_platform_target(by_name, now)
        look = self.look_target(now)
        for t in self.state.values():
            if t and (t.get("platform") or {}).get("why") in ("operator", "follow"):
                t["until"] = held["until"] if self.same_platform(t, held) else 0
            if t and t.get("subject") == "@look":
                t["until"] = look["until"] if self.same_look(t, look) else 0
        if self.pending and (self.look or self.plat or (self.fol and
                (self.state.get(self.pending["slot"]) or {}).get("subject") != self.fol)):
            self.pending = None
        if self.pending and self.ready(self.pending["slot"], now):
            self.cut(self.pending["slot"], self.pending["reason"], now)
        if self.inset and now >= self.inset["until"]:
            if self.inset.get("why") == "attention":
                self.last_attn = now
            self.inset = None
        fol = self.fol = self.following(by_name, now)
        self.watch_battle(by_name, now)
        self.follow_battle(by_name, now)  # a follow until its battle: ends follow_after_battle after the battle
        fol = self.fol = self.following(by_name, now)
        self.watch_incoming(snapshot, by_name, scores, now, segment)
        # an operator look, platform hold or follow, a key battle, or a group followed on its way: nothing else
        # takes the camera
        pinned = self.look or self.plat or fol or self.battle or self.incoming
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
        if not pinned:
            self.cloud_operator(scores, now, segment)
        if pinned:  # an operator follow, or a key battle: on air, nothing else takes the camera
            self.leave_trio("look" if self.look else f"platform {self.plat}" if self.plat else f"follow {fol}" if fol else f"battle: {self.battle['label']}" if self.battle
                            else f"incoming: {self.incoming['label']}", now)
            self.trio_pending = None
            if self.look:
                self.look_direct(look, scores, now)
            elif self.plat:
                self.platform_direct(self.operator_platform_target(by_name, now), scores, now)
            elif fol:
                self.follow_direct(fol, by_name, scores, now)
            elif self.battle:
                self.battle_direct(by_name, scores, now)
            else:
                self.incoming_direct(snapshot, by_name, scores, now)
                if self.battle:  # contact: the battle hold from this step on
                    self.battle_direct(by_name, scores, now)
        elif self.mode == "trio":
            self.maybe_danger(scores, now, segment)
            self.maybe_edge(scores, now, segment)
            self.maybe_departure(scores, now, segment)
            self.tiles(by_name, scores, now)
        else:
            self.maybe_danger(scores, now, segment)
            self.maybe_edge(scores, now, segment)
            self.maybe_departure(scores, now, segment)
            self.direct(by_name, scores, ranked, now)
            self.maybe_work(snapshot, by_name, scores, now, segment)
            self.maybe_attention(by_name, scores, now, segment)
            self.maybe_map(scores, now, segment)
            self.maybe_cloud(scores, now, segment)
            self.maybe_platform(scores, now, segment)
            self.maybe_trio(by_name, scores, ranked, now)
        self.maybe_cue(snapshot, by_name, scores, now, segment)
        self.maybe_artillery(snapshot, by_name, scores, now, segment)
        self.maybe_enemy_pip(snapshot, by_name, scores, now)
        self.release_maps(now)
        self.pan_step(now)
        shown = [self.onair, self.inset and self.inset["slot"]] + list((self.trio or {}).get("tiles", {}).values())
        for t in (self.state.get(s) for s in shown if s):
            for n in (t or {}).get("agents") or []:
                self.last_on_air[n] = now
        return self.public(now)

    # -- operator follow ---------------------------------------------------------------------------------------
    def set_follow(self, agent, until, label=None, by=None, now=None, until_battle=False):
        """The operator pins the camera on air on one agent until `until` (serve.py POST /follow, or
        runs/RUN/director-follow.json); agent None ends it. until_battle (Nick, 14:47: "we also have camera fixed on
        Sol for a while after fight is over"): `until` is only the longest wait for the battle; once a battle with
        the agent or in its area has ended, the follow ends follow_after_battle later."""
        self.follow = {"agent": agent, "until": float(until), "label": label or None, "by": by or "operator",
                       "since": now or time.time(), "until_battle": bool(until_battle)} if agent else None

    def following(self, by_name, now):
        """The agent an operator follow pins on air now, or None (off, over, or the agent is gone)."""
        f = self.follow
        if not f or now >= f["until"]:
            return None
        return f["agent"] if f["agent"] in by_name else None

    def follow_battle(self, by_name, now):
        """until_battle: note the battle with the followed agent (it fights in it, or the battle's area is around
        it); when that battle is over, end the follow follow_after_battle later."""
        f = self.follow
        if not f or not f.get("until_battle") or now >= f["until"]:
            return
        b = self.battle
        a = by_name.get(f["agent"]) or {}
        if b and (b.get("agent") == f["agent"] or self.in_battle(dict(a.get("position") or {}, surface=surface_of(a)) if a.get("position") else None)):
            f["battle"] = b["key"]
            return
        if f.get("battle") and not (b and b["key"] == f["battle"]):
            end = now + self.cfg["follow_after_battle"]
            if end < f["until"]:
                f["until"] = end
                f["ended_by"] = f["battle"]
                print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} follow {f['agent']}: its battle "
                      f"is over, the follow ends in {int(self.cfg['follow_after_battle'])} s", flush=True)
            f["battle"] = None

    def follow_info(self, now):
        """snapshot["follow"]: {agent, label, until, remaining_s, by, until_battle, battle?}, or None."""
        f = self.follow
        if not f or now >= f["until"]:
            return None
        return {"agent": f["agent"], "label": f["label"], "until": round(f["until"], 1),
                "remaining_s": int(f["until"] - now), "by": f["by"], "until_battle": f.get("until_battle", False),
                "battle": f.get("battle"), "ended_by": f.get("ended_by")}
    def follow_direct(self, name, by_name, scores, now):
        """An operator follow: the camera on air stays on `name` (zoom follows its activity); if it is elsewhere, a
        standby is framed on the agent and the program cuts to it. Aboard, its whole platform is framed instead.
        No rotation, trio, base map, unrelated platform shot,
        attention inset or segment meanwhile; other agents' urgent events are insets (on_alert)."""
        ship = self.operator_platform_target(by_name, now)
        if ship:
            self.platform_direct(ship, scores, now)
            return
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

    # -- operator look (lookcam.py) -------------------------------------------------------------------------
    def set_host(self, host, now=None):
        """Host view on until host["until"] (hostview.py), None: off."""
        self.host_hold = dict(host, since=now or time.time()) if host else None

    def hosting(self, now):
        h = self.host_hold
        return h if h and now < h["until"] else None

    def host_info(self, now):
        """snapshot["hostview"]: {label, caption, by, until, remaining_s, since}, or None."""
        h = self.hosting(now)
        return {k: h.get(k) for k in ("label", "caption", "by", "until", "since")} | {"remaining_s": int(h["until"] - now)} if h else None

    def set_look(self, look, now=None):
        """The operator points the camera on air at a charted spot until look["until"] (serve.py POST /look, or
        runs/RUN/director-look.json); None ends it. It takes the camera from a platform hold and a follow, which
        resume after it if their time is not up."""
        self.look_hold = dict(look, since=now or time.time()) if look else None

    def looking(self, now):
        lk = self.look_hold
        return lk if lk and now < lk["until"] else None

    def look_info(self, now):
        """snapshot["look"]: {surface, position, zoom, until, remaining_s, label, by}, and (CK1) cut_at, id, platform
        and aired (when the program first showed it) when set; or None."""
        lk = self.looking(now)
        return {k: lk[k] for k in ("surface", "position", "zoom", "until", "label", "by")} | \
            {k: lk[k] for k in ("cut_at", "id", "platform", "aired") if lk.get(k) is not None} | \
            {"remaining_s": int(lk["until"] - now)} if lk else None

    def look_label(self, lk):
        """The on-air card: the operator's label, else the spot ("Vulcanus · (120, -40)")."""
        where = f"({round(lk['position']['x'])}, {round(lk['position']['y'])})"
        surf = lk["surface"]
        if surf != "nauvis":
            where = f"{surf[:1].upper() + surf[1:] if not surf.startswith('platform-') else surf} · {where}"
        return lk.get("label") or where

    def look_target(self, now):
        lk = self.looking(now)
        if not lk:
            return None
        return {"agents": [], "subject": "@look", "position": dict(lk["position"]), "surface": lk["surface"],
                "zoom": lk["zoom"], "exact_zoom": True, "until": lk["until"], "cut_at": lk.get("cut_at"),
                "look": {"label": self.look_label(lk), "by": lk["by"], "surface": lk["surface"],
                         "position": dict(lk["position"]), **({"id": lk["id"]} if lk.get("id") else {})}}

    def look_aired(self, now):
        """(CK1) The look is on the program now: when it first was, kept with the hold (the snapshot's look.aired)."""
        lk = self.look_hold
        if lk is not None and lk.get("aired") is None:
            lk["aired"] = round(now, 3)

    @staticmethod
    def same_look(a, b):
        return bool(a and b) and all(a.get(k) == b.get(k) for k in ("position", "surface", "zoom"))

    def look_direct(self, shot, scores, now):
        """Hold the spot on air: frame it on a standby and cut once it is there (one client: retarget it on air).
        The story on air is remembered and taken up again after (direct: resume)."""
        if not shot:
            return
        self.pending = None
        # (d23 batch128 CK1) cut_at: a standby frames the spot now and the program cuts at that moment (one client:
        # it moves then); until then the shot on air, its label and time stay as they are
        early = now < (shot.get("cut_at") or 0)
        cur = self.state.get(self.onair)
        if self.same_look(cur, shot):
            if early:
                return
            cur.update(look=shot["look"], until=shot["until"])  # a new label or time for the same spot
            self.look_aired(now)
            return
        if cur and cur.get("subject") in scores:
            self.resume = {"subject": cur["subject"], "since": self.onair_since}
        slot = self.next_slot() or self.slot(self.onair)
        t = self.state.get(slot["slot"])
        if not self.same_look(t, shot):
            if early and slot["slot"] == self.onair:
                return
            self.frame_on(slot, shot, f"standby: look {shot['look']['label']}", scores, now)
            if slot["slot"] == self.onair:
                self.onair_since = now
                self.look_aired(now)
            return
        t.update(look=shot["look"], until=shot["until"])
        if slot["slot"] != self.onair and self.ready(slot["slot"], now) and not early:
            self.cut(slot["slot"], f"look: {shot['look']['label']}", now)
            self.look_aired(now)

    # -- key battles -------------------------------------------------------------------------------------------
    def fight_spot(self, f, by_name):
        """A fight's position with its surface (an agent's own fight: the agent's surface)."""
        p = dict(f.get("position") or {})
        if not p.get("surface"):
            a = by_name.get(f.get("agent")) or {}
            p["surface"] = surface_of(a) if a else "nauvis"
        return p

    def base_core(self):
        """The base's core box and centre from the snapshot's basemap ({x0, y0, x1, y1}, {x, y}), or (None, None)."""
        c = (self.basemap or {}).get("core") or {}
        if not all(k in c for k in ("x0", "y0", "w", "h", "cell")):
            return None, {"x": 0, "y": 0}
        box = {"x0": c["x0"], "y0": c["y0"], "x1": c["x0"] + c["w"] * c["cell"], "y1": c["y0"] + c["h"] * c["cell"]}
        return box, {"x": (box["x0"] + box["x1"]) / 2, "y": (box["y0"] + box["y1"]) / 2}

    def set_threat_history(self, path):
        """Keep the threat history in the run folder (serve.py: runs/RUN/threat-history.json), so a restart keeps it."""
        from threats import Threats
        self.threats = Threats(path, weights=self.cfg.get("threat_weights"), log=self.log_threat,
                               budget=self.cfg["threat_budget"], floor=self.cfg["threat_floor"])

    def log_threat(self, entry):
        """threats.py's score and decision for each candidate, in the director log (to tune the weights)."""
        now = entry.get("t") or time.time()
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"threat {entry['threat']} {entry['decision']}: "
                                    f"{entry['why']}", "threat": entry}) + "\n")
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} threat {entry['threat']} {entry['key']}: "
              f"{entry['decision']} ({entry['why']}; {entry['parts']})", flush=True)

    def candidate_fights(self, by_name, now):
        """Fights going on now, scored once per fight (an episode: its key and first sign), again when it has grown
        (every 10 s, a score at least 0.5 higher); -> the first one taken, or None. Fights over join the history."""
        cfg = self.cfg
        core, centre = self.base_core()
        fresh = {}
        for f in self.fight_list:
            if now - self.fight_t(f) < cfg["fight_quiet"] and f.get("position"):
                fresh[f"{f['key']}@{int(f.get('first', now))}"] = f
        for k in [k for k in self.fight_cands if k not in fresh]:  # over: its size joins the history
            c = self.fight_cands.pop(k)
            self.threats.learn_fight(c["pieces"], c["text"])
        taken = None
        for k, f in sorted(fresh.items(), key=lambda kv: kv[1].get("first", now)):
            c = self.fight_cands.setdefault(k, {"score": None, "t": -1e9, "pieces": 0, "text": f.get("text")})
            c["pieces"] = max(c["pieces"], loss_pieces(f.get("text")))
            c["text"] = f.get("text") or c["text"]
            if c.get("taken") or now - c["t"] < 10:
                continue
            p = self.fight_spot(f, by_name)
            if self.battle and self.in_battle(dict(p, extent=0)):
                continue  # part of the battle on now: not a candidate of its own
            if not self.battle and not taken and self.last_battle and \
                    now - self.last_battle_end < cfg["battle_resume"] and self.in_battle(dict(p, extent=0), self.last_battle):
                # the battle it ended picks up again (a raid's next wave): no new score, budget or spacing
                c["taken"] = True
                taken = (f, "resume")
                self.log_threat({"t": round(now, 1), "threat": "battle", "key": k, "score": None, "parts": {},
                                 "decision": "take", "why": f"resumes the battle that ended {int(now - self.last_battle_end)} s ago"})
                continue
            agent_in = bool(f.get("agent")) or any(
                (a.get("combat") or plan_kind(a) in FIGHT) and a.get("position") and surface_of(a) == p["surface"] and
                dist(a["position"], p) <= 30 for a in by_name.values())
            score, parts = self.threats.score_fight(c["pieces"], c["text"], agent_in, now - f.get("first", now),
                                                    target=p if p["surface"] == "nauvis" else None, centre=centre,
                                                    core=core if p["surface"] == "nauvis" else None)
            if c["score"] is not None and score < c["score"] + 0.5:
                continue
            c["score"], c["t"] = score, now
            blocked = None
            if self.battle or taken:
                blocked = "a battle is on"
            elif now - self.last_battle_end < cfg["battle_spacing"]:
                blocked = f"spacing ({int(now - self.last_battle_end)} s since the last battle)"
            if self.threats.decide("battle", k, score, parts, now, blocked=blocked):
                c["taken"] = True
                taken = (f, score)
        return taken

    def start_battle(self, f, why, by_name, now, label=None):
        p = self.fight_spot(f, by_name)
        b = self.battle = {"key": f["key"], "why": why, "position": {"x": p["x"], "y": p["y"]},
                           "surface": p["surface"], "extent": p.get("extent") or 0, "since": now,
                           "first": min(f.get("first", now), now), "last": self.fight_t(f), "keys": set(),
                           "lost": 0, "label": label or "", "agent": None}
        cur = self.state.get(self.onair)
        if cur and cur.get("subject") in by_name and not self.resume:
            self.resume = {"subject": cur["subject"], "since": self.onair_since}  # back to it afterwards
        self.battles.append((now, f["key"], why, f.get("text")))
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} BATTLE ({why}): {f.get('text')}", flush=True)
        return b

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
        """Start (a fight whose threat score passes the bar, threats.py), grow and end the key battle from the
        snapshot's fights (a battle: the fights near the first one)."""
        cfg = self.cfg
        if not cfg["battle"]:
            return
        b = self.battle
        taken = self.candidate_fights(by_name, now)
        if not b:
            if not taken:
                return
            f, score = taken
            if score == "resume":  # the same battle again: its key, first sign and area (replays.py: one battle)
                last = self.last_battle
                b = self.start_battle(f, "resume", by_name, now)
                b.update(key=last["key"], first=last["first"], position=last["position"], extent=last["extent"],
                         lost=last.get("lost", 0), loss_text=last.get("loss_text"), keys=set(last.get("keys") or ()))
            else:
                b = self.start_battle(f, f"score {score}", by_name, now)
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
        if b.get("group_label") and not b.get("loss_text"):
            b["label"] = f"Battle · {b['group_label']}"
        else:
            b["label"] = (f"{who} in battle" if who else "Battle") + \
                (f" · {b['loss_text']}" if b.get("loss_text") else "")
        if b["agent"]:
            b["last_attack"] = now  # its agent still fighting in it
        quiet = now - max(b.get("last_attack", -1e9), b["since"]) >= cfg["battle_after"] and \
            now - b.get("last_loss", -1e9) >= cfg["battle_loss_after"]
        if quiet or now - b["since"] >= cfg["battle_max"]:
            print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} battle over after "
                  f"{int(now - b['since'])} s: {b['label']}", flush=True)
            self.last_battle, self.battle = b, None
            self.last_battle_end = now

    # -- incoming groups (Nick 13:40: "Can we follow biter attacks as they approach a base?") ----------------------
    def watch_incoming(self, snapshot, by_name, scores, now, segment=None):
        """New enemy groups on their way (snapshot incoming, harness attack_groups_live) are scored once
        (threats.py) and the history learns them; one that passes the bar, when nothing holds the camera and not
        within incoming_spacing of the last, is followed: a fixed view on the group that pans with it (smooth),
        labelled, until it makes contact; then the battle hold takes over at that spot."""
        cfg = self.cfg
        rows = {g["id"]: g for g in snapshot.get("incoming") or [] if g.get("id") is not None and g.get("position")}
        core, centre = self.base_core()
        # (d23 batch124 CG1) how attacks go now: each group to its end, with contact and our real losses near it
        # (threats.py observe), so routine waves the defenses hold score low
        losses = []
        for f in self.fight_list:
            n = loss_pieces(f.get("text"))
            if n and not minor_loss(f.get("text")) and f.get("losses") and f.get("position"):
                losses.append({"key": f"{f.get('key')}:{len(f['losses'])}", "surface": f["position"].get("surface") or "nauvis",
                               "x": f["position"]["x"], "y": f["position"]["y"], "pieces": n, "t": f["losses"][-1]})
        self.threats.observe([dict(g, contact=self.group_contact(g)) for g in rows.values()], losses, now)
        bm = snapshot.get("basemap") or {}
        turrets = bm.get("turrets") if isinstance(bm.get("turrets"), list) and not (bm.get("turrets_read") or {}).get("capped") else None
        box = {"x0": bm["x0"], "y0": bm["y0"], "x1": bm["x0"] + bm["w"] * bm["cell"], "y1": bm["y0"] + bm["h"] * bm["cell"]} \
            if all(isinstance(bm.get(k), (int, float)) for k in ("x0", "y0", "w", "h", "cell")) else None
        for gid, g in rows.items():
            if gid in self.groups_seen:
                continue
            self.groups_seen.add(gid)
            if (g.get("surface") or "nauvis") != "nauvis":
                core_g, centre_g = None, None
            else:
                core_g, centre_g = core, centre
            # agents on the group's surface only: Sol by the egg breeders on Gleba at (46, 51) counted for any Nauvis
            # group heading near that spot, inside the base (13:00-13:40)
            near = [a for a in by_name.values() if surface_of(a) == (g.get("surface") or "nauvis")]
            score, parts = self.threats.score_group(g, centre=centre_g, agents=near, core=core_g,
                                                    turrets=turrets if (g.get("surface") or "nauvis") == "nauvis" else None, box=box)
            self.threats.learn_group(g, centre=centre_g)
            cur = self.state.get(self.onair) or {}
            blocked = None
            if not cfg["incoming"]:
                blocked = "incoming follow off"
            elif self.look or self.plat or self.fol or self.battle or self.incoming:
                blocked = "the camera is held (a follow, a battle or another group)"
            elif self.hold_layout or self.pending or segment or \
                    (cur.get("subject") in HOLDS and now < cur.get("until", 0)):
                blocked = "an urgent, segment or replay shot is on"
            elif now - self.last_incoming < cfg["incoming_spacing"]:
                blocked = f"spacing ({int(now - self.last_incoming)} s since the last followed group)"
            elif self.group_contact(g):
                blocked = "already attacking"
            if self.threats.decide("group", f"group:{gid}", score, parts, now, blocked=blocked):
                self.follow_group(g, score, scores, now)

    def group_contact(self, g):
        st = str(g.get("state") or "")
        near = g.get("nearest_distance")
        return st.startswith("attacking") or (near is not None and near <= self.cfg["incoming_contact"])

    def group_target(self, g, now, until):
        return {"agents": [], "subject": "@incoming", "position": {"x": g["position"]["x"], "y": g["position"]["y"]},
                "surface": g.get("surface") or "nauvis", "zoom": self.cfg["incoming_zoom"], "exact_zoom": True,
                "until": until, "incoming": f"Incoming · {g.get('label') or 'enemies on the way'}"}

    def follow_group(self, g, score, scores, now):
        self.incoming = {"id": g["id"], "since": now, "label": g.get("label"), "score": score,
                         "until": now + self.cfg["incoming_max"]}
        self.last_incoming = now
        self.urgent(self.group_target(g, now, self.incoming["until"]), f"incoming: {g.get('label')}", scores, now)

    def incoming_direct(self, snapshot, by_name, scores, now):
        """The followed group: pan with it; at contact the battle hold takes over at the same place (no cut); gone,
        past incoming_max, turned back or stopped short (not while it gathers): back to the story."""
        inc = self.incoming
        g = next((x for x in snapshot.get("incoming") or [] if x.get("id") == inc["id"]), None)
        cur = self.state.get(self.onair) or {}
        if self.pending:
            return  # the cut to it comes within ready_s
        def over(why):
            self.incoming = None
            if cur.get("subject") == "@incoming":
                cur["until"] = 0
            print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} incoming over ({why}): {inc['label']}",
                  flush=True)
        if not g or now >= inc["until"]:
            return over("gone" if not g else "too long")
        fight_near = any(now - self.fight_t(f) < self.cfg["fight_quiet"] and f.get("position") and
                         (f["position"].get("surface") or "nauvis") == (g.get("surface") or "nauvis") and
                         dist(f["position"], g["position"]) <= 40 for f in self.fight_list)
        if self.group_contact(g) or fight_near:
            # contact: the battle hold takes over where the camera already is
            f = {"key": f"group:{g['id']}", "kind": "attack", "text": g.get("label"), "first": now, "last": now,
                 "position": dict(g["position"], surface=g.get("surface") or "nauvis", extent=24)}
            b = self.start_battle(f, f"incoming (score {inc['score']})", by_name, now)
            b["group_label"] = g.get("label")
            b["last_attack"] = now
            if cur.get("subject") == "@incoming":
                cur.update(subject="@battle", battle=b["key"], until=0)
                cur.pop("incoming", None)
            self.incoming = None
            return
        # turned back (farther than incoming_away from its closest approach) or stopped (under incoming_still_tiles
        # in incoming_still seconds) before contact: back to the story
        near = g.get("nearest_distance")
        if near is not None:
            inc["closest"] = min(inc.get("closest", near), near)
            if near - inc["closest"] >= self.cfg["incoming_away"]:
                return over(f"turned back: {near:g} tiles from our nearest building, {inc['closest']:g} at closest")
        trail = inc["trail"] = [q for q in inc.get("trail", []) if now - q[0] <= self.cfg["incoming_still"]]
        trail.append((now, dict(g["position"])))
        if not str(g.get("state") or "").startswith("gathering") and len(trail) >= 3 and \
                now - trail[0][0] >= 0.8 * self.cfg["incoming_still"] and \
                all(dist(q[1], g["position"]) <= self.cfg["incoming_still_tiles"] for q in trail):
            return over(f"stopped: under {self.cfg['incoming_still_tiles']:g} tiles in {now - trail[0][0]:.0f} s")
        if cur.get("subject") == "@incoming":
            p = cur["position"]
            aim = lead_point(trail, self.cfg)
            if dist(p, aim) > 3:  # pan with it, ahead of it (cameras.lua eases a non-jump move)
                self.apply(self.slot(self.onair), dict(cur, position=aim, incoming=f"Incoming · {g.get('label')}", jump=False),
                           "incoming: pan", scores, now, quiet=True)

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

    # -- a big enemy on its way, in the inset ---------------------------------------------------------------------
    def threatened_on_air(self, e, by_name):
        """Is the program on what this enemy threatens: an agent on air (or followed, or fighting in the battle) on
        its surface within 120 tiles of the building it heads for, or the battle's area around that building."""
        target = e.get("nearest") or e.get("character")
        if not target:
            return False
        pt = {"x": target["x"], "y": target["y"], "surface": e.get("surface") or "nauvis"}
        if self.battle and self.in_battle(pt):
            return True
        cur = self.state.get(self.onair) or {}
        for n in [self.fol] + list(cur.get("agents") or []):
            a = by_name.get(n) or {}
            if a.get("position") and surface_of(a) == pt["surface"] and dist(a["position"], pt) <= 120:
                return True
        fr = frame_of(cur, self.onair_frac())
        return bool(fr) and in_frame(fr, pt, by_name, -60)

    def maybe_enemy_pip(self, snapshot, by_name, scores, now):
        """A demolisher closing on our buildings, at most enemy_eta away, while the program is on what it threatens:
        the inset follows it (a fixed view that pans with it), "Small demolisher · 120 tiles from Sol's gun turrets",
        the distance updating; gone at contact (the battle hold takes it), when it turns away, or when the program
        moves on. Alerts take the inset first (deaths, an agent under attack, real raids)."""
        cfg = self.cfg
        rows = {e["id"]: e for e in snapshot.get("big_enemies") or [] if e.get("id") is not None and e.get("position")}
        ins = self.inset
        if ins and ins.get("why") == "enemy":
            e = rows.get(ins["enemy"])
            if e and e.get("closing"):
                ins["closing_t"] = now
            why = ("gone" if not e else "contact" if (e.get("nearest_distance") or 1e9) <= cfg["enemy_contact"]
                   else "turned away" if now - ins.get("closing_t", now) >= cfg["enemy_away"]
                   else "the program moved on" if not self.threatened_on_air(e, by_name) else None)
            if why:
                self.inset = None
                print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} enemy inset over ({why}): "
                      f"{ins['label']}", flush=True)
                return
            t = self.state.get(ins["slot"]) or {}
            ins["until"] = now + 10
            ins["label"] = t["enemy"] = e.get("label") or ins["label"]
            if t.get("position") and dist(t["position"], e["position"]) > 3:  # pan with it
                self.apply(self.slot(ins["slot"]), dict(t, position=dict(e["position"]), jump=False, until=ins["until"]),
                           "enemy inset: pan", scores, now, quiet=True)
            return
        if not cfg["enemy_pip"] or self.mode == "trio" or self.hold_layout or self.pending or \
                (ins and ins.get("why") not in ("attention", "cue")):
            return
        for e in sorted(rows.values(), key=lambda e: e.get("eta_s") or 1e9):
            if not e.get("closing") or (e.get("eta_s") or 1e9) > cfg["enemy_eta"] or \
                    (e.get("nearest_distance") or 1e9) <= cfg["enemy_contact"] or not self.threatened_on_air(e, by_name):
                continue
            sb = self.standbys()
            slot = self.slot(ins["slot"]) if ins else (sb[-1] if len(sb) >= 2 else None)
            if not slot:
                return
            label = e.get("label") or human_enemy(e)
            target = {"agents": [], "subject": "@enemy", "position": dict(e["position"]),
                      "surface": e.get("surface") or "nauvis", "zoom": cfg["enemy_zoom"], "exact_zoom": True,
                      "until": now + 10, "enemy": label}
            self.frame_on(slot, target, f"enemy inset: {label}", scores, now)
            self.inset = {"slot": slot["slot"], "until": now + 10, "why": "enemy", "enemy": e["id"], "label": label,
                          "closing_t": now}
            print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} enemy inset: {label} "
                  f"(eta {e.get('eta_s')} s)", flush=True)
            return

    # -- spoken-line cues ----------------------------------------------------------------------------------------
    def cue_target(self, look, agent, who, until, by_name):
        """A look -> (target, label) or (None, why not): a platform's whole view, a spot or area framed like
        attention (on the look's surface, else the speaker's), or another agent followed."""
        if look.get("platform"):
            name = look["platform"]
            row = self.plat_rows.get(name) or {}
            if not (row.get("view") or {}).get("surface"):
                return None, f"no view of {name} yet"
            label = f"{who} · {self.platform_label(name)}"
            return self.platform_target(name, "cue", until, label=label), label
        if look.get("agent"):
            n = next((a["name"] for a in by_name.values()
                      if look["agent"].lower() in (a["name"].lower(), str(a.get("display_name") or "").lower())), None)
            if not n:
                return None, f"no agent {look['agent']}"
            tdisp = by_name[n].get("display_name") or n
            z = self.zoom_for(by_name[n], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            label = f"{tdisp} ({who} on the mic)"
            return {"agents": [n], "follow": n, "subject": "@work", "zoom": z, "until": until, "work": label}, label
        p = look.get("position")
        if not p or p.get("x") is None:
            return None, "no place in the look"
        speaker = by_name.get(agent) or {}
        surface = look.get("surface") or surface_of(speaker) if speaker else look.get("surface") or "nauvis"
        ext = look.get("extent") or 0
        z = min(self.cfg["attn_zoom"], Director.fight_zoom(self, ext)) if ext else self.cfg["attn_zoom"]
        label = f"{who} at ({round(p['x'])}, {round(p['y'])})"
        return {"agents": [agent] if agent in by_name else [], "subject": "@work",
                "position": {"x": p["x"], "y": p["y"]}, "surface": surface, "zoom": z, "exact_zoom": True,
                "until": until, "work": label}, label

    def cue_decision(self, agent, now, by_name, segment):
        """-> ("cut" | "inset" | "drop", why). Below urgent shots, battles, follows, incoming groups and segments
        (an inset then, or nothing), above routine rotation; spacing per agent and for all cues."""
        cfg = self.cfg
        cur = self.state.get(self.onair) or {}
        if now - self.cue_last.get(agent, -1e9) < cfg["cue_agent_gap"]:
            return "drop", f"spacing: {agent}'s last cue {int(now - self.cue_last[agent])} s ago"
        if now - self.last_cue < cfg["cue_gap"]:
            return "drop", f"spacing: the last cue {int(now - self.last_cue)} s ago"
        if self.hold_layout or self.mode == "trio":
            return "drop", "a replay or a trio is on air"
        busy = ("an operator look" if self.look else "an operator platform hold" if self.plat else "an operator follow" if self.fol else "a battle" if self.battle else "an incoming group" if self.incoming
                else "a segment" if segment else "an urgent shot" if self.pending or
                (cur.get("subject") in HOLDS and now < cur.get("until", 0)) else None)
        subj = cur.get("subject")
        if not busy and subj in by_name and (self.fighting(subj, by_name, now) or big_plan(by_name[subj])):
            busy = f"{subj} {'fighting' if self.fighting(subj, by_name, now) else plan_kind(by_name[subj])} on air"
        if not busy:
            return "cut", "nothing more interesting on air"
        if (self.inset and self.inset.get("why") not in ("attention", "cue", "departure")) or len(self.standbys()) < 2:
            return "drop", f"{busy}; no client free for an inset"
        return "inset", busy

    def maybe_cue(self, snapshot, by_name, scores, now, segment=None):
        """An agent's line that starts playing (snapshot voiced: the page's start report) with a look (say look=, or
        inferred: a platform named in it, one "(x, y)") is a cue: a cut to the look for the line plus cue_after if
        nothing more interesting is on, else the look in the inset, else nothing; each decision is logged."""
        cfg = self.cfg
        if not cfg["cues"]:
            return
        plats = [n for n, p in self.plat_rows.items() if (p.get("view") or {}).get("surface")]
        for v in snapshot.get("voiced") or []:
            cid = v.get("id")
            if not cid or cid in self.cues_seen:
                continue
            self.cues_seen.add(cid)
            agent, line = v.get("agent"), v.get("said") or v.get("text") or ""
            look = v.get("look") if isinstance(v.get("look"), dict) else None
            look = look or infer_look(line, plats)
            if not look:
                continue
            started = float(v.get("started") or now)
            until = started + min(float(v.get("duration") or 8.0), cfg["cue_max"]) + cfg["cue_after"]
            who = (by_name.get(agent) or {}).get("display_name") or v.get("speaker") or agent
            target, label = self.cue_target(look, agent, who, until, by_name)
            if not target:
                decision, why = "drop", label
            elif now - started > cfg["cue_late"]:
                decision, why = "drop", f"the line started {int(now - started)} s ago"
            else:
                decision, why = self.cue_decision(agent, now, by_name, segment)
            if decision == "cut":
                self.urgent(target, f"cue: {label}", scores, now)
            elif decision == "inset":
                slot = self.slot(self.inset["slot"]) if self.inset else self.standbys()[-1]
                self.frame_on(slot, target, f"inset cue: {label}", scores, now)
                self.inset = {"slot": slot["slot"], "until": until, "why": "cue"}
            if decision != "drop":
                self.cue_last[agent] = self.last_cue = now
            self.cues.append((now, agent, decision, label))
            entry = {"agent": agent, "look": look, "line": line[:120], "decision": decision, "why": why, "label": label}
            if self.log_path:
                with open(self.log_path, "a") as f:
                    f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                        "slot": "program", "reason": f"cue {decision}: {why}", "cue": entry}) + "\n")
            print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} cue {decision} ({why}): {label}"
                  f"{' (inferred)' if look.get('inferred') else ''}", flush=True)

    # -- artillery impacts --------------------------------------------------------------------------------------
    @staticmethod
    def arty_name(name):
        return str(name or "").replace("-", " ")

    def arty_label(self, sh, by_name):
        """'💥 Artillery · Opus's artillery turret (298, -320) → big spitter nest (398, -320), 100 tiles, with 1 medium
        worm turret'"""
        piece, t = sh.get("piece") or {}, sh.get("target") or {}
        by = sh.get("by") or piece.get("by")
        who = next((a.get("display_name") or a["name"] for a in by_name.values() if by and a["name"].lower() == str(by).lower()), by)
        pp, tp = sh.get("from") or piece.get("position") or {}, t.get("position") or {}
        text = (f"💥 Artillery · {who + chr(39) + 's' if who else 'Our'} {self.arty_name(piece.get('name') or 'artillery')} "
                f"({round(pp.get('x', 0))}, {round(pp.get('y', 0))}) → {self.arty_name(t.get('name'))} "
                f"({round(tp.get('x', 0))}, {round(tp.get('y', 0))})")
        if sh.get("distance"):
            text += f", {sh['distance']} tiles"
        if t.get("around"):
            text += f", with {self.arty_name(t['around'])}"
        return text

    def arty_busy(self, by_name, now, segment):
        """What outranks an artillery shot now, or None: an operator look, platform hold or follow, a battle, an
        incoming group, a segment, a replay or trio, an urgent shot (a death, a loss) held, a fight anywhere, or the
        agent on air fighting."""
        cur = self.state.get(self.onair) or {}
        busy = ("an operator look" if self.look else "an operator platform hold" if self.plat else
                "an operator follow" if self.fol else "a battle" if self.battle else
                "an incoming group" if self.incoming else "a segment" if segment else
                "a replay or a trio" if (self.hold_layout or self.mode == "trio") else
                "an urgent shot" if self.pending or (cur.get("subject") in HOLDS and now < cur.get("until", 0)) else
                "a fight" if any(now - self.fight_t(f) < self.cfg["fight_quiet"] for f in self.fight_list) else None)
        subj = cur.get("subject")
        if not busy and subj in by_name and self.fighting(subj, by_name, now):
            busy = f"{subj} fighting on air"
        return busy

    def maybe_artillery(self, snapshot, by_name, scores, now, segment=None):
        """A shell in flight (snapshot artillery: artillery_live's last read, read_at its wall time) -> a cut to its
        target if nothing outranks it and it lands at least arty_lead from now, at most once per arty_gap; held
        arty_after past the impact, longer (up to arty_max) while more shells land there. Each decision is logged."""
        cfg = self.cfg
        art = snapshot.get("artillery") or {}
        if not cfg["artillery"] or not art.get("shells"):
            return
        read_at = float(art.get("read_at") or now)
        cur = self.state.get(self.onair) or {}
        shot = cur.get("artillery") if now < cur.get("until", 0) else None
        for sh in art["shells"]:
            key = sh.get("key")
            t = (sh.get("target") or {}).get("position")
            if not key or not t or key in self.arty_seen:
                continue
            self.arty_seen.add(key)
            lands = read_at + float(sh.get("eta_ticks") or 0) / 60.0
            label = self.arty_label(sh, by_name)
            if shot:  # a shot on air: a shell landing beside its target holds it longer
                if sh.get("surface") == shot["surface"] and dist(t, shot["target"]) <= cfg["arty_near"]:
                    cur["until"] = min(shot["since"] + cfg["arty_max"], max(cur["until"], lands + cfg["arty_after"]))
                    shot["shells"] += 1
                continue
            lead = lands - now
            if lead < cfg["arty_lead"]:
                decision, why = "drop", f"lands in {lead:.1f} s"
            elif now - self.last_arty < cfg["arty_gap"]:
                decision, why = "drop", f"spacing: the last artillery shot {int(now - self.last_arty)} s ago"
            else:
                busy = self.arty_busy(by_name, now, segment)
                decision, why = ("drop", busy) if busy else ("cut", f"nothing more interesting on air; lands in {lead:.1f} s")
            if decision == "cut":
                shot = {"surface": sh.get("surface"), "target": t, "since": now, "shells": 1, "key": key}
                target = {"agents": [], "subject": "@work", "position": {"x": t["x"], "y": t["y"]},
                          "surface": sh.get("surface") or "nauvis", "zoom": cfg["arty_zoom"], "exact_zoom": True,
                          "until": min(now + cfg["arty_max"], lands + cfg["arty_after"]), "work": label, "artillery": shot}
                self.urgent(target, f"artillery: {label}", scores, now)
                if self.pending:  # framed on a standby: cut in time for the impact
                    self.pending["ready_s"] = max(0.2, min(cfg["ready_s"], lead - 0.5))
                self.last_arty = now
                # (d22 batch89 AY5) the next shells of this read hold the new shot, not the state that was on air
                # (shift57 07:50:12: KeyError 'until' on a state without one); urgent() keeps a copy, on air or on the
                # standby, sharing this shot
                cur = next((st for st in self.state.values() if isinstance(st, dict) and st.get("artillery") is shot), target)
            self.artys.append((now, decision, why, label))
            entry = {"key": key, "decision": decision, "why": why, "label": label, "lead": round(lead, 2)}
            if self.log_path:
                with open(self.log_path, "a") as f:
                    f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                        "slot": "program", "reason": f"artillery {decision}: {why}", "artillery": entry}) + "\n")
            print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} artillery {decision} ({why}): {label}", flush=True)
        if len(self.arty_seen) > 2000:
            self.arty_seen = set(list(self.arty_seen)[-500:])

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

    # -- pollution and spore clouds -----------------------------------------------------------------------------
    def watch_clouds(self, snapshot, now):
        """The snapshot's clouds; nests a cloud reached that were not in the last ones make it due (cloud_auto)."""
        rows = snapshot.get("clouds")
        if not isinstance(rows, list):
            return
        self.clouds = {r["surface"]: r for r in rows if r.get("surface") and r.get("cells")}
        keys = set()
        for r in self.clouds.values():
            keys |= clouds.reached_keys(r)
        if self.cloud_seen is None:
            if self.clouds:
                self.cloud_seen = keys
            return
        new = keys - self.cloud_seen
        self.cloud_seen |= keys
        if not new or not self.cfg["cloud_auto"] or now - self.last_cloud < self.cfg["cloud_every"]:
            return
        by = {}
        for k in new:
            by[k[0]] = by.get(k[0], 0) + 1
        surface = max(by, key=lambda k: by[k])
        self.cloud_due = {"surface": surface, "t": now, "nests": by[surface]}
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} cloud due: "
              f"{self.clouds[surface]['label']} reached {by[surface]} new nest(s)", flush=True)

    def cloud_pick(self, name=None):
        """A surface with a cloud by name (any case), or with none named: spores first (Gleba), else the biggest."""
        if name:
            n = str(name).strip().lower()
            return next((k for k in self.clouds if k.lower() == n or self.clouds[k]["label"].lower() == n), None)
        if not self.clouds:
            return None
        return max(self.clouds, key=lambda k: (self.clouds[k]["pollutant"] == "spores", self.clouds[k]["chunks"]))

    def request_cloud(self, surface=None, seconds=None, by=None, now=None):
        """The operator's cloud shot (serve.py POST /cloud) -> (http code, reply). It goes on air at the next step
        with nothing pinned on air (a segment, a key battle or a followed group: it waits, up to cloud_late)."""
        now = now or time.time()
        if self.looking(now):
            return 409, {"error": "an operator look is on air (DELETE /look first)"}
        p = self.platform_info(now)
        if p:
            return 409, {"error": f"an operator platform hold of {p['name']} is active (DELETE /platform first)"}
        f = self.follow
        if f and now < f["until"]:
            return 409, {"error": f"an operator follow of {f['agent']} is on air (DELETE /follow first)"}
        name = self.cloud_pick(surface)
        if not name:
            return 409 if not surface else 400, {
                "error": f"no cloud on {surface}" if surface else "no cloud read yet",
                "clouds": {k: {"label": c["label"], "chunks": c["chunks"], "max": c["max"]} for k, c in self.clouds.items()}}
        try:
            secs = max(5.0, min(120.0, float(seconds or self.cfg["cloud_hold"])))
        except (TypeError, ValueError):
            return 400, {"error": "seconds must be a number"}
        self.cloud_req = {"surface": name, "t": now, "seconds": secs, "by": str(by or "operator")[:40]}
        c = self.clouds[name]
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} {self.cloud_req['by']}: cloud shot "
              f"{c['label']} for {int(secs)} s", flush=True)
        return 200, {"surface": name, "label": c["label"], "seconds": int(secs), "chunks": c["chunks"], "max": c["max"],
                     "reached": len(c.get("reached") or [])}

    def cloud_target(self, surface, until, why):
        c = self.clouds.get(surface)
        sh = clouds.shot(c, frac=self.cfg["view_frac"]) if c else None
        if not sh:
            return None
        return {"agents": [], "subject": "@map", "map": True, "position": sh["position"], "surface": surface,
                "zoom": sh["zoom"], "exact_zoom": True, "until": until, "map_size": sh["size"],
                "cloud": {"surface": surface, "label": c["label"], "why": why}}

    def cloud_operator(self, scores, now, segment):
        req = self.cloud_req
        if not req:
            return
        if now - req["t"] > self.cfg["cloud_late"]:
            self.cloud_req = None
            return
        if segment or self.battle or self.incoming:
            return
        t = self.cloud_target(req["surface"], now + self.cfg["ready_s"] + req["seconds"], f"called by {req['by']}")
        if not t:
            return
        self.cloud_req = None
        self.cloud_shots.append((now, req["surface"], "operator"))
        self.urgent(t, f"cloud: {t['cloud']['label']} ({req['by']})", scores, now)

    def maybe_cloud(self, scores, now, segment=None):
        due = self.cloud_due
        if not due or len(self.slots) < 2 or self.mode != "onecam":
            return
        if now - due["t"] > self.cfg["cloud_late"]:
            self.cloud_due = None
            return
        cur = self.state.get(self.onair)
        if (self.hold_layout or self.pending or self.inset or self.trio_pending or segment or
                (cur and cur.get("subject") in HOLDS and now < cur.get("until", 0)) or
                now - self.last_program_cut < self.cfg["map_gap"] or
                any(now - self.fight_t(f) < self.cfg["fight_quiet"] for f in self.fight_list)):
            return
        why = f"reached {due['nests']} new nest" + ("s" if due["nests"] > 1 else "")
        t = self.cloud_target(due["surface"], now + self.cfg["ready_s"] + self.cfg["cloud_hold"], why)
        self.cloud_due = None
        if not t:
            return
        self.last_cloud = now
        self.cloud_shots.append((now, due["surface"], why))
        self.urgent(t, f"cloud: {t['cloud']['label']} {why}", scores, now)

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
        # (d20 batch50 F1, shift46 08:50:28 "Grok · Petrel · in orbit of in transit") between stops with no route read,
        # `where` is "in transit" (model.platform_where) while the state may still read as at a stop
        elif self.travelling(row) or row.get("where") in (None, "", "in transit"):
            text = f"{name} · in transit"
        else:
            text = f"{name} · in orbit of {row['where']}" + (" · paused" if row.get("paused") else "")
        if route and row.get("speed_kms"):
            text += f" · {row['speed_kms']} km/s"
        hp = (row.get("view") or {}).get("hub_health")
        if isinstance(hp, (int, float)) and hp < 100:
            text += f" · hub {round(hp)}%"
        return text

    def surface_platform(self, surface):
        """The platform whose surface a camera shows (an agent aboard), else None."""
        if not surface or surface == "nauvis":
            return None
        return next((n for n, r in self.plat_rows.items() if (r.get("view") or {}).get("surface") == surface), None)

    def ship_facts(self, name):
        """(d19 batch42 C1, viewer Foobator: "when a ship is shown ... where it is docked or from where to where it is
        flying, with what speed, and how far along it is on the trip") What the stream already reads of a platform
        (model.platform_where, the platforms read): {name, at} at a planet, else {name, from, to, pct, speed_kms};
        paused when it is."""
        row = self.plat_rows.get(name) if name else None
        if not row:
            return None
        out = {"name": name}
        route = row.get("route")
        if route:
            out.update({"from": route.get("from"), "to": route.get("to"), "pct": route.get("pct")})
            if row.get("speed_kms"):
                out["speed_kms"] = row["speed_kms"]
        elif row.get("where") and row["where"] != "in transit":
            out["at"] = row["where"]
        else:
            out["at"] = None  # in transit, the route not read
        if row.get("paused"):
            out["paused"] = True
        return out

    def watch_platforms(self, snapshot, now):
        """The snapshot's platforms; one that starts travelling (it was seen still) is a departure."""
        rows = [p for p in (snapshot.get("space") or {}).get("platforms") or [] if p.get("name")]
        if not rows and not snapshot.get("space"):
            return  # no space data in this snapshot (the director keeps what it saw)
        self.plat_rows = {p["name"]: p for p in rows}
        for p in rows:
            moving = self.travelling(p)
            if moving and self.plat_moving.get(p["name"]) is False and p.get("view") and \
                    not (self.departure and self.departure.get("maiden") and self.departure["name"] == p["name"]):
                news, route, why = self.departure_news(p["name"], p)
                d = {"name": p["name"], "t": now, "label": self.platform_label(p["name"], "departure"),
                     "news": news, "route": route, "why": why}
                print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} departure: "
                      f"{d['label']} ({'news' if news else 'routine'}: {why})", flush=True)
                old = self.departure  # (AS1) one departure waits at a time: news before routine, else the newer
                if old and not old.get("until") and (old.get("maiden") or old.get("news")) and not news:
                    self.log_departure(d, "none", f"{why}; {old['name']}'s departure is news and waits", now)
                else:
                    if old and not old.get("until") and "news" in old:
                        self.log_departure(old, "none", f"{old['why']}; {d['name']} left in the same read", now)
                    self.departure = d
            self.plat_moving[p["name"]] = moving

    EDGE_PLACES = {"solar-system-edge": "the solar system edge", "shattered-planet": "the shattered planet"}

    def departure_news(self, name, row):
        """(d22 batch83 AS1) -> (news, route, why) for a platform that starts travelling: news when the leg goes to or
        from the solar system edge or the shattered planet, to a planet the platform has not been at, or on a route
        (platform, from, to) it has not flown in depart_news_h game hours (this director's own record and the model's,
        route_source: space-memory.json and the chronicle along the run chain); else routine, "flown 41 min ago"."""
        from model import planet_label
        ids, r = row.get("route_ids") or [], row.get("route") or {}
        if len(ids) != 2:
            return False, None, "its route is not read"
        frm, to = ids
        route = (name, frm, to)
        text = f"{name} {r.get('from') or planet_label(frm)}->{r.get('to') or planet_label(to)}"
        tick = self.game_tick if self.game_tick is not None else None
        seen = self.route_ticks.setdefault(route, [])
        before = (tick if tick is not None else 0) - 2 * 3600  # (this departure's own records are newer)
        last = max((t for t in seen if t < before), default=None) if tick is not None else None
        src = self.route_source
        if src and tick is not None:
            m = src.route_last(name, frm, to, before)
            last = m if last is None or (m is not None and m > last) else last
        if tick is not None:
            seen.append(tick)
            del seen[:-4]
        edge = self.EDGE_PLACES.get(frm) or self.EDGE_PLACES.get(to)
        if edge:
            return True, route, f"{text}: a leg to or from {edge}"
        visited = src.platform_visited(name) if src else None
        if visited is not None and to not in visited:
            return True, route, f"{text}: {r.get('to') or planet_label(to)} is new to {name}"
        if last is None:
            return True, route, f"{text}: no flight on this route remembered"
        ago = (tick - last) / 60.0
        if ago > self.cfg["depart_news_h"] * 3600:
            return True, route, f"{text}: last flown {ago / 3600:.1f} h ago"
        return False, route, f"{text} flown {round(ago / 60)} min ago"

    def routine_turn(self, route, now, inset=False):
        """None when a routine departure may go on air now (inset: in the inset, AS2), else why not."""
        cfg = self.cfg
        shown, where = (self.routine_inset_t, "in the inset") if inset else (self.routine_main, "on air")
        every, route_every = (cfg["depart_inset_every"], cfg["depart_inset_route_every"]) if inset else \
            (cfg["depart_routine_every"], cfg["depart_route_every"])
        last = max((t for t, _ in shown), default=None)
        if last is not None and now - last < every:
            return f"a routine departure went {where} {round((now - last) / 60)} min ago"
        same = max((t for t, r in shown if r == route), default=None)
        if same is not None and now - same < route_every:
            return f"this route went {where} {round((now - same) / 60)} min ago"
        return None

    def log_departure(self, d, decision, why, now):
        self.departs.append((now, d["name"], decision, why))
        kind = "news" if d.get("news") else "routine"
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} departure {kind} ({decision}): {why}",
              flush=True)
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"departure {kind} ({decision}): {why}",
                                    "departure": {"name": d["name"], "label": d["label"], "news": bool(d.get("news")),
                                                  "decision": decision, "why": why}}) + "\n")

    def platform_target(self, name, why, until, agent=None, label=None):
        from model import platform_shot
        row = self.plat_rows.get(name) or {}
        view = row.get("view")
        if not view or not view.get("surface"):
            return None
        t = dict(platform_shot(view, travelling=self.travelling(row), frac=self.cfg["view_frac"]),
                 agents=[agent] if agent else [], subject="@platform", until=until,
                 platform={"name": name, "why": why, "label": label or self.platform_label(name, why)})
        if t.get("pan"):  # a tall ship: from the bow (pan_step)
            t["position"] = dict(t["position"], y=t["pan"]["y0"])
        if agent:
            t["platform"]["agent"] = agent
        return t

    def platform_following(self, now):
        p = self.platform_follow
        if p and now < p["until"]:
            return next((n for n, r in self.plat_rows.items() if n.casefold() == p["name"].casefold()
                         and (r.get("view") or {}).get("surface")), None)
        return None

    def platform_info(self, now):
        p = self.platform_follow
        return dict(p, remaining_s=max(0, int(p["until"] - now)), available=bool(self.platform_following(now))) \
            if p and now < p["until"] else None

    def operator_platform_target(self, by_name, now):
        """The platform explicitly held, or the ship the followed agent is actually aboard (not remote work)."""
        p = self.platform_follow
        if self.plat and p and now < p["until"]:
            label = self.platform_label(self.plat)
            if p.get("label"):
                label += f" · {p['label']}"
            t = self.platform_target(self.plat, "operator", p["until"], label=label)
            if t:
                t["platform"].update(by=p["by"], requested_label=p.get("label"))
            return t
        a = by_name.get(self.fol) or {}
        f = self.follow
        if not f or now >= f["until"] or not a or a.get("travel") in ("ascending", "descending"):
            return None
        name = next((n for n, p in self.plat_rows.items()
                     if (p.get("view") or {}).get("surface") == surface_of(a)), None)
        if name:
            label = f"{a.get('display_name') or self.fol} · aboard {self.platform_label(name)}"
            if f.get("label"):
                label += f" · {f['label']}"
            return self.platform_target(name, "follow", f["until"], agent=self.fol, label=label)
        return None

    PAN_END_S = 3.0    # a tall ship's pan rests this long at the bow and at the stern
    PAN_LEG_S = 40.0   # at most this long from bow to stern; a longer shot goes back and forth
    PAN_STEP = 2.0     # tiles: a whole-frame pan step (CG2: steps now go every DETAIL_STEP, gliding on; kept for the tests)

    DETAIL_STEP = 0.5  # tiles: a detail pan's step (d20 batch50 A2; cameras.lua glides between steps at its speed)
    # (d22 batch99 BI4, viewer Foobator site:4332) a long ship's whole-frame pan (model.LONG_VIEWS): a visit or an edge
    # shot holds until the pan has gone bow to stern at one view height in PAN_VIEW_S, at most PAN_HOLD_MAX; every
    # tall-ship pan glides (cameras.lua speed) between its steps
    PAN_VIEW_S = 10.0
    PAN_HOLD_MAX = 50.0

    def pan_hold(self, t):
        """Seconds a whole-frame pan needs to go bow to stern at one view height in PAN_VIEW_S, with its rests (0 for
        no pan or a detail pan)."""
        p = (t or {}).get("pan")
        if not p or p.get("speed") or not t.get("zoom"):
            return 0.0
        vh = 34.0 / t["zoom"]
        return min(self.PAN_HOLD_MAX, 2 * self.PAN_END_S + abs(p["y1"] - p["y0"]) * self.PAN_VIEW_S / vh)

    def pan_speed(self, t):
        """Tiles a second a pan moves at: a detail pan's speed, else its length over its leg."""
        p, since = t["pan"], t.get("since") if t.get("since") is not None else 0.0
        if p.get("speed"):
            return p["speed"]
        span = max(1.0, (t.get("until") or since + 20) - since)
        leg = max(4.0, min(self.PAN_LEG_S, span - 2 * self.PAN_END_S))
        return abs(p["y1"] - p["y0"]) / leg

    def pan_y(self, t, now):
        """Where a tall ship's view is along its pan (model.platform_shot `pan`) at `now`: at the bow for PAN_END_S, to
        the stern over the shot's time (at most PAN_LEG_S, then back), at the stern for PAN_END_S. A detail pan (d20
        batch50 A2: `speed`, `bow_s`) rests bow_s on the bow, then moves at its speed in tiles/s, rests PAN_END_S at the
        stern and comes back the same way: a short shot shows the bow and part of the hull."""
        p, since = t["pan"], t.get("since") if t.get("since") is not None else now
        rest0 = rest1 = self.PAN_END_S
        if p.get("speed"):
            rest0, leg = p.get("bow_s", rest0), max(1.0, abs(p["y1"] - p["y0"]) / p["speed"])
        else:
            span = max(1.0, (t.get("until") or since + 20) - since)
            leg = max(4.0, min(self.PAN_LEG_S, span - 2 * self.PAN_END_S))
        cycle = 2 * leg + rest0 + rest1
        x = (now - since) % cycle
        f = 0.0 if x < rest0 else min(1.0, (x - rest0) / leg) if x < rest0 + leg + rest1 \
            else max(0.0, 1.0 - (x - rest0 - rest1 - leg) / leg)
        f = f * f * (3 - 2 * f)  # (d23 batch124 CG2) eased: each leg starts and stops gently, not at full speed
        return round(p["y0"] + (p["y1"] - p["y0"]) * f, 1)

    # (d23 batch124 CG2, Nick 10:00: "the panning across spaceships could be a little better") the director steps
    # every 1.1-1.5 s (director logs d23 07:55-10:10: 2637 ship reframes, 6.7 tiles a step at a glide of 6.77 tiles/s)
    # and each step's glide (1.15x the pan's speed) ended in about 1.0 s: the view moved, stopped, moved. Each step now
    # aims where the pan will be PAN_LEAD step intervals on (the interval measured, PAN_DT at first) and glides there
    # over that time, so the next step comes while it still moves: one even motion, eased at the ends (pan_y).
    PAN_LEAD = 1.5
    PAN_DT = 1.2

    def pan_step(self, now):
        """(d19 batch42 C2) Each camera holding a tall ship (a `pan` in its target) moves along it, bow to stern."""
        last = getattr(self, "_pan_at", None)
        if last is not None and 0.3 <= now - last <= 5:
            self._pan_dt = 0.7 * getattr(self, "_pan_dt", self.PAN_DT) + 0.3 * (now - last)
        self._pan_at = now
        ahead = self.PAN_LEAD * getattr(self, "_pan_dt", self.PAN_DT)
        for slot in self.slots:
            t = self.state.get(slot["slot"])
            if not t or not t.get("pan") or not t.get("position") or now >= t.get("until", now + 1):
                continue
            y = self.pan_y(t, now + ahead)
            ends = (t["pan"]["y0"], t["pan"]["y1"])
            if abs(y - t["position"]["y"]) >= self.DETAIL_STEP or (y in ends and y != t["position"]["y"]):
                target = {k: v for k, v in t.items() if k != "jump"}
                target["position"] = dict(t["position"], y=y)
                # cameras.lua moves at this speed: it reaches y as the step after next would come
                target["glide"] = round(max(0.5, abs(y - t["position"]["y"]) / ahead), 2)
                self.apply(slot, target, "reframe", {}, now, quiet=True)

    @staticmethod
    def same_platform(a, b):
        ap, bp = (a or {}).get("platform") or {}, (b or {}).get("platform") or {}
        return bool(ap and bp) and all(ap.get(k) == bp.get(k) for k in ("name", "why", "agent")) and \
            a.get("surface") == b.get("surface")

    def platform_direct(self, shot, scores, now):
        """Hold a whole-ship view; refresh its bounds and flight framing without repeated cuts or commands."""
        if not shot:
            return
        name = shot["platform"]["name"]
        if self.departure and self.departure["name"] == name:
            self.departure = None  # this departure is already being shown, not another visit after the hold
        self.plat_shown[name] = self.last_platform = now
        self.pending = None
        cur = self.state.get(self.onair)
        if self.same_platform(cur, shot):
            slot, t = self.slot(self.onair), cur
        else:
            slot = self.next_slot() or self.slot(self.onair)
            t = self.state.get(slot["slot"])
        if not self.same_platform(t, shot):
            self.frame_on(slot, shot, f"standby: {shot['platform']['label']}", scores, now)
            if slot["slot"] == self.onair:
                self.onair_since, self.resume = now, None
        else:
            if t.get("pan") and t.get("pan") == shot.get("pan"):  # a tall ship's pan moves the view: not a new frame
                shot = {k: v for k, v in shot.items() if k != "position"}
            changed = any(t.get(k) != shot.get(k) for k in ("position", "zoom", "surface", "pan") if k in shot)
            t.update(shot)
            if changed:
                self.apply(slot, dict(t, jump=slot["slot"] != self.onair), "reframe", scores, now, quiet=True)
        if slot["slot"] != self.onair and self.ready(slot["slot"], now):
            self.cut(slot["slot"], f"platform {shot['platform']['why']}: {shot['platform']['label']}", now)
            self.resume = None

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

    def maybe_danger(self, scores, now, segment=None):
        """A platform in danger (its card's danger, model.platform_danger) gets the whole-platform view, labelled with the
        reason ("Wayfarer under fire: 3 buildings lost", "Wayfarer ammo for 2 min"). Under fire it holds until
        danger_hold after the latest hit or loss (at most danger_max), then the story comes back; ammo running out holds
        ammo_hold. It takes the camera from a platform visit, work or departure, not from an operator hold or follow, a
        battle or incoming group (step: pinned), an urgent attack shot, a segment, a replay or a cut being framed; the
        same platform again after danger_gap, sooner when its danger got worse (more lost, a hurt hub, less ammo time)."""
        cfg = self.cfg
        cur = self.state.get(self.onair)
        cp = (cur or {}).get("platform") or {}
        rows = {n: p for n, p in self.plat_rows.items() if p.get("danger") and (p.get("view") or {}).get("surface")}
        if cp.get("why") == "danger" and now < cur.get("until", 0):
            d = (rows.get(cp["name"]) or {}).get("danger")
            if d and d.get("kind") == "fire" and cp.get("kind") == "fire":
                cur["until"] = max(cur["until"], min(d["last"] + cfg["danger_hold"], cur.get("since", now) + cfg["danger_max"]))
            if d:
                cp["label"] = d["reason"]
                self.danger_seen[cp["name"]] = (now, d.get("level", 0))
            return
        if not rows or len(self.slots) < 2:
            return
        busy = bool(self.hold_layout or self.pending or self.trio_pending or segment or
                    (cur and now < cur.get("hold_until", 0)) or
                    (cur and cur.get("subject") in HOLDS and now < cur.get("until", 0) and
                     not (cur.get("subject") == "@platform" and cp.get("why") in ("visit", "work", "departure", "cue", "edge"))))
        if busy:
            return
        def live(n):
            d = rows[n]["danger"]
            return d.get("kind") != "fire" or now - d.get("last", 0) <= cfg["danger_hold"]
        def fresh(n):
            seen = self.danger_seen.get(n)
            d = rows[n]["danger"]
            return not seen or now - seen[0] >= cfg["danger_gap"] or d.get("level", 0) > seen[1]
        pick = sorted((n for n in rows if live(n) and fresh(n)),
                      key=lambda n: (rows[n]["danger"].get("kind") != "fire", -rows[n]["danger"].get("level", 0), n))
        if not pick:
            return
        name = pick[0]
        d = rows[name]["danger"]
        hold = cfg["danger_hold"] if d["kind"] == "fire" else cfg["ammo_hold"]
        t = self.platform_target(name, "danger", now + cfg["ready_s"] + hold, label=d["reason"])
        if not t:
            return
        t["platform"]["kind"] = d["kind"]
        self.danger_seen[name] = (now, d.get("level", 0))
        if cp.get("why") == "departure" and now < cur.get("until", 0):
            # the departure comes back after (urgent's rule for an urgent shot), for what is left of it
            self.departure = {"name": cp["name"], "t": now, "label": cp["label"], "until": cur["until"],
                              "maiden": cp.get("maiden")}
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} platform danger: {d['reason']}", flush=True)
        self.show_platform(t, scores, now)

    def maybe_edge(self, scores, now, segment=None):
        """(d20 batch57 S3, viewer Foobator, shift48 17:40: "if a ship reaches the dense part of edge asteroids, can you
        switch to it?") A platform flying a leg to or from the solar system edge that enters the leg's dense part
        (edgedense.py: where big and huge asteroids' hit points per unit of travel reach 80% of the leg's peak; Aquilo
        to the edge from 40% of the way) is shown once per leg as an urgent platform shot, as a platform in danger is:
        platform_hold, framed for its guns' reach (model.platform_shot), labelled "Bastion · dense asteroids near the
        solar system edge". It waits while the camera is busy as maybe_danger does, and a danger shot takes it over."""
        import edgedense
        cfg = self.cfg
        due = []
        for name, row in self.plat_rows.items():
            lg = edgedense.leg(row)
            if not lg:
                self.edge_legs.pop(name, None)  # arrived, or another leg: the next edge leg counts again
                continue
            st = self.edge_legs.get(name)
            if not st or st["leg"] != lg:
                st = self.edge_legs[name] = {"leg": lg, "shown": False}
            if not st["shown"] and edgedense.in_dense(row) and (row.get("view") or {}).get("surface"):
                due.append(name)
        if not due or len(self.slots) < 2:
            return
        cur = self.state.get(self.onair)
        cp = (cur or {}).get("platform") or {}
        busy = bool(self.hold_layout or self.pending or self.trio_pending or segment or
                    (cur and now < cur.get("hold_until", 0)) or
                    (cur and cur.get("subject") in HOLDS and now < cur.get("until", 0) and
                     not (cur.get("subject") == "@platform" and cp.get("why") in ("visit", "work", "departure", "cue"))))
        if busy:
            return
        name = sorted(due)[0]
        label = f"{name} · dense asteroids near the solar system edge"
        t = self.platform_target(name, "edge", now + cfg["ready_s"] + cfg["platform_hold"], label=label)
        if t and self.pan_hold(t) > cfg["platform_hold"]:  # (BI4) a long ship: bow to stern within the shot
            t["until"] = now + cfg["ready_s"] + self.pan_hold(t)
        if not t:
            return
        t["platform"]["kind"] = "edge"
        self.edge_legs[name]["shown"] = True
        if cp.get("why") == "departure" and now < cur.get("until", 0):
            self.departure = {"name": cp["name"], "t": now, "label": cp["label"], "until": cur["until"],
                              "maiden": cp.get("maiden")}
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} platform edge: {label} "
              f"({self.plat_rows[name]['route'].get('pct')}%)", flush=True)
        self.show_platform(t, scores, now)

    def maybe_departure(self, scores, now, segment=None):
        """A departure seen (watch_platforms, watch_maiden): a maiden flight or news on air for depart_hold (maiden_hold);
        a routine one (AS1) on air for depart_routine_hold when routine_turn allows, else in a free inset, else not
        shown. One that comes back after an urgent shot (it has `until`) was decided already."""
        d = self.departure
        if not d or (len(self.slots) < 2 and not d.get("maiden")):  # one camera: only a maiden flight
            return
        routine = "news" in d and not d.get("news") and not d.get("maiden") and not d.get("until")
        if (now > d["until"] - self.cfg["platform_hold"] / 2) if d.get("until") else now - d["t"] > self.cfg["depart_late"]:
            self.departure = None  # a replay or an urgent shot was in the way the whole time: the moment has passed
            if "news" in d and not d.get("until"):
                self.log_departure(d, "none", f"{d['why']}; the camera was busy for {self.cfg['depart_late']:.0f} s", now)
            return
        hold = self.cfg["depart_routine_hold"] if routine else self.cfg["depart_hold"]
        cur = self.state.get(self.onair)
        if cur and cur.get("platform", {}).get("name") == d["name"] and now < cur.get("until", 0) and not self.pending:
            if cur["platform"].get("why") == "edge" and not d.get("maiden"):
                self.departure = None  # (d20 batch57 S3) its edge shot is on air: that label stays
                return
            maiden = d.get("maiden") or cur["platform"].get("maiden")  # (a plain departure never relabels a maiden)
            cur["until"] = max(cur["until"], d["until"] if d.get("maiden") else now + hold)
            cur["platform"] = dict(cur["platform"], why="departure", maiden=maiden or None,
                                   label=d["label"] if d.get("maiden") or not maiden else cur["platform"]["label"])
            self.departure = None  # on air already (a visit, or the maiden flight's card on the same ship): stay
            if "news" in d and not d.get("until"):
                self.log_departure(d, "main", f"{d['why']}; already on air", now)
            return
        if routine:
            busy = self.routine_turn(d["route"], now)
            if busy:
                self.departure = None
                self.routine_inset(d, f"{d['why']}; {busy}", scores, now, segment)
                return
        if self.plat_busy(now, segment) and not (cur and cur.get("subject") == "@map"):
            return  # (the base map gives way to a departure)
        t = self.platform_target(d["name"], "departure", d.get("until") or now + self.cfg["ready_s"] + hold,
                                 label=d["label"])
        self.departure = None
        if t:
            if d.get("maiden"):
                t["platform"]["maiden"] = True
            if routine:
                self.routine_main.append((now, d["route"]))
            if "news" in d and not d.get("until"):
                self.log_departure(d, "main", d["why"], now)
            self.show_platform(t, scores, now)

    def routine_inset(self, d, why, scores, now, segment=None):
        """(AS1) A routine departure off the main camera: in the inset for depart_routine_hold when no inset is up and
        nothing holds the program (a replay, a trio, a segment, a cut being framed), at most once per depart_inset_every
        and once per depart_inset_route_every for its route (AS2); else not shown."""
        cur = self.state.get(self.onair) or {}
        sb = self.standbys()
        busy = ("routine departures not in the inset (depart_inset)" if not self.cfg["depart_inset"]
                else self.routine_turn(d["route"], now, inset=True))
        busy = busy or ("an inset is up" if self.inset else "a replay or a trio" if self.hold_layout or self.mode != "onecam"
                else "a segment" if segment else "a cut being framed" if self.pending or self.trio_pending
                else "the ship is on air" if (cur.get("platform") or {}).get("name") == d["name"]
                else "no client free for an inset" if len(sb) < 2 else None)
        until = now + self.cfg["ready_s"] + self.cfg["depart_routine_hold"]
        t = None if busy else self.platform_target(d["name"], "departure", until, label=d["label"])
        if not t:
            self.log_departure(d, "none", f"{why}; {busy or 'no view of the ship'}", now)
            return
        self.frame_on(sb[-1], t, f"inset departure: {d['label']}", scores, now)
        self.inset = {"slot": sb[-1]["slot"], "until": until, "why": "departure", "platform": d["name"]}
        self.routine_inset_t.append((now, d["route"]))
        self.log_departure(d, "inset", why, now)

    def watch_maiden(self, snapshot, now):
        """A maiden flight (model.py moment maiden_flight: a platform's first departure since it was built): the
        departure is held maiden_hold, captioned "Swiftlet · maiden flight · Nauvis to Aquilo · built by Luna", and shown
        with one camera too. It ranks as a departure: below an operator look, platform hold or follow, a battle, an
        urgent shot, a segment (its own space_moment card comes first) and a platform in danger; once per platform."""
        for m in (snapshot.get("space") or {}).get("moments") or []:
            if m.get("kind") != "maiden_flight" or m.get("id") in self.maiden_done:
                continue
            self.maiden_done.add(m.get("id"))
            f = m.get("facts") or {}
            name = f.get("platform")
            if not name or now - m.get("t", now) > self.cfg["maiden_late"] or \
                    not ((self.plat_rows.get(name) or {}).get("view") or {}).get("surface"):
                continue
            label = " · ".join(x for x in (name, "maiden flight", " to ".join(p for p in (f.get("from"), f.get("to")) if p),
                                           f"built by {f['built_by']}" if f.get("built_by") else None) if x)
            until = now + self.cfg["ready_s"] + self.cfg["maiden_hold"]
            cur = self.state.get(self.onair)
            cp = (cur or {}).get("platform") or {}
            if cp.get("name") == name and now < cur.get("until", 0) and cp.get("why") in ("departure", "visit"):
                cur["until"] = max(cur["until"], until)  # its departure is on air already: it becomes the maiden flight
                cur["platform"] = dict(cp, why="departure", maiden=True, label=label)
                if self.departure and self.departure["name"] == name:
                    self.departure = None
            else:
                self.departure = {"name": name, "t": now, "label": label, "until": until, "maiden": True}
            print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} maiden flight: {label}", flush=True)

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
        if t and self.pan_hold(t) > cfg["platform_hold"]:  # (BI4) a long ship: bow to stern within the shot
            t["until"] = now + cfg["ready_s"] + self.pan_hold(t)
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
        due = self.surface_due
        blocked = (self.hold_layout or self.pending or self.inset or subj not in scores or
                   self.fighting(subj, by_name, now) or
                   (due and self.balance_surface(by_name.get(subj)) != due["surface"]) or
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
        if not self.trio:  # maybe_departure left the trio earlier in this step (01:55: TypeError on None)
            return
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
        # A new planet under its floor (surface_factors): its agents are the story. On air there already, the story
        # stays among them; elsewhere, its best-scoring agent is next (dwell rules first).
        due, floor_reason = self.surface_due, None
        if due:
            here = [n for n in ranked if self.balance_surface(by_name.get(n)) == due["surface"]
                    and n not in inset_agents and n not in blocked]
            if here or (subj in scores and self.balance_surface(by_name.get(subj)) == due["surface"]):
                floor_reason = f"new planet {due['surface']} {due['share']}% of {due['target']}%"
                if subj in scores and self.balance_surface(by_name.get(subj)) == due["surface"]:
                    others = [n for n in here if n != subj]
                else:
                    others = here
        cand = others[0] if others else None
        want = None
        resumed = None
        if need:
            r, self.resume = self.resume, None
            if r and r["subject"] in scores and r["subject"] not in inset_agents and \
                    subj in (None, "@attack", "@segment", "@map", "@platform", "@battle", "@incoming", "@work", "@look") and \
                    not (floor_reason and r["subject"] not in others):
                want, resumed = r["subject"], r  # back to the story the urgent shot interrupted
                self.resume = r  # kept until the cut back happens
            elif floor_reason and others:
                want = others[0]  # a new planet under its floor: its best-scoring agent
            else:
                want = ranked[0] if ranked else None
            if want is None:
                return
        else:
            held = now - self.onair_since
            cfg = self.cfg
            holding = (big_plan(by_name[subj]) and held < cfg["plan_hold"]) or \
                self.fighting(subj, by_name, now)  # its big action runs, or it fights: stay
            away = floor_reason and self.balance_surface(by_name.get(subj)) != due["surface"]
            if cand and away and not holding and held >= cfg["onair_dwell"] and \
                    now - self.last_program_cut >= cfg["cut_spacing"]:
                want, reason = cand, floor_reason  # the new planet's turn, whatever the scores
            elif cand and not holding and held >= cfg["onair_dwell"] and now - self.last_program_cut >= cfg["cut_spacing"]:
                if scores[cand] > scores[subj] * cfg["switch_margin"] + cfg["switch_bias"]:
                    want = cand
                    reason = f"{cand} {scores[cand]} beats {subj} {scores[subj]}" + \
                        (f" ({plan_kind(by_name[cand])} ahead)" if big_plan(by_name[cand]) else "") + \
                        self.surface_note(cand, by_name)
                elif held >= cfg["onair_max"] and scores[cand] >= scores[subj] * cfg["rotate_ratio"]:
                    want = cand
                    reason = f"rotate after {int(held)} s" + self.surface_note(cand, by_name)
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
            self.cut(nxt["slot"], reason if not need else f"back to {want}" if resumed else floor_reason if floor_reason
                     and self.balance_surface(by_name.get(want)) == due["surface"] else
                     (f"{subj} unavailable" if subj else "initial") + self.surface_note(want, by_name), now)
            self.want[nxt["slot"]] = (self.state[nxt["slot"]]["zoom"], now)
            if resumed:
                self.resume = None
                self.onair_since = max(resumed["since"], now - self.cfg["onair_dwell"] + self.cfg["resume_min"])
        elif want and not nxt:  # one client only (POG_CAMS=1): the cut is a jump of the client on air to the subject
            fit = self.plan_zoom(by_name[want])
            z = fit or self.zoom_for(by_name[want], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            shot = {"agents": [want], "follow": want, "zoom": z, "solo_zoom": z, "subject": want}
            if fit:
                shot.update(exact_zoom=True, plan_fit=fit)
            why = reason if not need else f"back to {want}" if resumed else floor_reason if floor_reason \
                and self.balance_surface(by_name.get(want)) == due["surface"] else \
                (f"{subj} unavailable" if subj else "initial") + self.surface_note(want, by_name)
            self.retarget(shot, why, scores, now)
            if resumed:
                self.resume = None
                self.onair_since = max(resumed["since"], now - self.cfg["onair_dwell"] + self.cfg["resume_min"])

    def keep(self, cur, by_name, now):
        """Zoom follows the on-air subject's activity once it has lasted zoom_settle (no pairs on air); while a big
        action with bounds runs, the zoom fits them."""
        subj = cur["subject"]
        # (BC2) its spidertron fires: framed to its farthest target while it does, then back to the activity's zoom
        fire = self.fire_zoom(by_name[subj])
        if fire or cur.get("fire_fit"):
            if fire and cur.get("fire_fit") and abs(fire - cur["fire_fit"]) < self.cfg["zoom_delta"]:
                return  # fitted already
            target = {k: v for k, v in cur.items() if k not in ("jump", "exact_zoom", "fire_fit")}
            if fire:
                target.update(zoom=fire, exact_zoom=True, fire_fit=fire)
                reason = f"zoom {fire} ({self.fire_text(by_name[subj])})"
            else:
                z = self.zoom_for(by_name[subj], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
                target.update(zoom=z, solo_zoom=z)
                reason = "zoom (its spidertron stopped firing)"
            self.apply(self.slot(self.onair), target, reason, {}, now)
            return
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
                row["map_view"] = {"position": t.get("position"), "surface": t.get("surface") or "nauvis",
                                   # the zoom sent (director.apply rounds it): the overlay's cloud layer
                                   "zoom": t.get("game_zoom") or t["zoom"], "size": t.get("map_size")}
                if t.get("cloud"):  # a cloud shot: "Spores on Gleba" (the overlay draws its cells)
                    row["map"] = t["cloud"]["label"]
                    row["cloud"] = t["cloud"]
            ship = self.ship_facts((t.get("platform") or {}).get("name") or self.surface_platform(t.get("surface")))
            if ship:  # (d19 batch42 C1) the overlay's ship card: where it is or its route, progress, speed
                row["ship"] = ship
            if t.get("platform"):  # {name, why, label, agent?}: a visit and a work shot read the latest row
                p = dict(t["platform"])
                if p["why"] == "visit":
                    p["label"] = self.platform_label(p["name"])
                row["platform"] = p
                if t.get("work"):
                    row["work"] = t["work"]  # the page: "Astra · working on Starling"
            if t.get("attention"):  # the inset on where the agent on air is looking: "Sol · placing ghosts 40 m north"
                row.update(work=t["work"], attention=t["attention"])
            elif t.get("subject") == "@work" and t.get("work"):  # a spoken-line cue: "Sol · at (120, -40)"
                row["work"] = t["work"]
            if t.get("subject") == "@enemy" and t.get("enemy"):  # "Small demolisher · 120 tiles from Sol's gun turrets"
                row["enemy"] = t["enemy"]
            if key == "main" and t.get("subject") == "@incoming" and t.get("incoming"):
                row["incoming"] = t["incoming"]  # "Incoming · 38 biters and spitters heading for the oil field"
            if key == "main" and self.battle and t.get("battle") == self.battle["key"]:
                row["battle"] = self.battle["label"]  # "Sol in battle · 44 lost near (-237, 64): 40 gun turret ..."
            if key == "main" and t.get("subject") == "@look" and t.get("look"):
                row["look"] = t["look"]  # the on-air card: "📍 The western wall" (lookcam.py)
            f = self.follow
            if key == "main" and f and f["label"] and now < f["until"] and f["agent"] in (t.get("agents") or []):
                row["follow"] = f["label"]  # the on-air card: "Following Sol · Sol vs the Demolisher"
            out[key] = row
        return out
