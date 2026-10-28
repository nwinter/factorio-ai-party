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
  - a ship flying a leg to or from the solar system edge or the shattered planet (d24 batch170 QM1, viewer Caleb: "show
    a view of the front of Asterion when it is in flight for a few seconds"; bow_turn): at a story turn, at most once a
    round (every agent on air in the last `bow_window` had a story since the last one, or `bow_round_max`; at least
    `bow_gap` apart), its bow for `bow_hold` (8 s): a fixed view, the bow's width across, the hull's north edge
    `bow_ahead` down the frame, labelled "Asterion · the bow · travelling to Aquilo (21%) · 57 km/s"; then the story
    goes to the agent the turn was for ("after the bow: luna"). The bow comes from the foundation tiles (live.py
    add_hulls). One camera or three; a danger or edge shot takes it over;
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
- Loops, fresh events, quiet time, remote vehicles (d26 batch222 CD, viewers Aurora and Caleb; ONECAM loop_*, fresh_*,
  quiet_*, tour_*, vehicle_*): an agent walking a short loop scores down by half a minute and counts as standing
  still; a new kind of action, a big action starting, a remote vehicle setting off or new ground scores up, and such a
  fresh agent takes a stale story after still_min; with every story stale, a quiet view goes on air (a base tour of a
  planet, basetour.py, chart-checked, a slow camera move; a platform visit; the base map), then the best lively agent;
  an agent driving a vehicle by remote view is shown where the vehicle is. airtime.py measures a log; director_replay.py
  replays one through these rules.
- Flare barrages and spider raids (d26 batch224 AY/VS, viewer Aurora 05:29; ONECAM arty_*, vehicle_keep, vehicle_flip):
  a shell from artillery_live is judged arty_pre before it lands; the shot holds while the barrage's shells land there
  (or are flared by the same agent), up to arty_max, its frame on the impacts due next; arty_gap counts from its end.
  A remote vehicle walking, firing or near a fight keeps its agent active and on the vehicle while that lasts.
- A remote vehicle where it is (d26 batch232 VC, viewer Aurora site:5020; ONECAM vehicle_ahead, vehicle_glide): the
  service's live read of the vehicles (harness VEHICLES_LUA) places it; the view aims ahead and glides at least at its
  speed; a unit belongs to the agent who called it last; a vehicle/character switch keeps the story's dwell.
- Builds and idle air (d26 batch240 IA; ONECAM did_hold, did_zoom, fresh_min, quiet_min, quiet_story, quiet_gap): an
  agent's build, paste, deconstruction or silo load from its journal (`did`, work.DidFeed) is a fresh event and an act,
  its spot the shot when away from the character; its clocks' idle seconds (`idle_s`, work.ClockFeed) make it still.
  Back from an urgent or timed shot, fresh news first and no story standing still while another acts; the surface
  bonus only for an agent doing something; a quiet view gives way to fresh news.
- Battles, groups, walk loops (d26 batch245 MB; ONECAM battle_all, battle_gap, battle_repeat, group_pip*, loop_queue):
  every attack on our buildings, vehicles or agents on a planet is a battle on air within seconds unless an operator
  look holds the camera (a spidertron's is its vehicle shot); fights elsewhere follow on, the same area resumes or,
  repeated with nothing lost, is an inset; a group not followed is the inset until contact; a repeating queue's walk
  is a loop whatever its size.
- A remote vehicle's shot (d26 batch245 SP; ONECAM vehicle_stuck, vehicle_progress, vehicle_still_box, vehicle_obs,
  vehicle_settle): framed on its standby before the cut, dwell counted while it is in the frame, the lead no faster
  than the reads saw it go, along the reply's route (cp3) and inside the frame's inner box, a stop inside that box
  holds the frame; a vehicle stuck
  vehicle_stuck s (no fight, no fire) has served its dwell and counts as standing; moving on again is news.
- Rocket launches (d26 batch257 IB, viewer Aurora site:5029/5030; ONECAM launch_*, trio_busy_lively): a story standing
  still launch_still s with nobody else moving or with news, and a silo ordered to launch (launches.py, the silos read
  every poll): the silo, framed and cut before lift-off, held through the flight, then the story; silos of a planet
  launching together share the frame. A busy trio only of agents doing something; a check-in trio gives way to news.
- Builds and repeated platform views (d27 batch267 LB, shift85: 11 of 23 builds late, Sol's Loom 25x; ONECAM
  work_build_*, work_repeat, work_spot_zoom): a build on a platform is news work_build_fresh and takes the camera after
  work_build_min (no dwell, no score ratio) from a story without its own news, a tour, the map, a platform view, a
  launch or an inspection, and from a trio; no launch starts while one waits; a build on the ground makes the same
  views give way. A platform aired for work within work_repeat comes back only for a build, closer on where it landed.
- Build close-ups (d28 batch312 A, viewer Aurora 10:47; work_overview_s, work_close_*): a build that names where it
  lands (its entries, area or position) opens on the whole ship for work_overview_s on a first visit, its caption
  saying where the work is, then glides to the work at a zoom that fits the request's box (0.6 to 0.9); a repeat goes
  to the work at once. The caption names what the request names and where on the ship (bow north). With one client
  (camera panels) a build moves it there too; inspections and the like stay off with one client.
- Operation stories (d28 batch312 B, viewer Aurora 10:48; story_*, stories.py): an agent's flight watch starting and
  its result, each once: the ship on air story_hold with the question and the team's handoff from the board (or the
  result: passed, failed or still pending, with its reason), the agent who set it in the inset once the ship is up; a
  result goes back to the spot last built on. It waits for a free moment as a build does.
- public(): "main" is the camera on air and "inset" the inset while it is up (what viewers see), so the overlay,
  model.py, replays.py, the casters and push_live keep reading cameras.main; in a trio also "cam2" and "cam3", the
  small tiles. program() is what cuts.py applies: which client is on air and which, if any, is the inset; the layout
  ("onecam" or "trio") and, in a trio, which client is in which hole.
"""
import json, math, os, re, time

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
BOW_REACH_MARGIN = 4.0  # (d24 batch188) tiles past the guns' reach the bow shot shows, ahead and on each side


LOOP_STEPS = {"move_to", "walk", "wait_ticks", "wait_until"}


def queue_walk_loop(a):
    """(d26 batch245 MB) The agent's body queue repeats (queue_repeat; the status read's queues.body.repeating) and
    walks or waits now (between rounds nothing runs): a walk loop, whatever its size. Grok's "ag-tour" of shift81
    (800 rounds over 66 x 32 tiles) passed loop_span 64 whenever two polls caught its ends, so batch240's stale rules
    saw it as moving. A repeating queue that mines, builds or crafts is work, not a loop."""
    q = (a.get("queues") or {}).get("body") if isinstance(a.get("queues"), dict) else None
    if not isinstance(q, dict) or not q.get("repeating") or q.get("paused"):
        return False
    act = q.get("active")
    return not act or (isinstance(act, dict) and act.get("action") in LOOP_STEPS)


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
    "trio_busy_lively": True,  # (d26 batch257) ... each moving or with news (stale_s under still_cut, newsworthy)
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
    # (d24 batch170 QM1, viewer Caleb, site 14:51: "show a view of the front of Asterion when it is in flight for a few
    # seconds") a ship flying a leg to or from the solar system edge or the shattered planet: its bow (the hull's north
    # edge from its foundation tiles, live.py add_hulls) on air for bow_hold at a story turn, at most once a round
    "bow": True,
    "bow_hold": 8.0,          # seconds on the bow
    "bow_gap": 300.0,         # at least this long between bow shots ...
    "bow_round_max": 1200.0,  # ... and a round is over after this long, or sooner once every agent on air in the last
    "bow_window": 3600.0,     # bow_window has had a story since the last bow shot
    "bow_first": 120.0,       # the first one not before this long after the start
    "bow_recent": 120.0,      # not for a ship on air this recently (a visit pans from its bow anyway)
    "bow_ahead": 0.4,         # the hull's north edge this far down the frame: the space ahead, where asteroids come in
    "work_hold": 25.0,        # an agent's platform action shows the platform this long ...
    "work_max": 90.0,         # ... more while its requests keep coming, up to this
    "work_fresh": 12.0,       # a platform action dispatched within this long is news
    "work_gap": 180.0,        # the same agent's work on the same platform is shown again after this long
    "work_ratio": 0.8,        # an agent off air: its platform action takes over if it scores this share of the one on air
    # (d27 batch267 LB, shift85: 11 of 23 new builds late, 8 of them on platforms, which were news only work_fresh and
    # waited out onair_dwell; Sol's Loom inspections aired 25x in repeats, 16.2 min) A build on a platform (BUILD_WORK)
    # is news work_build_fresh: it takes over a story on air work_build_min (no dwell, no score ratio), and a quiet or
    # timed view, a launch or another's platform inspection (yields_to_build) after work_build_min; a check-in trio is left
    # for it, and no launch shot starts while one waits.
    "work_build_fresh": 30.0,
    "work_build_min": 8.0,
    # Repeats: a platform shown for work within work_repeat comes back only for a build (not an inspection, settings or
    # requests), at least work_build_gap after its last work shot, and then as a closer view of where the build landed
    # (work_spot_zoom) when the work names a place.
    "work_repeat": 900.0,
    "work_build_gap": 60.0,
    "work_spot_zoom": 0.9,
    # (d28 batch312 A, viewer Aurora 10:47: "Could repair/build shots on large ships use a brief overview followed by a
    # close-up of the actual changed machines or feeders? ... a first platform visit can use the whole-ship view despite
    # an exact work position.") A build that names where it lands: on a first visit the whole ship work_overview_s,
    # then the camera moves to the work; a repeat goes there at once. The close-up fits the request's box (its entries
    # or area) plus work_close_margin tiles, at a zoom from work_close_min (19 px a tile at 1080p: a one-tile inserter
    # still readable) to work_spot_zoom (a position alone: that zoom); the caption says what it names and where on the
    # ship (bow north): "Sol placing 5 ghosts (3 assembling machine 2, 2 inserter) on Loom · whole ship, the work near
    # the stern, starboard side", then "... on Loom · near the stern, starboard side".
    # (d28 batch312 B, viewer Aurora 10:48: "carry a few operation stories through to their results ... use connected
    # main/inset views, briefly explain the question and real team handoff, then show the result as passed, failed or
    # still pending. Revisit the same repaired spot after its watch completes.") A story beat (model.py `stories`,
    # stories.py: a flight watch's question when it starts, its result when it ends): the ship on air story_hold s,
    # captioned, the agent who set it in the inset story_inset_s once the ship is up; a result goes back to the spot
    # last built on (batch312 A's close-up). Like a build, it waits for a free moment (no fight, battle, urgent shot,
    # segment, look, danger or build on air), at most one story_gap apart.
    "stories": True,
    "story_hold": 20.0,
    "story_inset_s": 14.0,
    "story_gap": 60.0,
    "work_overview_s": 5.0,
    "work_close_margin": 10.0,
    "work_close_min": 0.6,
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
    "battle_spacing": 120.0,  # no new battle within this long of the last one's end (scored fights: battle_all off)
    # (d26 batch245 MB, operator: "These battles are where our defenses fought, which is what viewers want to see ... a
    # battle reaches air within seconds unless an operator look holds the camera"; shift81's 5 battles all scored
    # 0.70 against a bar of 2.09: no loss, so no pieces part) every fight where enemies hit our buildings, vehicles or
    # an agent on a planet is a battle whatever its score (still logged; it spends none of the group budget). Against
    # flapping: a fight in the area of the battle that ended within battle_resume resumes it; a new one elsewhere
    # waits battle_gap of the story after the last battle, unless it began while that battle was on (it follows on).
    "battle_all": True,
    "battle_gap": 20.0,
    # ... and a fight in the area of a battle that aired within battle_repeat with nothing of ours lost is its inset
    # only (shift79: the laser turrets at (-304, -272) were hit at 02:08, 02:09, 02:13 and 02:19)
    "battle_repeat": 300.0,
    "incoming": True,       # follow an enemy group on its way (harness attack_groups_live) when it scores enough
    "incoming_spacing": 600.0,  # at most one followed group this often
    "incoming_max": 240.0,  # following a group at most this long before contact
    # (batch245 MB) a group not followed goes in the inset (maybe_group_pip): seen at most group_pip_wait ago, up at
    # most group_pip_max
    "group_pip": True,
    "group_pip_wait": 30.0,
    "group_pip_max": 45.0,
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
    "battle_resume": 90.0,  # a fight in the area of the battle that ended this recently resumes it (the next wave;
    # batch245: 45 until d26, every attack a battle now)
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
    # (d26 batch224 AY, viewer Aurora 05:29: "Opus's shelling is off-screen. Follow the vehicle or target area while
    # the action lasts") A flare barrage: 40-110 flares in 8-28 s over nest clusters 50-500 tiles across, 21 pieces
    # 1000-1460 tiles off firing every 3.3 s, shells up 17-24 s: impacts over a minute or so. A shell is kept until
    # arty_pre before it lands; the shot holds while shells land within arty_near of where it looks (or flared by the
    # same agent), up to arty_max, its frame moved to the impacts due next (arty_frame).
    "arty_gap": 120.0,      # (batch224) from the end of one artillery shot to the start of the next
    "arty_lead": 0.6,       # a shell landing sooner than this is let go (the cut would come after it)
    "arty_pre": 6.0,        # (batch224) a shell landing later than this is judged this long before it lands
    "arty_after": 4.0,      # held this long after the (last) impact
    "arty_max": 90.0,       # (batch224; was 20) an artillery shot at most this long while more shells land there
    "arty_near": 48.0,      # tiles: a later shell landing this close to the shot's frame or target extends it
    "arty_move": 2.5,       # (batch224) the barrage's frame moved at most this often
    "arty_zoom_min": 0.45,  # (batch224) the widest frame of a barrage's impacts
    "arty_zoom": 0.8,
    # (d26 batch257 IB, viewer Aurora site:5029/5030: 43.3% of shift83 a standing character, 101 of its 107 idle minutes
    # with every character still; 1261 rockets launched in it, none on air) A rocket about to lift off (launches.py: a
    # silo ordered to launch lifts off 8-10 s later; the 3 s poll sees it 6 s ahead at least) instead of a story standing
    # still: the story on air stale launch_still and on air launch_air, nobody else moving or with news, nothing held;
    # framed launch_lead before lift-off at the soonest, held through the flight (rocket_flying 5.9-6.8 s on world n)
    "launch": True,
    "launch_still": 30.0,   # the story on air standing still (or on a loop) this long (still_cut) ...
    "launch_air": 10.0,     # ... and on air this long
    "launch_gap": 20.0,     # from the end of one launch shot to the start of the next
    "launch_lead": 2.5,     # lift-off at the soonest this far ahead: the standby framed and the cut made before it
    "launch_wait": 12.0,    # lift-off at the latest at most this far ahead (else a later poll judges it)
    "launch_after": 6.5,    # on air this long after lift-off (the flight)
    "launch_max": 30.0,     # a launch shot at most this long (more silos of the frame launching hold it)
    "launch_zoom": 0.7,
    "launch_zoom_min": 0.45,
    "launch_up": 6.0,       # tiles the frame sits north of the silos: the rocket rises into it
    "launch_near": 48.0,    # tiles: silos launching this close together share the shot
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
    # (d26 batch222 CD, viewer Aurora 20:09: "Grok's repeat walking often fills the stream. Could camera priority decay
    # for repeated loops, favor fresh work/events or a useful overview, and preserve host holds?"; site:4876-4879)
    # A short loop: over the last loop_window the character walked at least loop_travel tiles inside a box at most
    # loop_span across, with no action placing pieces (Grok's queue_repeat ag-watch-walk (62,18) <-> (20,30), 46 tiles a
    # leg every 8 s: 76% of 19:43-21:40 on air, airtime.py). Its score halves every loop_half while it goes on (to
    # loop_floor at the least), its walk is no move_boost, and on air it is stale like a character standing still.
    "loop_window": 180.0,
    "loop_travel": 120.0,
    "loop_span": 64.0,
    "loop_half": 60.0,
    "loop_floor": 0.1,
    "loop_end": 30.0,       # not seen looping this long: the loop is over
    "loop_queue": True,     # (batch245) a repeating body queue walking or waiting is a loop whatever its size
    # Fresh events and visible progress: an action kind the agent has not run in fresh_window, a big action starting,
    # its remote vehicle setting off, or new ground (fresh_far tiles from everywhere it stood in fresh_window) scores up
    # to 1 + fresh_boost, fading over fresh_s; an action that placed, built or removed pieces within progress_s scores
    # progress_boost. A fresh agent (its event within fresh_cut, itself not stale) takes the camera after onair_dwell
    # when it scores fresh_ratio of the story on air, and after still_min from a stale story whatever the scores.
    "fresh_window": 600.0,
    "fresh_s": 120.0,
    "fresh_boost": 1.0,
    "fresh_far": 96.0,
    "fresh_cut": 120.0,
    "fresh_ratio": 1.0,
    "progress_s": 20.0,
    "progress_boost": 1.3,
    # Quiet time: the story on air stale (standing still, idle or on a loop) at least quiet_story and no fresh or moving
    # agent to cut to: a quiet view instead, the one shown longest ago of a base tour (basetour.py, viewer Caleb d25:
    # one planet after another, least recently toured first), a platform visit and the base map (the last two only with
    # a standby client); one quiet view at most every quiet_gap, and then the story goes to the best agent that is not
    # stale (or the best one). Nothing urgent, held, pinned, framed or fighting meanwhile; host and operator looks,
    # follows, platform holds, tours and the hourly piece (a look) come first. tour_every: a tour about this often
    # anyway (tour_first after the start), as the base map's map_every.
    # (batch240 IA: 90 and 150 until d26; shift80's replay: idle or loop air 50.7% -> 43.3%, repeats 11.8 -> 15.3 min)
    "quiet_story": 60.0,
    "quiet_gap": 120.0,
    "tour_every": 1800.0,
    "tour_first": 900.0,
    "quiet_platform_hold": 25.0,
    # Remote vehicles (viewer Aurora site:4851): an agent's car or tank driven by remote view (status active.remote) or
    # spidertron sent by remote (its journal's vehicle replies, work.VehicleFeed) is shown where the vehicle is, as a
    # fixed view moved with it, labelled "Opus · spidertron by remote view": a read at most vehicle_stale old, at least
    # vehicle_near tiles from the character; else the character as before. Between reads a spidertron walking to its
    # target is led along that line at its read speed (at most to the target).
    "vehicle_stale": 30.0,
    "vehicle_near": 24.0,
    "vehicle_zoom": 0.75,
    # (d26 batch224 VS, viewer Aurora 05:29) A remote vehicle walking (a read under vehicle_stale with speed, or a
    # target given and not reached at vehicle_speed), firing (status vehicle_fire, seated) or in a fight or loss within
    # fight_near of it keeps its agent active (not still, not looping, the move or fight boost) and on the vehicle
    # while that lasts, from a read up to vehicle_keep old.
    "vehicle_keep": 600.0,
    "vehicle_speed": 47.5,  # km/h: a go_to reply has no speed (spidertron 27069154's reads, shifts 79-80: 46-50 while
                            # walking, 47.5 the median; batch232, was 45)
    # (d26 batch232 VC, viewer Aurora site:5020) The service reads the vehicles' positions every poll (work.VehicleFeed
    # live rows). The view aims vehicle_ahead s on and glides there at no less than vehicle_glide x the vehicle's speed:
    # shift80 09:27:05-46 each step glided at 9-10 tiles/s behind a spider walking 13 and the frame fell 130 tiles back.
    "vehicle_ahead": 1.0,
    "vehicle_glide": 1.2,
    # (d26 batch245 SP, viewer Aurora 14:53: "Opus's spider shot panned without catching it before a cut ... frame the
    # vehicle promptly, then track smoothly and start dwell once it is visible ... Shorten an unchanged stuck scene
    # unless recovery or combat is active, and return when progress resumes") shift82 14:59:54: the standby kept a frame
    # 230 tiles behind the spider for 20 s and the cut panned on air; 14:41:57-14:42:01 the aim ran 30 tiles ahead of a
    # stuck spider whose read said it walked, then snapped back. A standby on a vehicle shot follows the vehicle (off
    # air) and is framed anew when it was far off; dwell counts only while the vehicle is in the frame; the lead is no
    # faster than the live reads saw it go (vehicle_obs); a stopped vehicle inside vehicle_still_box of the frame keeps
    # the frame still; a vehicle that has not moved vehicle_progress tiles in vehicle_stuck s, not fighting or firing,
    # is stuck: its shot has served its dwell, it counts as standing, a quiet view may come; moving again is news.
    "vehicle_stuck": 20.0,
    "vehicle_progress": 4.0,
    "vehicle_still_box": 0.7,
    "vehicle_obs": 12.0,    # live reads this recent give its seen speed
    "vehicle_settle": 3.0,  # s: the frame's way back after a stop the aim ran past (the vehicle still in the frame)
    # (d26 batch240 IA) a build, paste, deconstruction or silo load in the agent's journal (work.DidFeed): the live read
    # never shows these (done within the request). It is a fresh event; away from its character (vehicle_near), the
    # agent's shot is where it landed while it is did_hold old. In shift80 4 of 16 new builds aired at once (75 s median).
    "did_hold": 45.0,
    "did_zoom": 0.9,
    "fresh_min": 20.0,      # a fresh agent takes over a stale story on air this long (was still_min, 60 s)
    "quiet_min": 8.0,       # a quiet view gives way to a fresh agent after this long
    "vehicle_flip": 20.0,   # an agent's shot switched between vehicle and character at most this often (replay 02:18:51)
}
AIR_FILE, AIR_SAVE_S = "surface-air.json", 60.0  # (batch232) the planets' air time kept across a restart
AUTO_LOOKS = {"tour"}  # (batch245) looks set by the service's own pieces (tour.py), not by the operator: a battle takes them
VISIBLE = FIGHT | BUILD | WALK | {"mine", "gather", "craft", "construct", "kite", "repair", "pickup", "drive", "shoot"}
DULL = {"craft", "wait_until", "sleep", "inspect", "feed", "insert", "take", "transfer", "research", "fuel", "observe"}
BIG = {"construct": 4, "build_path": 8, "build_blueprint": 4, "blueprint": 4}  # kind -> pieces that make it big
# (batch222) kinds whose start is news (fresh_window): visible work, not a walk, a craft or a read
FRESH_KINDS = (VISIBLE | {"place_ghosts", "paste", "blueprint_place", "deconstruct", "launch", "load_silo", "vehicle"}) - WALK - DULL
# (d27 batch267 LB) platform work that changes the platform (work.py REMOTE): news, as a build on the ground is
BUILD_WORK = {"place_ghosts", "paste", "blueprint_place", "deconstruct", "cancel_deconstruction", "remove_ghosts"}
DID_TEXT = {"place_ghosts": "ghosts placed", "paste": "a blueprint pasted", "blueprint_place": "a blueprint pasted",
            "build_blueprint": "building a blueprint", "blueprint": "building a blueprint", "build": "building",
            "place": "building", "build_path": "building a path", "construct": "building", "deconstruct":
            "marked for deconstruction", "load_silo": "loading a rocket", "launch": "launching a rocket", "mine": "mining"}


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
    # (batch267) a platform work shot's own words ("building on Loom", "deconstructing on Loom", "working on Loom")
    work_doing = str(plat.get("label") or "").split(" · ", 1)[-1] if plat and plat.get("why") == "work" and \
        " · " in str(plat.get("label") or "") else None
    doing = main.get("follow") or ("in battle" if main.get("battle") and name else "") or ((work_doing or f"working on {plat['name']}") if plat and name else
                                   main["vehicle"].split(" · ", 1)[-1] if main.get("vehicle") and name else
                                   main["did"].split(" · ", 1)[-1] if main.get("did") and name else
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
            "cloud": main.get("cloud"),
            # (batch222) a base tour on air {surface, label, machines}; the vehicle by remote view the agent on air drives
            "tour": main.get("tour"), "vehicle": main.get("vehicle"), "did": main.get("did")}


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
        self.air_saved = -1e9      # (batch232) when surface-air.json was last written
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
        self.plat_work_shown = {}  # (batch267) platform -> when any agent's work on it went on air
        self.work_built = {}   # (batch267) (agent, platform) -> the time of the latest build row shown
        self.builds_waiting = []  # (batch267) platform builds this step that are news and not on air yet
        self.stories_shown, self.story_on, self.last_story = set(), None, -1e9  # (batch312 B) maybe_story
        self.did_news = {}     # (batch267) name -> when its fresh event was a build from its journal (did)
        self.danger_seen = {}  # platform -> (when its danger shot went on air or was last held, its level then)
        self.edge_legs = {}    # platform -> {leg: (origin, dest), shown}: an edge leg's dense part (maybe_edge)
        self.last_bow = None   # (QM1) when the last bow shot went on air
        self.bows = []         # (t, name, why): bow shots, why the round was over
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
        self.battle_spots = []   # (batch245) (end, battle) of the battles aired lately: battle_repeat
        self.group_pips = []     # (batch245) (group id, seen) of groups not followed: maybe_group_pip
        self.cues_seen = set()  # voice clip ids already judged
        self.cue_last = {}      # agent -> when its last cue was shown
        self.last_cue = -1e9
        self.cues = []          # (t, agent, decision, label)
        self.arty_seen = set()  # artillery shell keys already judged
        self.last_arty = -1e9
        self.arty_queue = []    # (batch224) shells landing later than arty_pre: {sh, lands, key}
        self.arty_end = -1e9    # (batch224) when the last artillery shot ends (arty_gap counts from it)
        self.silo_read_at = None  # (batch257) the silos read last seen (snapshot silos.read_at)
        self.silo_status = {}   # (batch257) silo key -> its status in that read
        self.launch_due = {}    # (batch257) silo key -> a launch ordered, not yet flying: {key, surface, position, lift, to}
        self.silo_lifted = {}   # (batch257) silo key -> the read that first saw its rocket flying
        self.launch_end = -1e9  # (batch257) when the last launch shot ended (launch_gap counts from it)
        self.launch_surface_t = {}  # (batch257) planet -> when a launch shot last showed it
        self.launch_log = []    # (batch257) (t, label, keys, lead)
        self.arty_said = {}     # (batch224) a drop's reason -> when it was last logged (a barrage's drops once per 10 s)
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
        # (batch222 CD) loops, fresh events, progress, quiet views, remote vehicles
        self.trail = {}        # name -> [(t, x, y, surface)]: where it stood over loop_window
        self.loop_since = {}   # name -> when its current loop was first seen
        self.loop_seen = {}    # name -> when it was last seen looping
        self.kinds = {}        # name -> {action kind: when last seen}
        self.places = {}       # name -> [(t, x, y, surface)] a sample a FRESH_PLACE_S over fresh_window (new ground)
        self.fresh = {}        # name -> (t, why): its latest fresh event
        self.progress = {}     # name -> [when its action last placed pieces, its count then]
        self.vehicle_was = {}  # name -> the remote vehicle row last seen (a new target is a fresh event)
        self.vehicle_act = {}  # (batch224) name -> its vehicle's activity at the last step (vehicle_activity)
        self.vehicle_swapped = {}  # (batch224) name -> when keep_vehicle last switched its shot (vehicle_flip)
        self.vehicle_seen = {}  # (batch245) unit -> [(t, x, y)] of its live reads (vehicle_obs)
        self.vehicle_anchor = {}  # (batch245) name -> [x, y, since, resumed]: where its vehicle has stood since
        self.vehicle_act_t = {}  # (batch245) name -> when its vehicle last walked, fought or fired
        self.vehicle_resumed = {}  # (batch245) name -> when its vehicle moved on after standing stuck (news)
        self.tours = None      # basetour.Tours (serve.py set_tours), or None: no base tours
        self.toured = {}       # surface -> when its tour last went on air
        self.last_tour = None
        self.tour_shots = []   # (t, surface, label): base tours on air
        self.last_quiet = -1e9  # when the last quiet view went on air
        self.quiet_shown = {}  # "tour" | "platform" | "map" -> when it was last the quiet view
        self.quiets = []       # (t, kind, label, why)
        self.after_quiet = False  # the story on air was cut for a quiet view: not resumed if it is still stale

    # -- clients ----------------------------------------------------------------------------------------------
    def slot(self, name):
        return next(s for s in self.slots if s["slot"] == name)

    def standbys(self):
        busy = {self.onair, self.inset and self.inset["slot"]}
        return [s for s in self.slots if s["slot"] not in busy]

    def next_slot(self):
        """The standby that frames the next subject (the first one; the other takes insets). Never a camera panel: a
        panel is inset only (inset_free)."""
        sb = [s for s in self.standbys() if not s.get("panel")]
        if self.pending:
            return self.slot(self.pending["slot"])
        return sb[0] if sb else None

    def n_clients(self):
        """The camera clients (slots that can go on air): camera panels (inset only) do not count."""
        return sum(1 for s in self.slots if not s.get("panel"))

    def inset_free(self, sb):
        """The standby an inset takes, or None: a camera panel when one is free (d27 batch285 B, tools/cams.py
        POG_CAM_PANELS: views drawn by the main client, for insets only), else the last client when two or more are
        free (one stays free to frame the next cut)."""
        panels = [s for s in sb if s.get("panel")]
        if panels:
            return panels[-1]
        clients = [s for s in sb if not s.get("panel")]
        return clients[-1] if len(clients) >= 2 else None

    def program(self):
        out = {"onair": self.onair, "inset": self.inset and self.inset["slot"], "layout": self.mode}
        if self.trio:
            out["tiles"] = dict(self.trio["tiles"], main=self.onair)
        if self.hosting(getattr(self, "step_t", None) or time.time()):
            out["host"] = True  # cuts.py: the host's capture over the cameras
        return out

    def onair_frac(self):
        return self.cfg["trio_frac"] if self.mode == "trio" else self.cfg["view_frac"]

    def frame_half(self, zoom):
        """(batch245) Half the on-air frame in tiles at this game zoom (a shot's game_zoom): (across, down)."""
        from director import CLIENT
        tile = 32.0 * max(0.01, zoom)
        return CLIENT[0] / tile / 2 * self.onair_frac(), CLIENT[1] / tile / 2

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
                                    "target": cur and {k: cur[k] for k in ("agents", "zoom", "vehicle", "did") if k in cur}}) + "\n")
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
                                    "target": {k: target[k] for k in ("agents", "zoom", "vehicle", "did") if k in target}}) + "\n")
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
        if not nxt:  # (batch222) one client: moved on air, a cut in the log (airtime.py counts it)
            self.retarget(target, reason, scores, now)
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
        t = self.state.get(self.onair) or {}  # (CK2) a move the director steps itself
        if t.get("subject") in ("@look", "@tour") and t.get("move") and t.get("move_ok") is False:
            soon = min(soon if soon is not None else 1e9, self.MOVE_STEP)
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
        elif self.inset_free(sb):
            slot = self.inset_free(sb)
        elif sb and not self.pending and self.n_clients() == 2 and not sb[-1].get("panel"):
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
            stood = self.track_vehicle(a, now)  # (batch245) its vehicle's reads and where it has stood
            vact = self.vehicle_activity(a, now)
            stuck = stood >= self.cfg["vehicle_stuck"] and vact not in ("fighting", "firing")
            if stuck:
                vact = None  # (batch245) its read may say it walks: it has not moved, standing since it stopped
                self.vehicle_act_t[a["name"]] = min(self.vehicle_act_t.get(a["name"], now), now - stood)
            elif vact:
                self.vehicle_act_t[a["name"]] = now
            acting = a.get("combat") or plan_kind(a) in VISIBLE or vact  # (batch224 VS)
            if m is None:
                self.motion[a["name"]] = m = {"pos": p, "still_since": now, "moved": now}
            if stuck and not acting:
                m["moved"] = min(m["moved"], now - stood)
            if p and m["pos"] and dist(p, m["pos"]) >= self.cfg["still_moved"]:
                m["pos"], m["moved"] = p, now
            elif p and not m["pos"]:
                m["pos"] = p
            if acting:
                m["moved"] = now
            d = self.did_row(a, now)  # (batch240) a build of its own just now: it acted, whatever the read showed
            if d and d["t"] > m["moved"]:
                m["moved"] = min(now, d["t"])
            idle = a.get("idle_s")  # (batch240) its own clocks say its character stood this long: still, whatever moved
            if isinstance(idle, (int, float)) and idle > 0 and not acting and not (d and now - d["t"] < idle):
                # (batch245) not before its vehicle last walked: shift82 15:00:00 "opus still 1779 s" 6 s after its
                # spidertron stopped (Opus's clocks count the character, idle while it drives by remote view)
                m["moved"] = min(m["moved"], max(now - idle, self.vehicle_act_t.get(a["name"], -1e9)))
            big = big_plan(a)
            if a["name"] in self.was_big and not big:
                self.plan_end[a["name"]] = now
            new_big = big and a["name"] not in self.was_big
            (self.was_big.add if big else self.was_big.discard)(a["name"])
            self.track_progress(a, now)
            self.track_loop(a, now)
            self.track_fresh(a, now, new_big)

    def still_s(self, name, now):
        m = self.motion.get(name)
        return now - m["moved"] if m else 0.0

    # -- (batch222 CD) loops, fresh events, visible progress ---------------------------------------------------------
    FRESH_PLACE_S = 10.0  # seconds between the samples of where an agent stood (new ground)

    def track_progress(self, a, now):
        """Pieces placed, built or removed by the action running now (status plan placed/built/remaining)."""
        p = a.get("plan") or {}
        done = [p.get(k) for k in ("placed", "built") if isinstance(p.get(k), (int, float))]
        if isinstance(p.get("remaining"), (int, float)):
            done.append(-p["remaining"])
        if not done:
            self.progress.pop(a["name"], None)
            return
        count = sum(done)
        prev = self.progress.get(a["name"])
        if prev is None:
            self.progress[a["name"]] = [-1e9, count]
        elif count > prev[1]:
            self.progress[a["name"]] = [now, count]

    def progressed(self, name, now):
        p = self.progress.get(name)
        return bool(p) and now - p[0] < self.cfg["progress_s"]

    def track_loop(self, a, now):
        """A short loop (loop_window, loop_travel, loop_span), or (batch245) its repeating queue walking it: when it was
        first seen, while it goes on."""
        cfg, n, p = self.cfg, a["name"], a.get("position")
        tr = self.trail.setdefault(n, [])
        if p:
            s = surface_of(a)
            if tr and tr[-1][3] != s:
                tr.clear()
            tr.append((now, p["x"], p["y"], s))
        while tr and now - tr[0][0] > cfg["loop_window"]:
            tr.pop(0)
        looping = cfg["loop_queue"] and queue_walk_loop(a)  # (batch245) its own repeating queue walks it round
        if not looping and len(tr) >= 3 and now - tr[0][0] >= cfg["loop_window"] * 0.5 and not self.progressed(n, now) \
                and plan_kind(a) not in BUILD and self.still_s(n, now) < cfg["loop_end"]:  # (standing: the loop is over)
            path = sum(math.hypot(b[1] - c[1], b[2] - c[2]) for b, c in zip(tr, tr[1:]))
            xs, ys = [q[1] for q in tr], [q[2] for q in tr]
            looping = path >= cfg["loop_travel"] and max(max(xs) - min(xs), max(ys) - min(ys)) <= cfg["loop_span"]
        if looping:
            if now - self.loop_seen.get(n, -1e9) > cfg["loop_end"]:
                self.loop_since[n] = tr[0][0]  # it has been on it since the window's start
            self.loop_seen[n] = now
        elif now - self.loop_seen.get(n, -1e9) > cfg["loop_end"]:
            self.loop_since.pop(n, None)

    def loop_s(self, name, now):
        """Seconds the agent has been on its short loop (0: none)."""
        t = self.loop_since.get(name)
        return now - t if t is not None and now - self.loop_seen.get(name, -1e9) <= self.cfg["loop_end"] else 0.0

    def stale_s(self, name, now):
        """Seconds the character has shown nothing new: standing still, or walking its short loop."""
        return max(self.still_s(name, now), self.loop_s(name, now))

    def track_fresh(self, a, now, new_big):
        """Its latest fresh event (fresh_window, fresh_far): a kind of visible work (FRESH_KINDS) it has not run in the
        window, a big action starting, its remote vehicle setting off for a new target, new ground."""
        cfg, n = self.cfg, a["name"]
        why = None
        k = plan_kind(a)
        seen = self.kinds.setdefault(n, {})
        if k in FRESH_KINDS or any(w in k for w in ("rocket", "platform", "launch", "cargo")):
            if now - seen.get(k, -1e9) >= cfg["fresh_window"] and seen.get("@", 0) > 0:
                why = str(k).replace("_", " ")
            seen[k] = now
        d = self.did_row(a, now)  # (batch240) the journal's build, paste, deconstruction or silo load, once each
        if d and d["t"] > seen.get("@did", -1e9):
            seen["@did"] = d["t"]
            if now - seen.get(d["action"], -1e9) >= cfg["fresh_window"] and seen.get("@", 0) > 0:
                why = DID_TEXT.get(d["action"], d["action"].replace("_", " "))
                self.did_news[n] = now  # (batch267) a build: news that a quiet view, launch or inspection yields to
            seen[d["action"]] = now
        seen["@"] = seen.get("@", 0) + 1  # (the first look at an agent is no news: what it did before is unknown)
        if new_big and not why:
            why = str(k).replace("_", " ")
        v = a.get("remote_vehicle") if isinstance(a.get("remote_vehicle"), dict) else None
        was = self.vehicle_was.get(n)
        # (batch232) a new call by the agent with a target, not the live read's next waypoint
        if v and v.get("target") and (not was or was.get("seen_t", was.get("t")) != v.get("seen_t", v.get("t"))) and \
                (v.get("cmd_target") or v.get("target")) != (was or {}).get("cmd_target", (was or {}).get("target")) and \
                now - v.get("seen_t", v.get("t", 0)) < cfg["vehicle_stale"] and not self.vehicle_stuck_s(n, now):
            why = why or f"{v.get('vehicle') or 'vehicle'} by remote view"  # (batch245: a call to a stuck one is no news)
        if v:
            self.vehicle_was[n] = v
        res = self.vehicle_resumed.pop(n, None)
        if res is not None:  # (batch245) its vehicle moves again after standing stuck
            why = why or f"{(v or {}).get('vehicle') or 'vehicle'} on its way again"
        act = self.vehicle_activity(a, now)  # (batch224 VS) its vehicle starts firing or fighting: news
        if act in ("fighting", "firing") and self.vehicle_act.get(n) not in ("fighting", "firing"):
            why = why or f"{(v or a.get('vehicle_fire') or {}).get('vehicle') or 'vehicle'} {act}"
        self.vehicle_act[n] = act
        p = a.get("position")
        if p and not why:
            places, s = self.places.setdefault(n, []), surface_of(a)
            while places and now - places[0][0] > cfg["fresh_window"]:
                places.pop(0)
            if places and now - places[0][0] >= cfg["fresh_window"] * 0.5 and \
                    all(q[3] != s or math.hypot(q[1] - p["x"], q[2] - p["y"]) >= cfg["fresh_far"] for q in places):
                why = "new ground"
            if not places or now - places[-1][0] >= self.FRESH_PLACE_S:
                places.append((now, p["x"], p["y"], s))
        if why:
            self.fresh[n] = (now, why)

    def fresh_age(self, name, now):
        f = self.fresh.get(name)
        return now - f[0] if f else 1e9

    def newsworthy(self, name, now):
        """A fresh agent worth a cut (fresh_cut): not stale, or its event within twice still_cut (a short build or
        paste leaves the character standing by what it did)."""
        age = self.fresh_age(name, now)
        return age < self.cfg["fresh_cut"] and (self.stale_s(name, now) < self.cfg["still_cut"] or
                                                age < 2 * self.cfg["still_cut"])

    def fresh_build(self, name, now):
        """(batch267) newsworthy for a build from its journal (track_fresh's did row)."""
        f = self.fresh.get(name)
        return bool(f) and self.did_news.get(name) == f[0] and self.newsworthy(name, now)

    def yields_to_build(self, cur, now):
        """(batch267) The shot on air gives way to a fresh build once up work_build_min: a tour, the map, a platform
        visit, departure or edge view, a launch, or a platform's work that is no build. A battle, an attack, a segment,
        an agent's cue (its voiced line), an operator's or followed platform, danger and a look keep it."""
        if not cur or now - self.onair_since < self.cfg["work_build_min"]:
            return False
        subj = cur.get("subject")
        why = (cur.get("platform") or {}).get("why")
        if subj in ("@tour", "@map") or cur.get("launch"):
            return True
        if subj == "@platform":
            return why in ("visit", "departure", "edge") or (why == "work" and not cur.get("build"))
        return False

    def fresh_factor(self, name, now):
        age = self.fresh_age(name, now)
        return 1.0 + self.cfg["fresh_boost"] * max(0.0, 1.0 - age / self.cfg["fresh_s"])

    # -- (batch222 CD) a vehicle by remote view --------------------------------------------------------------------
    def vehicle_where(self, v, now):
        """Where a remote vehicle read (VehicleFeed row) has it now: a spidertron walking to its target led along its
        route at its read speed (a go_to reply's none: vehicle_speed), at most to the route's end; -> ({x, y}, going).
        (batch245 cp3) A live read names only the next waypoint of a pathed route (shift82 16:16: 12 tiles apart, the
        lead stopped there and the frame trailed 30-50 tiles): the lead goes on along the reply's remaining route."""
        spot = {"x": float(v["position"]["x"]), "y": float(v["position"]["y"])}
        goal, speed = v.get("target"), v.get("speed")
        if speed is None and goal:
            speed = self.cfg["vehicle_speed"]
        seen = self.seen_speed(v, now) if v.get("live") else None
        if seen is not None and isinstance(speed, (int, float)):
            speed = min(speed, seen * 1.25 + 1.0)  # (batch245) no faster than the live reads saw it go (a stuck spider)
        if not goal or not isinstance(speed, (int, float)) or speed <= 0 or (seen is not None and speed < 4.0):
            return spot, False
        left = speed / 3.6 * max(0.0, now - v.get("t", now))
        here = spot
        for q in self.vehicle_path(v, goal):
            d = math.hypot(q["x"] - here["x"], q["y"] - here["y"])
            if left < d:
                f = left / d
                return {"x": round(here["x"] + (q["x"] - here["x"]) * f, 1),
                        "y": round(here["y"] + (q["y"] - here["y"]) * f, 1)}, True
            left -= d
            here = {"x": float(q["x"]), "y": float(q["y"])}
        return {"x": round(here["x"], 1), "y": round(here["y"], 1)}, False

    @staticmethod
    def vehicle_path(v, goal):
        """(batch245 cp3) The waypoints from the read's target on: the reply's route from the waypoint nearest it (within
        4 tiles), else the target alone."""
        route = v.get("route") if isinstance(v.get("route"), list) else []
        best = None
        for i, q in enumerate(route):
            d = math.hypot(q["x"] - goal["x"], q["y"] - goal["y"])
            if d <= 4.0 and (best is None or d < best[0]):
                best = (d, i)
        return [goal] + (route[best[1] + 1:] if best else [])

    def seen_speed(self, v, now):
        """(batch245) km/h between its last two live reads within vehicle_obs, or None."""
        tr = self.vehicle_seen.get(v.get("unit_number")) or []
        tr = [q for q in tr if now - q[0] <= self.cfg["vehicle_obs"]]
        if len(tr) < 2 or tr[-1][0] - tr[-2][0] <= 0:
            return None
        (t0, x0, y0), (t1, x1, y1) = tr[-2], tr[-1]
        return math.hypot(x1 - x0, y1 - y0) / (t1 - t0) * 3.6

    def track_vehicle(self, a, now):
        """(batch245) Its vehicle's live reads (seen speed) and where it has stood; -> seconds it has stood still past
        vehicle_progress tiles (0: moving, or none). Moving again after vehicle_stuck is a fresh event."""
        n = a["name"]
        v = a.get("remote_vehicle") if isinstance(a.get("remote_vehicle"), dict) else None
        if not v or not isinstance(v.get("position"), dict) or self.vehicle_spot(a, now, held=True) is None:
            self.vehicle_anchor.pop(n, None)
            return 0.0
        if v.get("live") and v.get("unit_number") is not None:
            tr = self.vehicle_seen.setdefault(v["unit_number"], [])
            if not tr or tr[-1][0] != v.get("t"):
                tr.append((v.get("t", now), float(v["position"]["x"]), float(v["position"]["y"])))
                del tr[:-4]
        here = self.vehicle_where(v, now)[0]  # (where it is led to: a reply's go_to walks on between reads)
        x, y = here["x"], here["y"]
        an = self.vehicle_anchor.get(n)
        if not an or math.hypot(x - an[0], y - an[1]) >= self.cfg["vehicle_progress"]:
            if an and now - an[2] >= self.cfg["vehicle_stuck"]:
                self.vehicle_resumed[n] = now  # progress again: news (track_fresh)
            self.vehicle_anchor[n] = [x, y, now]
            return 0.0
        return now - an[2]

    def vehicle_stuck_s(self, name, now):
        """(batch245) Seconds its vehicle has stood unchanged past vehicle_stuck, not fighting or firing (else 0)."""
        an = self.vehicle_anchor.get(name)
        if not an or now - an[2] < self.cfg["vehicle_stuck"] or \
                self.vehicle_activity(getattr(self, "agents_now", {}).get(name), now) in ("fighting", "firing"):
            return 0.0
        return now - an[2]

    def vehicle_activity(self, a, now):
        """(batch224 VS) What the agent's vehicle does now that counts as action: "firing" (status vehicle_fire, seated:
        enemies within its guns' reach, ammo in), "fighting" (a fight or loss still reported within fight_near of its
        remote vehicle, a read up to vehicle_keep old), "walking" (a read under vehicle_stale showing speed, or a target
        given and not reached yet at the lead's speed); else None."""
        if not a:
            return None
        vf = a.get("vehicle_fire")
        if isinstance(vf, dict) and vf.get("targets") and vf.get("ammo"):
            return "firing"
        v = a.get("remote_vehicle") if isinstance(a.get("remote_vehicle"), dict) else None
        if not v or not isinstance(v.get("position"), dict):
            return None
        if now - v.get("seen_t", v.get("t", -1e9)) > self.cfg["vehicle_keep"]:  # (the agent's own last call)
            return None
        age = now - v.get("t", -1e9)  # (batch232: the position's, a live read's)
        spot, going = self.vehicle_where(v, now)
        if self.fight_fresh(dict(spot, surface=surface_of(a)), now):
            return "fighting"
        seen = self.seen_speed(v, now) if v.get("live") else None  # (batch245: a stuck spider's read has speed)
        if going or (age <= self.cfg["vehicle_stale"] and (v.get("speed") or 0) > 0 and (seen is None or seen >= 4.0)):
            return "walking"
        return None

    def vehicle_spot(self, a, now, held=False, ahead=0.0):
        """Where the agent's vehicle by remote view is now (or `ahead` s on), as {x, y, surface, label}; None when it
        drives none, the agent's last call to it is stale (vehicle_stale; held: twice that for a shot already on the
        vehicle; batch224: vehicle_keep while it walks, fires or fights, vehicle_activity) or the vehicle is near its
        character. (batch232) Where it is: the service's live read when there is one, else the agent's reply led on."""
        if not a or not a.get("position"):
            return None
        cfg, spot, label = self.cfg, None, None
        stale = cfg["vehicle_keep"] if self.vehicle_activity(a, now) else cfg["vehicle_stale"] * (2 if held else 1)
        drive = (a.get("plan") or {}).get("remote")
        m = COORD_RE.search(drive) if isinstance(drive, str) else None
        if m:  # a drive by remote view: status reads it every poll
            spot = {"x": float(m.group(1)), "y": float(m.group(2))}
            label = drive.split(" at ", 1)[0].replace("-", " ")
        v = a.get("remote_vehicle") if isinstance(a.get("remote_vehicle"), dict) else None
        if not spot and v and isinstance(v.get("position"), dict) and now - v.get("seen_t", v.get("t", -1e9)) <= stale and \
                now - v.get("t", -1e9) <= cfg["vehicle_keep"]:
            spot, label = self.vehicle_where(v, now + ahead)[0], str(v.get("vehicle") or "vehicle").replace("-", " ")
        if not spot or dist(spot, a["position"]) < cfg["vehicle_near"]:
            return None
        who = a.get("display_name") or a["name"]
        return dict(spot, surface=surface_of(a), label=f"{who} · {label} by remote view")

    def did_row(self, a, now):
        """(batch240) The agent's latest build, paste, deconstruction or silo load (work.DidFeed) while did_hold old,
        on a planet; None for one on a platform (maybe_work shows those; batch271: surface= may name the platform)."""
        d = a.get("did") if a and isinstance(a.get("did"), dict) else None
        if not d or d.get("platform") or not isinstance(d.get("t"), (int, float)) or now - d["t"] > self.cfg["did_hold"]:
            return None
        if d.get("surface") and any(d["surface"] in (n, (p.get("view") or {}).get("surface")) for n, p in self.plat_rows.items()):
            return None
        return d

    @staticmethod
    def did_surface(a, d):
        """(d27 batch271 WS) The surface a build landed on: the request's (work.DidFeed; the body's when it named none
        and live.py read the body then), None when not known. A row from before batch271 has no surface key: the body's."""
        return d.get("surface") if "surface" in d else surface_of(a)

    def did_spot(self, a, now):
        """(batch240) Where that request landed when it is away from the character (vehicle_near or more, or on another
        surface than the body's): {x, y, surface, label}, else None (Astra's ghosts of shift81 went 176-214 tiles from
        where she stood). (d27 batch271 WS) The spot is on the request's surface: Astra on Aquilo marked poles on Nauvis
        and the camera showed Aquilo's ice at those coordinates. A surface not known: no spot."""
        d = self.did_row(a, now)
        p = d.get("position") if d else None
        s = self.did_surface(a, d) if d else None
        if not isinstance(p, dict) or not s or not a.get("position"):
            return None
        if s == surface_of(a) and dist(p, a["position"]) < self.cfg["vehicle_near"]:
            return None
        who = a.get("display_name") or a["name"]
        from model import planet_label
        on = f" on {planet_label(s)}" if s != surface_of(a) else ""  # "Astra · marked for deconstruction on Nauvis"
        return {"x": float(p["x"]), "y": float(p["y"]), "surface": s,
                "label": f"{who} · {DID_TEXT.get(d['action'], d['action'].replace('_', ' '))}{on}"}

    def body_shot(self, name, by_name, zoom, now, fit=None):
        """The shot of an agent: its character followed, or (batch222) its vehicle by remote view, or (batch240) where
        its latest build landed away from it."""
        spot = self.vehicle_spot(by_name.get(name), now)
        if spot:
            z = self.cfg["vehicle_zoom"]
            return {"agents": [name], "subject": name, "position": {"x": spot["x"], "y": spot["y"]},
                    "surface": spot["surface"], "zoom": z, "solo_zoom": z, "vehicle": spot["label"]}
        spot = self.did_spot(by_name.get(name), now)
        if spot:
            z = self.cfg["did_zoom"]
            return {"agents": [name], "subject": name, "position": {"x": spot["x"], "y": spot["y"]},
                    "surface": spot["surface"], "zoom": z, "solo_zoom": z, "did": spot["label"]}
        shot = {"agents": [name], "follow": name, "zoom": zoom, "solo_zoom": zoom, "subject": name}
        if fit:
            shot.update(exact_zoom=True, plan_fit=fit)
        return shot

    def scores(self, agents, now):
        out = super().scores(agents, now)
        cfg = self.cfg
        for a in agents:
            n = a["name"]
            if n not in out:
                continue
            k = plan_kind(a)
            loop = self.loop_s(n, now)
            vehicle = self.vehicle_spot(a, now) is not None
            if a.get("combat") or k in FIGHT or self.vehicle_activity(a, now) in ("fighting", "firing"):
                f = cfg["fight_boost"]  # under attack or shooting (batch224: or its vehicle is): a strong pick
            elif big_plan(a):
                f = cfg["plan_boost"]
            elif vehicle and self.vehicle_stuck_s(n, now):
                f = cfg["still_factor"]  # (batch245) its vehicle stands stuck: like a character standing there
            elif vehicle:
                f = cfg["move_boost"]  # (batch222) its vehicle by remote view moves: shown where it is
            elif k in DULL:
                f = cfg["dull"]
            elif (a.get("combat") or k in VISIBLE) and not loop:
                f = cfg["move_boost"]
            elif a.get("activity") == "thinking" and self.still_s(n, now) >= cfg["still_cut"]:
                f = cfg["still_factor"]  # thinking, character standing there: like idle
            else:
                f = 1.0
            if loop:  # (batch222) the same short loop: half every loop_half
                f *= max(cfg["loop_floor"], 0.5 ** (loop / cfg["loop_half"]))
            f *= self.fresh_factor(n, now) * (cfg["progress_boost"] if self.progressed(n, now) else 1.0)
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
        air, cut = [], time.time() - self.cfg["surface_window"]
        for _ in range(20):  # this run, then the runs it resumed from
            # (d26 batch232 VC2) the planets' air time of the last surface_window, as the service before saved it: a
            # restart (each shift change) began with none, so after surface_warmup every planet but Nauvis was short of
            # its share (shift81 10:22-10:26: Aquilo and Fulgora agents x2.5, Opus and Luna on Nauvis x0.65)
            try:
                with open(os.path.join(folder, AIR_FILE)) as f:
                    air += [tuple(e) for e in (json.load(f) or {}).get("air") or []
                            if isinstance(e, list) and len(e) == 3 and isinstance(e[0], (int, float)) and e[0] >= cut]
            except (OSError, ValueError, AttributeError):
                pass
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
        seen = {round(e[0], 1) for e in self.surface_air}
        for e in sorted(set(air)):
            if round(e[0], 1) not in seen:
                self.surface_air.append((float(e[0]), str(e[1]), float(e[2])))
        self.surface_air.sort()

    def save_surface_air(self, now):
        """(batch232) The planets' air time of the last surface_window, next to surface-seen.json, every AIR_SAVE_S."""
        if not self.surface_memory or now - self.air_saved < AIR_SAVE_S:
            return
        self.air_saved = now
        path = os.path.join(os.path.dirname(os.path.abspath(self.surface_memory)), AIR_FILE)
        try:
            with open(path + ".tmp", "w") as f:
                json.dump({"air": [[round(t, 1), s, round(dt, 2)] for t, s, dt in self.surface_air]}, f)
            os.replace(path + ".tmp", path)
        except OSError as e:
            print(f"[director] surface air not saved: {e}", flush=True)

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
        self.save_surface_air(now)

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
                # (batch240 IA) for an agent doing something to see: a character standing there is no more of that
                # planet to watch (shift80: Astra on Aquilo x1.6-2.5 standing, 25.9 min of idle air)
                if self.stale_s(n, now) < cfg["still_cut"] or self.newsworthy(n, now):
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
        self.watch_silos(snapshot, now)  # (batch257) launches due
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
            since = self.pending.get("since")
            self.cut(self.pending["slot"], self.pending["reason"], now)
            if since is not None:
                self.onair_since = since  # (batch232) a swap: the story's own start
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
        # (batch245 MB) a battle takes the camera from a tour's look; an operator's look holds it
        look_holds = self.look and not (self.battle and self.cfg["battle_all"] and self.look.get("by") in AUTO_LOOKS)
        if pinned:  # an operator follow, or a key battle: on air, nothing else takes the camera
            self.leave_trio("look" if self.look else f"platform {self.plat}" if self.plat else f"follow {fol}" if fol else f"battle: {self.battle['label']}" if self.battle
                            else f"incoming: {self.incoming['label']}", now)
            self.trio_pending = None
            if look_holds:
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
            self.maybe_work(snapshot, by_name, scores, now, segment)  # (batch267) builds_waiting: the trio leaves for one
            self.tiles(by_name, scores, now)
        else:
            self.maybe_danger(scores, now, segment)
            self.maybe_edge(scores, now, segment)
            self.maybe_departure(scores, now, segment)
            self.direct(by_name, scores, ranked, now)
            self.maybe_work(snapshot, by_name, scores, now, segment)
            self.maybe_story(snapshot, by_name, scores, now, segment)
            self.maybe_attention(by_name, scores, now, segment)
            self.maybe_launch(snapshot, by_name, scores, now, segment)  # (batch257) before a quiet view
            self.maybe_quiet(by_name, scores, now, segment)
            self.maybe_tour(scores, now, segment)
            self.maybe_map(scores, now, segment)
            self.maybe_cloud(scores, now, segment)
            self.maybe_platform(scores, now, segment)
            self.maybe_trio(by_name, scores, ranked, now)
        self.maybe_cue(snapshot, by_name, scores, now, segment)
        self.maybe_artillery(snapshot, by_name, scores, now, segment)
        self.maybe_enemy_pip(snapshot, by_name, scores, now)
        self.maybe_group_pip(snapshot, by_name, scores, now)
        self.release_maps(now)
        self.pan_step(now)
        self.closeup_step(now)
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
            {k: lk[k] for k in ("cut_at", "id", "platform", "aired", "move") if lk.get(k) is not None} | \
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
                "move": lk.get("move"),
                "look": {"label": self.look_label(lk), "by": lk["by"], "surface": lk["surface"],
                         "position": dict(lk["position"]), **({"id": lk["id"]} if lk.get("id") else {})}}

    def look_aired(self, now):
        """(CK1) The look is on the program now: when it first was, kept with the hold (the snapshot's look.aired)."""
        lk = self.look_hold
        if lk is not None and lk.get("aired") is None:
            lk["aired"] = round(now, 3)

    @staticmethod
    def same_look(a, b):
        """The same shot: a spot, surface and zoom; a moving one by its surface and move (its position moves)."""
        if not (a and b):
            return False
        if a.get("move") or b.get("move"):
            return a.get("surface") == b.get("surface") and a.get("move") == b.get("move")
        return all(a.get(k) == b.get(k) for k in ("position", "surface", "zoom"))

    # (d23 batch128 CK2) a look's move goes to the game at the cut (cameras.lua plays it every tick); a standby frames
    # its first point without it. A game whose cameras.lua has no move (its reply has no camera.move): the director
    # steps it, aiming MOVE_LEAD s ahead every MOVE_STEP s with a glide that gets there then.
    MOVE_LEAD = 0.8
    MOVE_STEP = 0.5

    def start_move(self, slot, shot, now):
        t = self.state.get(slot["slot"])
        if not shot.get("move") or not t:
            return
        self.apply(slot, dict(t, move=shot["move"], jump=True, moved=now), "reframe", {}, now, quiet=True)
        t = self.state.get(slot["slot"])
        t["moved"] = now

    def step_move(self, now):
        """The fallback: a look's move on air in a game that does not play it (move_ok False)."""
        import math
        import camerapath
        t = self.state.get(self.onair)
        if not t or t.get("subject") not in ("@look", "@tour") or not t.get("move") or t.get("move_ok") is not False:
            return
        since = t.get("moved", now)
        x, y, z = camerapath.at(t["move"], now - since + self.MOVE_LEAD)
        here = t.get("position") or {}
        d = math.hypot(x - here.get("x", x), y - here.get("y", y))
        target = {k: v for k, v in t.items() if k not in ("jump", "move")}
        target.update(position={"x": round(x, 2), "y": round(y, 2)}, zoom=round(z, 3), glide=round(max(0.5, d / self.MOVE_LEAD), 2))
        self.apply(self.slot(self.onair), target, "reframe", {}, now, quiet=True)
        nt = self.state.get(self.onair)
        nt.update(move=t["move"], moved=since, move_ok=False)

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
            self.step_move(now)
            return
        if cur and cur.get("subject") in scores:
            self.resume = {"subject": cur["subject"], "since": self.onair_since}
        slot = self.next_slot() or self.slot(self.onair)
        t = self.state.get(slot["slot"])
        if not self.same_look(t, shot):
            if early and slot["slot"] == self.onair:
                return
            onair = slot["slot"] == self.onair
            self.frame_on(slot, shot if onair else dict(shot, move=None), f"standby: look {shot['look']['label']}",
                          scores, now)
            if not onair:
                self.state[slot["slot"]]["move"] = shot.get("move")  # (sent at the cut)
                self.state[slot["slot"]]["move_pending"] = bool(shot.get("move"))
            if onair:
                self.onair_since = now
                self.look_aired(now)
                if shot.get("move"):
                    self.state[slot["slot"]]["moved"] = now
            return
        t.update(look=shot["look"], until=shot["until"])
        if slot["slot"] != self.onair and self.ready(slot["slot"], now) and not early:
            self.cut(slot["slot"], f"look: {shot['look']['label']}", now)
            self.look_aired(now)
            if t.pop("move_pending", None):
                self.start_move(slot, shot, now)

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
            if cfg["battle_all"] and self.attacked(f, p):  # (batch245 MB) every one airs: waits, or a repeat's inset
                age = self.battle_repeat_age(p, now)
                if age is not None and not c["pieces"]:
                    c["taken"] = True  # (decided: its alert inset shows it)
                    self.log_threat({"t": round(now, 1), "threat": "battle", "key": k, "score": score, "parts": parts,
                                     "decision": "skip", "why": f"repeat: a battle here aired {int(age)} s ago, nothing lost"})
                    continue
                wait = "a battle is on" if self.battle or taken else \
                    f"the story's {cfg['battle_gap']:g} s after the last battle ({int(now - self.last_battle_end)} s)" \
                    if now - self.last_battle_end < cfg["battle_gap"] and f.get("first", now) >= self.last_battle_end else None
                if wait:
                    if not c.get("waits"):
                        c["waits"] = wait
                        self.log_threat({"t": round(now, 1), "threat": "battle", "key": k, "score": score, "parts": parts,
                                         "decision": "wait", "why": wait})
                    continue
                c["score"], c["t"], c["taken"] = score, now, True
                self.threats.decide("battle", k, score, parts, now, force="our defenses fight: every battle airs")
                taken = (f, score)
                continue
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

    def battle_repeat_age(self, p, now):
        """(batch245) Seconds since a battle at this spot went off the air, within battle_repeat; else None."""
        for end, b in reversed(self.battle_spots):
            if now - end > self.cfg["battle_repeat"]:
                break
            if self.in_battle(dict(p, extent=0), b):
                return now - end
        return None

    @staticmethod
    def attacked(f, p):
        """(batch245 MB) Enemies hitting our buildings, vehicles or an agent on a planet: an attack or a real loss (not
        an agent's own firing, friendly fire or a platform's asteroid damage)."""
        text = str(f.get("text") or "")
        if f.get("kind") not in ("attack", "loss") or "friendly fire" in text or str(p.get("surface") or "").startswith("platform"):
            return False
        return f.get("kind") != "loss" or not minor_loss(text) or bool(f.get("agent"))

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

    def battle_agent(self, b, by_name, now=None):
        """The agent fighting in it: alive, on its surface, in combat (or its own fight reported), nearest first; or
        (batch245) the agent whose vehicle by remote view is in it and fighting or firing (shift81 12:31: Opus's
        spidertron hit by worms)."""
        own = {k.split(":", 1)[1] for k in b.get("fresh", ()) if k.startswith("attack:")}
        best = None
        now = self.step_t if now is None else now
        for a in by_name.values():
            v = self.vehicle_spot(a, now, held=True)
            # (a vehicle that walked on from the fight is out of it: shift81's replay held Opus's spidertron 900 s)
            if v and v["surface"] == b["surface"] and self.vehicle_activity(a, now) in ("fighting", "firing"):
                d = dist(v, b["position"])
                if d <= self.cfg["battle_near"] + (b.get("extent") or 0) / 2 and (best is None or d < best[0]):
                    best = (d, a["name"])
        if best:
            return best[1]
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
                b["lost"], b["loss_text"] = loss_pieces(f.get("text")), f.get("text")
        b["agent"] = self.battle_agent(b, by_name, now)
        v = self.vehicle_spot(by_name.get(b["agent"]), now, held=True) if b["agent"] else None
        if v and v["surface"] == b["surface"]:
            b["position"] = {"x": v["x"], "y": v["y"]}  # (batch245) a vehicle's fight moves with the vehicle
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
            if b.get("aired"):
                self.battle_spots = (self.battle_spots + [(now, b)])[-20:]
            if cfg["battle_all"]:
                self.watch_battle(by_name, now)  # (batch245) a fight that waited for it follows on: no cut between

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
            if self.threats.decide("group", f"group:{gid}", score, parts, now, blocked=blocked, where=self.group_where(g)):
                self.follow_group(g, score, scores, now)
            elif not self.group_contact(g):
                self.group_pips = [q for q in self.group_pips if now - q[1] <= cfg["group_pip_wait"]] + [(gid, now)]

    @staticmethod
    def group_where(g):
        """(batch245) A group's place in the director log: its position, target and size (a replay can rebuild it)."""
        out = {"surface": g.get("surface") or "nauvis", "size": g.get("size")}
        for k in ("position", "target"):
            if isinstance(g.get(k), dict) and g[k].get("x") is not None:
                out[k] = {"x": round(g[k]["x"], 1), "y": round(g[k]["y"], 1)}
        if g.get("nearest_distance") is not None:
            out["nearest"] = round(g["nearest_distance"], 1)
        return out

    def maybe_group_pip(self, snapshot, by_name, scores, now):
        """(d26 batch245 MB) An enemy group on its way that the program does not follow (its score under the bar,
        spacing, or the camera held: shift81 showed 2 of 16): the inset follows it (a fixed view that pans with it,
        "Incoming · 18 biters and spitters heading for ...") for group_pip_max, until contact (its fight is a battle
        on the program), or until it is gone, turns back or stops. Alerts take the inset first; only a group seen
        within group_pip_wait goes up."""
        cfg = self.cfg
        rows = {g["id"]: g for g in snapshot.get("incoming") or [] if g.get("id") is not None and g.get("position")}
        ins = self.inset
        if ins and ins.get("why") == "group":
            g = rows.get(ins["group"])
            near = (g or {}).get("nearest_distance")
            if g and near is not None:
                ins["closest"] = min(ins.get("closest", near), near)
            why = ("gone" if not g else "contact" if self.group_contact(g) else "on the program" if self.incoming
                   else f"{int(cfg['group_pip_max'])} s up" if now >= ins["end"]
                   else "turned back" if near is not None and near - ins["closest"] >= cfg["incoming_away"] else None)
            if why:
                self.inset = None
                print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} group inset over ({why}): "
                      f"{ins['label']}", flush=True)
                return
            t = self.state.get(ins["slot"]) or {}
            ins["until"] = now + 10
            if t.get("position") and dist(t["position"], g["position"]) > 3:  # pan with it
                self.apply(self.slot(ins["slot"]), dict(t, position=dict(g["position"]), jump=False, until=ins["until"]),
                           "group inset: pan", scores, now, quiet=True)
            return
        if not cfg["group_pip"] or self.mode == "trio" or self.hold_layout or self.pending or self.incoming or \
                (ins and ins.get("why") not in ("attention", "cue")):
            return
        self.group_pips = [q for q in self.group_pips if now - q[1] <= cfg["group_pip_wait"] and q[0] in rows]
        for gid, seen in reversed(self.group_pips):
            g = rows[gid]
            if self.group_contact(g):
                continue
            sb = self.standbys()
            slot = self.slot(ins["slot"]) if ins else self.inset_free(sb)
            if not slot:
                return
            label = f"Incoming · {g.get('label') or 'enemies on the way'}"
            target = {"agents": [], "subject": "@enemy", "position": dict(g["position"]),
                      "surface": g.get("surface") or "nauvis", "zoom": cfg["incoming_zoom"], "exact_zoom": True,
                      "until": now + 10, "enemy": label}
            if ins and ins.get("why") == "attention":
                self.last_attn = now
            self.frame_on(slot, target, f"group inset: {label} (group:{gid})", scores, now)
            self.inset = {"slot": slot["slot"], "until": now + 10, "why": "group", "group": gid, "label": label,
                          "end": now + cfg["group_pip_max"]}
            self.group_pips.remove((gid, seen))
            return

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
        v = self.vehicle_spot(by_name.get(n), self.step_t, held=True) if n else None
        if v and v["surface"] == b["surface"] and dist(v, b["position"]) <= self.cfg["battle_near"] + b["extent"] / 2:
            # (batch245) its vehicle by remote view in the fight: that vehicle's shot, the battle's area moving with it
            z = min(self.cfg["attack_zoom"], self.cfg["vehicle_zoom"])
            return {"agents": [n], "subject": n, "position": {"x": v["x"], "y": v["y"]}, "surface": v["surface"],
                    "zoom": z, "solo_zoom": z, "exact_zoom": True, "vehicle": v["label"], "battle": b["key"]}
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
            cur.get("battle") == b["key"] or want["subject"] != "@battle" or self.in_battle(cpos)) and \
            bool(cur.get("vehicle")) == bool(want.get("vehicle"))  # (batch245: its body is not its vehicle's fight)
        if same:  # on it already: reframed in place (zoom, centre), never a cut
            cur["battle"] = b["key"]
            b["aired"] = True
            if want.get("vehicle"):
                self.keep_vehicle(cur, by_name, now)  # (batch245) moved with the vehicle, led like any vehicle shot
                return
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
            slot = self.slot(ins["slot"]) if ins else self.inset_free(sb)
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
        if (self.inset and self.inset.get("why") not in ("attention", "cue", "departure")) or self.inset_free(self.standbys()) is None:
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
                slot = self.slot(self.inset["slot"]) if self.inset else self.inset_free(self.standbys())
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
        worm turret'; (batch224) a flare's shell: '💥 Artillery · Opus's flare → big spitter nest (-1392, 48), with 1
        medium worm turret · artillery turret (-273, -558), 1273 tiles'"""
        piece, t = sh.get("piece") or {}, sh.get("target") or {}
        by = sh.get("by") or piece.get("by")
        who = next((a.get("display_name") or a["name"] for a in by_name.values() if by and a["name"].lower() == str(by).lower()), by)
        pp, tp = sh.get("from") or piece.get("position") or {}, t.get("position") or {}
        where = f"({round(tp.get('x', 0))}, {round(tp.get('y', 0))})"
        if sh.get("flare"):
            text = (f"💥 Artillery · {who + chr(39) + 's' if who else 'Our'} flare → "
                    f"{self.arty_name(t['name']) + ' ' if t.get('name') else ''}{where}")
            if t.get("around"):
                text += f", with {self.arty_name(t['around'])}"
            text += (f" · {self.arty_name(piece.get('name') or 'artillery')} ({round(pp.get('x', 0))}, "
                     f"{round(pp.get('y', 0))})")
            return text + (f", {sh['distance']} tiles" if sh.get("distance") else "")
        text = (f"💥 Artillery · {who + chr(39) + 's' if who else 'Our'} {self.arty_name(piece.get('name') or 'artillery')} "
                f"({round(pp.get('x', 0))}, {round(pp.get('y', 0))}) → {self.arty_name(t.get('name'))} {where}")
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
        target if nothing outranks it and it lands at least arty_lead from now, at most arty_gap after the last
        artillery shot ended; held arty_after past the impact, longer (up to arty_max) while more shells land there
        (arty_joins). (batch224) A shell landing later than arty_pre is kept (arty_queue) and judged arty_pre before it
        lands; a barrage's frame follows the impacts due next (arty_frame). Each decision is logged."""
        cfg = self.cfg
        if not cfg["artillery"]:
            return
        art = snapshot.get("artillery") or {}
        read_at = float(art.get("read_at") or now)
        for sh in art.get("shells") or []:
            key = sh.get("key")
            t = (sh.get("target") or {}).get("position")
            if not key or not t or key in self.arty_seen:
                continue
            self.arty_seen.add(key)
            self.arty_queue.append({"sh": sh, "key": key, "lands": read_at + float(sh.get("eta_ticks") or 0) / 60.0})
        due = sorted((q for q in self.arty_queue if q["lands"] - now <= cfg["arty_pre"]), key=lambda q: q["lands"])
        self.arty_queue = [q for q in self.arty_queue if q["lands"] - now > cfg["arty_pre"]]
        cur = self.state.get(self.onair) or {}
        shot = cur.get("artillery") if now < cur.get("until", 0) else None
        pend = self.state.get(self.pending["slot"]) if self.pending else None
        if not shot and pend and pend.get("artillery"):  # (batch224) a shot still framed on its standby takes them too
            cur, shot = pend, pend["artillery"]
        if not shot and now < self.arty_end:
            self.arty_end = now  # the shot was cut short (an urgent shot, a look): the spacing counts from now
        for q in due:
            sh, key, lands = q["sh"], q["key"], q["lands"]
            t = sh["target"]["position"]
            if shot:  # a shot on air: a shell landing there (or a barrage's, flared by the same agent) holds it longer
                if self.arty_joins(shot, sh):
                    cur["until"] = min(shot["since"] + cfg["arty_max"], max(cur["until"], lands + cfg["arty_after"]))
                    self.arty_end = max(self.arty_end, cur["until"])
                    shot["shells"] += 1
                    shot.setdefault("spots", []).append((lands, t["x"], t["y"]))
                    if shot.get("label"):
                        cur["work"] = f"{shot['label']} · {shot['shells']} shells"
                continue
            label = self.arty_label(sh, by_name)
            lead = lands - now
            if lead < cfg["arty_lead"]:
                decision, why = "drop", f"lands in {lead:.1f} s"
            elif now < self.arty_end + cfg["arty_gap"]:
                decision, why = "drop", f"spacing: the last artillery shot ended {int(now - self.arty_end)} s ago"
            else:
                busy = self.arty_busy(by_name, now, segment)
                decision, why = ("drop", busy) if busy else ("cut", f"nothing more interesting on air; lands in {lead:.1f} s")
            if decision == "cut":
                shot = {"surface": sh.get("surface"), "target": t, "since": now, "shells": 1, "key": key,
                        "spots": [(lands, t["x"], t["y"])], "center": dict(t), "moved": now, "label": label,
                        "flare_by": str((sh.get("flare") or {}).get("by") or "").lower() or None}
                target = {"agents": [], "subject": "@work", "position": {"x": t["x"], "y": t["y"]},
                          "surface": sh.get("surface") or "nauvis", "zoom": cfg["arty_zoom"], "exact_zoom": True,
                          "until": min(now + cfg["arty_max"], lands + cfg["arty_after"]), "work": label, "artillery": shot}
                self.urgent(target, f"artillery: {label}", scores, now)
                if self.pending:  # framed on a standby: cut in time for the impact
                    self.pending["ready_s"] = max(0.2, min(cfg["ready_s"], lead - 0.5))
                self.last_arty = now
                self.arty_end = target["until"]
                # (d22 batch89 AY5) the next shells of this read hold the new shot, not the state that was on air
                # (shift57 07:50:12: KeyError 'until' on a state without one); urgent() keeps a copy, on air or on the
                # standby, sharing this shot
                cur = next((st for st in self.state.values() if isinstance(st, dict) and st.get("artillery") is shot), target)
            self.artys.append((now, decision, why, label))
            said = why.split(":")[0]
            if decision == "drop" and now - self.arty_said.get(said, -1e9) < 10.0:
                continue  # (batch224) a barrage's shells dropped for one reason: logged once per 10 s
            self.arty_said[said] = now
            entry = {"key": key, "decision": decision, "why": why, "label": label, "lead": round(lead, 2)}
            if self.log_path:
                with open(self.log_path, "a") as f:
                    f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                        "slot": "program", "reason": f"artillery {decision}: {why}", "artillery": entry}) + "\n")
            print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} artillery {decision} ({why}): {label}", flush=True)
        if shot and self.onair and (self.state.get(self.onair) or {}).get("artillery") is shot:
            self.arty_frame(self.state[self.onair], shot, now)
        if len(self.arty_seen) > 2000:
            self.arty_seen = set(list(self.arty_seen)[-500:])

    def arty_joins(self, shot, sh):
        """(batch224) A shell holds the shot on air: on its surface, landing within arty_near of where it looks or of
        its first target, or a flare's shell by the agent whose flare it shows."""
        t = sh["target"]["position"]
        if (sh.get("surface") or "nauvis") != (shot.get("surface") or "nauvis"):
            return False
        near = self.cfg["arty_near"]
        if dist(t, shot["target"]) <= near or dist(t, shot.get("center") or shot["target"]) <= near:
            return True
        by = str((sh.get("flare") or {}).get("by") or "").lower()
        return bool(by) and by == shot.get("flare_by")

    def arty_frame(self, cur, shot, now):
        """(batch224) A barrage on air: the frame on the impacts due next (landed in the last 1.5 s or landing within
        arty_pre), the group round the first of them, wide enough for them all (arty_zoom down to arty_zoom_min); moved
        as a glide at most every arty_move."""
        cfg = self.cfg
        if self.pending or now - shot.get("moved", -1e9) < cfg["arty_move"]:
            return
        win = [p for p in shot.get("spots") or [] if now - 1.5 <= p[0] <= now + cfg["arty_pre"]]
        if not win:
            return
        first = min(win, key=lambda p: (p[0] < now, abs(p[0] - now)))
        group = [p for p in win if math.hypot(p[1] - first[1], p[2] - first[2]) <= cfg["arty_near"]]
        cx, cy = sum(p[1] for p in group) / len(group), sum(p[2] for p in group) / len(group)
        ext = 2 * max(math.hypot(p[1] - cx, p[2] - cy) for p in group) + 16
        z = round(max(cfg["arty_zoom_min"], min(cfg["arty_zoom"], self.fight_zoom(ext))), 2)
        p = cur.get("position") or {}
        d = dist({"x": cx, "y": cy}, p) if p else 1e9
        if d < cfg["reframe_tiles"] and abs(z - cur.get("zoom", z)) < cfg["zoom_delta"]:
            return
        target = {k: v for k, v in cur.items() if k != "jump"}
        target.update(position={"x": round(cx, 1), "y": round(cy, 1)}, zoom=z, exact_zoom=True,
                      glide=round(max(2.0, d / 1.5), 2))  # (batch232: tiles/s, as cameras.lua reads it; was 0.5-2)
        shot["center"], shot["moved"] = {"x": cx, "y": cy}, now
        self.apply(self.slot(self.onair), target, "reframe", {}, now, quiet=True)

    # -- rocket launches (batch257) ----------------------------------------------------------------------------
    def watch_silos(self, snapshot, now):
        """(batch257) The silos' latest read (snapshot silos, launches.SiloFeed): a silo ordered to launch is due
        (launch_due: its lift-off at the soonest and latest, wall time, narrowed by each later read); its rocket seen
        flying is noted (silo_lifted); a silo past both is no longer due."""
        sil = snapshot.get("silos") or {}
        at = sil.get("read_at")
        if not isinstance(at, (int, float)) or at == self.silo_read_at:
            return
        self.silo_read_at = at
        for r in sil.get("rows") or []:
            if not isinstance(r, dict) or not isinstance(r.get("x"), (int, float)) or not isinstance(r.get("y"), (int, float)):
                continue
            k = f"{r.get('surface')}@{r['x']:g},{r['y']:g}"
            st = r.get("status")
            self.silo_status[k] = st
            lift = r.get("lift")
            d = self.launch_due.get(k)
            if isinstance(lift, (list, tuple)) and len(lift) == 2:
                lo, hi = float(lift[0]), float(lift[1])
                if d and max(d["lift"][0], lo) <= min(d["lift"][1], hi):
                    lo, hi = max(d["lift"][0], lo), min(d["lift"][1], hi)
                self.launch_due[k] = {"key": k, "surface": str(r.get("surface") or "nauvis"),
                                      "position": {"x": float(r["x"]), "y": float(r["y"])}, "lift": (lo, hi),
                                      "to": r.get("to") or (d or {}).get("to"), "seen": (d or {}).get("seen", at)}
                self.silo_lifted.pop(k, None)
            elif st == 11:
                self.silo_lifted.setdefault(k, at)
                self.launch_due.pop(k, None)
            else:
                self.launch_due.pop(k, None)
                self.silo_lifted.pop(k, None)
        for k in [k for k, d in self.launch_due.items() if now > d["lift"][1] + 10.0]:
            self.launch_due.pop(k)  # (a read that never came)

    def launch_quiet(self, by_name, scores, now, segment):
        """(batch257) Why a launch may take the program now, or None: the story on air (an agent) standing still or on
        a loop launch_still and on air launch_air, without news of its own, nobody else moving or with news, nothing
        held or framed, no fight, launch_gap since the last launch shot (quiet_now's test, sooner); (batch267) no platform
        build waiting (maybe_work's builds_waiting)."""
        cfg = self.cfg
        cur = self.state.get(self.onair) or {}
        subj = cur.get("subject")
        if self.mode != "onecam" or self.plat_busy(now, segment) or subj not in scores or self.builds_waiting or \
                now - self.launch_end < cfg["launch_gap"] or now - self.last_program_cut < cfg["cut_spacing"] or \
                self.fighting(subj, by_name, now) or big_plan(by_name[subj]) or \
                any(now - self.fight_t(f) < cfg["fight_quiet"] for f in self.fight_list):
            return None
        stale = self.stale_s(subj, now)
        if cur.get("vehicle"):
            if not self.vehicle_stuck_s(subj, now):
                return None  # its vehicle on its way: moving
            stale = max(stale, self.vehicle_stuck_s(subj, now))
        if stale < cfg["launch_still"] or now - self.onair_since < cfg["launch_air"] or self.newsworthy(subj, now):
            return None  # (its own news: the story holds, as the story rules hold it)
        for n in scores:
            if n != subj and (self.newsworthy(n, now) or self.stale_s(n, now) < cfg["moving_s"]):
                return None  # someone to cut to: the story rules do
        return f"{subj} {'on a loop' if self.loop_s(subj, now) else 'still'} {int(stale)} s"

    def launch_label(self, group):
        planet = group[0]["surface"]
        to = sorted({d["to"] for d in group if d.get("to")})
        return f"Rocket launch · {planet[:1].upper() + planet[1:]}" + (f" · to {', '.join(to[:2])}" if to else "") + \
            (f" · {len(group)} rockets" if len(group) > 1 else "")

    def maybe_launch(self, snapshot, by_name, scores, now, segment=None):
        """(batch257 IB) A rocket about to lift off instead of a story standing still (launch_quiet): the launch due
        soonest enough ahead (launch_lead to launch_wait), from the planet a launch shot showed longest ago (then the one
        with the least air in surface_window); the silos of its planet launching within the frame with it. Framed on a
        standby north of the silos, cut before lift-off, held through the flight (launch_hold); then the story."""
        cfg = self.cfg
        if not cfg["launch"]:
            return
        cur = self.state.get(self.onair) or {}
        shot = cur.get("launch") if now < cur.get("until", 0) else None
        if shot:
            self.launch_hold(cur, shot, now)
            return
        if self.pending and (self.state.get(self.pending["slot"]) or {}).get("launch"):
            return  # being framed on its standby
        if self.launch_end > now:
            self.launch_end = now  # the shot was cut short: the gap counts from now
        due = [d for d in self.launch_due.values() if cfg["launch_lead"] <= d["lift"][0] - now and
               d["lift"][1] - now <= cfg["launch_wait"]]
        if not due:
            return
        why = self.launch_quiet(by_name, scores, now, segment)
        if not why:
            return
        share = self.surface_shares(now)
        pick = min(due, key=lambda d: (self.launch_surface_t.get(d["surface"], -1e9), share.get(d["surface"], 0.0),
                                       d["lift"][0], d["key"]))
        group = sorted((d for d in self.launch_due.values() if d["surface"] == pick["surface"] and
                        d["lift"][0] - now >= cfg["launch_lead"] - 1.0 and
                        dist(d["position"], pick["position"]) <= cfg["launch_near"]), key=lambda d: d["key"])
        cx = sum(d["position"]["x"] for d in group) / len(group)
        cy = sum(d["position"]["y"] for d in group) / len(group)
        ext = 2 * max(math.hypot(d["position"]["x"] - cx, d["position"]["y"] - cy) for d in group) + 24
        z = round(max(cfg["launch_zoom_min"], min(cfg["launch_zoom"], self.fight_zoom(ext))), 2)
        label = self.launch_label(group)
        lead = pick["lift"][0] - now
        until = min(now + cfg["launch_max"], max(d["lift"][1] for d in group) + cfg["launch_after"])
        shot = {"keys": [d["key"] for d in group], "surface": pick["surface"], "since": now, "label": label,
                "center": {"x": cx, "y": cy}}
        target = {"agents": [], "subject": "@work", "position": {"x": round(cx, 1), "y": round(cy - cfg["launch_up"], 1)},
                  "surface": pick["surface"], "zoom": z, "exact_zoom": True, "until": until, "work": label, "launch": shot}
        self.urgent(target, f"launch: {label} ({why})", scores, now)
        if self.pending:  # framed on a standby: the cut before lift-off
            self.pending["ready_s"] = max(0.2, min(cfg["ready_s"], lead - 0.5))
        self.launch_end = until
        self.launch_surface_t[pick["surface"]] = now
        for d in group:
            self.launch_due.pop(d["key"], None)
        self.launch_log.append((now, label, shot["keys"], round(lead, 1)))
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"launch take: {label} ({why})",
                                    "launch": {"keys": shot["keys"], "lead": round(lead, 1), "zoom": z,
                                               "lift": [round(x, 1) for x in pick["lift"]]}}) + "\n")
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} launch: {label}, lift-off in "
              f"{lead:.1f}-{pick['lift'][1] - now:.1f} s ({why})", flush=True)

    def launch_hold(self, cur, shot, now):
        """(batch257) A launch shot on air: another silo of its planet launching inside its frame holds it longer (up
        to launch_max); once every rocket of it has lifted off, it ends launch_after after the last lift-off read; a
        silo past its flight (the next rocket rising, the doors closing) ends it at once."""
        cfg = self.cfg
        hx, hy = self.frame_half(cur.get("game_zoom") or cur.get("zoom") or cfg["launch_zoom"])
        p = cur.get("position") or {}
        for d in list(self.launch_due.values()):
            if d["key"] in shot["keys"] or d["surface"] != shot["surface"] or not p or \
                    abs(d["position"]["x"] - p["x"]) > hx - 6 or not -hy + 4 <= d["position"]["y"] - p["y"] <= hy - 2:
                continue
            shot["keys"].append(d["key"])
            cur["until"] = min(shot["since"] + cfg["launch_max"], max(cur["until"], d["lift"][1] + cfg["launch_after"]))
            self.launch_due.pop(d["key"])
        lift_at = shot.setdefault("lift_at", {})
        for k in shot["keys"]:
            if k in lift_at:
                continue
            if self.silo_lifted.get(k):
                lift_at[k] = self.silo_lifted[k]
            elif self.silo_status.get(k) not in (8, 14, 9, 10, 11, None) and (self.silo_read_at or 0) > shot["since"]:
                lift_at[k] = self.silo_read_at - 3.0  # past its flight by this read (a read missed)
        if len(lift_at) == len(shot["keys"]):
            end = max(lift_at.values()) + cfg["launch_after"]
            if all(self.silo_status.get(k) not in (8, 14, 9, 10, 11) for k in shot["keys"]):
                end = min(end, now + 1.0)  # every rocket gone by the last read
            cur["until"] = min(cur["until"], max(end, now))
        shot["lifted"] = bool(lift_at)
        self.launch_end = cur["until"]

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
        if not att or self.inset_free(sb) is None:
            return  # (the first standby frames the next subject; the last one takes insets)
        self.show_attention(self.inset_free(sb)["slot"], subj, by_name[subj], att, scores, now)

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
        if not cfg["map_every"] or self.n_clients() < 2 or self.mode != "onecam":
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

    # -- (batch222 CD) quiet time: base tours, platform visits, the base map -------------------------------------
    def set_tours(self, tours):
        """basetour.Tours (serve.py: the run's chart), or None: no base tours."""
        self.tours = tours

    def tour_target(self, now):
        """The next planet's base tour (the one toured longest ago with a plan), as a held shot, or None."""
        if not self.tours:
            return None
        import basetour
        for surface in sorted(self.tours.planets, key=lambda s: (self.toured.get(s, -1e9), basetour.PLANETS.index(s)
                                                                 if s in basetour.PLANETS else 9)):
            plan = self.tours.get(surface, self.cfg["view_frac"])
            if not plan:
                continue
            return {"agents": [], "subject": "@tour", "position": dict(plan["position"]), "surface": surface,
                    "zoom": plan["zoom"], "exact_zoom": True, "move": plan["move"], "moved": now,
                    "until": now + self.cfg["ready_s"] + plan["seconds"],
                    "look": {"label": plan["label"], "by": "director", "surface": surface, "position": dict(plan["position"])},
                    "tour": {"surface": surface, "label": plan["label"], "machines": plan["machines"]}}
        return None

    def show_tour(self, t, why, scores, now):
        """On air via a standby (its move plays from the framing: the pan starts its REST_S after, about when the cut
        lands); one client: the client on air."""
        self.toured[t["tour"]["surface"]] = self.last_tour = now
        self.tour_shots.append((now, t["tour"]["surface"], t["tour"]["label"]))
        self.urgent(t, f"tour: {t['tour']['label']} ({why})", scores, now)

    def quiet_now(self, by_name, scores, now, segment):
        """Why it is quiet now (module doc, quiet_story), or None."""
        cfg = self.cfg
        cur = self.state.get(self.onair) or {}
        subj = cur.get("subject")
        if self.mode != "onecam" or self.plat_busy(now, segment) or self.inset or subj not in scores or \
                now < cur.get("hold_until", 0) or self.fighting(subj, by_name, now) or big_plan(by_name[subj]) or \
                any(now - self.fight_t(f) < cfg["fight_quiet"] for f in self.fight_list):
            return None
        stale = self.stale_s(subj, now)
        need = cfg["quiet_story"]
        if cur.get("vehicle") and self.vehicle_stuck_s(subj, now):
            need = cfg["vehicle_stuck"]  # (batch245) a stuck vehicle's unchanged scene: sooner
            stale = max(stale, self.vehicle_stuck_s(subj, now))
        if stale < need or now - self.onair_since < need:
            return None
        for n in scores:
            if n != subj and (self.newsworthy(n, now) or self.stale_s(n, now) < cfg["moving_s"]):
                return None  # someone to cut to: the story rules do
        return f"{subj} {'on a loop' if self.loop_s(subj, now) else 'still'} {int(stale)} s"

    def quiet_log(self, kind, label, why, now):
        self.last_quiet = self.quiet_shown[kind] = now
        self.after_quiet = True
        self.quiets.append((now, kind, label, why))
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"quiet {kind}: {label} ({why})", "target": None}) + "\n")

    def maybe_quiet(self, by_name, scores, now, segment=None):
        """Quiet time (module doc): the quiet view shown longest ago of a base tour, a platform visit, the base map."""
        cfg = self.cfg
        cur = self.state.get(self.onair) or {}
        gap = cfg["vehicle_stuck"] if cur.get("vehicle") and self.vehicle_stuck_s(cur.get("subject"), now) else cfg["quiet_gap"]
        if now - self.last_quiet < gap or self.pending or self.trio_pending or self.hold_layout:
            return  # (batch245: a stuck vehicle's scene waits no quiet_gap)
        why = self.quiet_now(by_name, scores, now, segment)
        if not why:
            return
        views = []
        tour = self.tour_target(now)
        if tour:
            views.append(("tour", tour))
        if self.n_clients() >= 2:
            plats = sorted(n for n, p in self.plat_rows.items() if (p.get("view") or {}).get("surface"))
            if plats:
                name = min(plats, key=lambda n: (self.plat_shown.get(n, -1e9), n))
                t = self.platform_target(name, "visit", now + cfg["ready_s"] + cfg["quiet_platform_hold"])
                if t and self.pan_hold(t) > cfg["quiet_platform_hold"]:
                    t["until"] = now + cfg["ready_s"] + self.pan_hold(t)
                if t:
                    views.append(("platform", t))
            m = self.map_target((1208, 1032), now + cfg["ready_s"] + cfg["map_hold"], cfg["view_frac"])
            if m:
                views.append(("map", m))
        if not views:
            return
        order = ("tour", "platform", "map")
        kind, t = min(views, key=lambda kv: (self.quiet_shown.get(kv[0], -1e9), order.index(kv[0])))
        if kind == "tour":
            self.quiet_log(kind, t["tour"]["label"], why, now)
            self.show_tour(t, f"quiet: {why}", scores, now)
        elif kind == "platform":
            self.quiet_log(kind, t["platform"]["label"], why, now)
            self.last_platform = now
            self.show_platform(t, scores, now)
        else:
            self.quiet_log(kind, "Base map", why, now)
            self.last_map = now
            self.maps.append((now, "quiet"))
            self.urgent(t, f"base map (quiet: {why})", scores, now)

    def maybe_tour(self, scores, now, segment=None):
        """A base tour about every tour_every (tour_first after the start), with the base map's guards; one client too."""
        cfg = self.cfg
        if not cfg["tour_every"] or not self.tours or self.mode != "onecam":
            return
        last = self.last_tour if self.last_tour is not None else self.started - cfg["tour_every"] + cfg["tour_first"]
        if now - last < cfg["tour_every"]:
            return
        cur = self.state.get(self.onair)
        if (self.hold_layout or self.pending or self.inset or self.trio_pending or segment or
                (cur and cur.get("subject") in HOLDS and now < cur.get("until", 0)) or
                (cur and now < cur.get("hold_until", 0)) or
                now - self.last_program_cut < cfg["map_gap"] or now - self.last_quiet < cfg["quiet_gap"] or
                any(now - self.fight_t(f) < cfg["fight_quiet"] for f in self.fight_list)):
            return
        t = self.tour_target(now)
        if t:
            self.last_quiet = self.quiet_shown["tour"] = now
            self.show_tour(t, f"every {int(cfg['tour_every'] // 60)} min", scores, now)

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
        if not due or self.n_clients() < 2 or self.mode != "onecam":
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

    def work_close(self, w, view, who, name):
        """(d28 batch312 A) The close-up of a build that names where it lands: {position, zoom, caption}. The box is the
        request's (extent: its entries or area), the zoom fits it with work_close_margin at the on-air width, from
        work_close_min to work_spot_zoom (a position alone: work_spot_zoom); the caption: who, what the request names, where on the ship (the hull's
        thirds from its bounds, bow north: "near the bow, port side")."""
        cfg = self.cfg
        p = w["position"]
        e = w.get("extent") or {}
        lo, hi = cfg["work_close_min"], cfg["work_spot_zoom"]
        try:
            left, top, right, bottom = (float(e[k]) for k in ("left", "top", "right", "bottom"))
            m = cfg["work_close_margin"]
            fit = min(60.0 * self.onair_frac() / (right - left + m), 34.0 / (bottom - top + m))
        except (KeyError, TypeError, ValueError):  # a position alone: work_spot_zoom there
            left = right = float(p["x"])
            top = bottom = float(p["y"])
            fit = hi
        zoom = round(max(lo, min(hi, fit)), 2)
        cx, cy = round((left + right) / 2, 1), round((top + bottom) / 2, 1)
        what = w.get("what") or []
        n = sum(c for _, c in what)
        named = ", ".join(f"{c} {k.replace('-', ' ')}" for k, c in what[:3]) + (f" and {len(what) - 3} more kinds" if len(what) > 3 else "")
        verb = w.get("verb") or "building"
        doing = f"placing {n} ghost{'s' if n != 1 else ''} ({named})" if w.get("action") == "place_ghosts" and n else verb
        b = view.get("bounds") or {}
        where = ""
        if all(isinstance(b.get(k), (int, float)) for k in ("left", "top", "right", "bottom")) and b["right"] > b["left"] and b["bottom"] > b["top"]:
            fy = (cy - b["top"]) / (b["bottom"] - b["top"])
            fx = (cx - b["left"]) / (b["right"] - b["left"])
            along = "near the bow" if fy < 1 / 3 else "near the stern" if fy > 2 / 3 else "midships"
            side = "port side" if fx < 1 / 3 else "starboard side" if fx > 2 / 3 else "on the centre line"
            where = f"{along}, {side}"
        cut = " (part of it)" if fit < lo - 1e-9 else ""
        # (the overlay drops the leading name and puts "· " before the rest, as for "Sol building on Starling")
        head = f"{who} {doing} on {name}"
        return {"position": {"x": cx, "y": cy}, "zoom": zoom, "caption": f"{head} · {where}{cut}" if where else head + cut,
                "overview": f"{head} · whole ship" + (f", the work {where}" if where else "")}

    def closeup_step(self, now):
        """(d28 batch312 A) The shot on air that opened on the whole ship for a build (`closeup`): after work_overview_s on
        air the camera glides to the work's close-up, its caption says what and where. A new shot drops it."""
        t = self.state.get(self.onair)
        c = (t or {}).get("closeup")
        if not c or c.get("done") or now < self.onair_since + self.cfg["work_overview_s"] or now >= t.get("until", now + 1):
            return
        c["done"] = now
        target = {k: v for k, v in t.items() if k not in ("jump", "pan")}
        dist = math.hypot(c["position"]["x"] - t["position"]["x"], c["position"]["y"] - t["position"]["y"]) if t.get("position") else 0
        target.update(position=dict(c["position"]), zoom=c["zoom"], solo_zoom=c["zoom"], exact_zoom=True, work=c["caption"],
                      glide=round(max(2.0, dist / 1.5), 2))  # about 1.5 s to the work, the zoom eased in on the way
        t.pop("pan", None)
        t.update(position=target["position"], zoom=c["zoom"], solo_zoom=c["zoom"], work=c["caption"])
        self.apply(self.slot(self.onair), target, f"work close-up: {c['caption']}", {}, now, quiet=True)

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
        if not rows or self.n_clients() < 2:
            return
        busy = bool(self.hold_layout or self.pending or self.trio_pending or segment or
                    (cur and now < cur.get("hold_until", 0)) or
                    (cur and cur.get("subject") in HOLDS and now < cur.get("until", 0) and
                     not (cur.get("subject") == "@platform" and cp.get("why") in ("visit", "work", "departure", "cue", "edge", "bow"))))
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
        if not due or self.n_clients() < 2:
            return
        cur = self.state.get(self.onair)
        cp = (cur or {}).get("platform") or {}
        busy = bool(self.hold_layout or self.pending or self.trio_pending or segment or
                    (cur and now < cur.get("hold_until", 0)) or
                    (cur and cur.get("subject") in HOLDS and now < cur.get("until", 0) and
                     not (cur.get("subject") == "@platform" and cp.get("why") in ("visit", "work", "departure", "cue", "bow"))))
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

    def bow_round(self, scores, now):
        """(QM1) Why a bow shot may go on air now, or None: not within bow_gap of the last one (bow_first after the
        start), and the round over: every agent on air in the last bow_window (and still here) had a story since the
        last bow shot, or bow_round_max has passed."""
        cfg, last = self.cfg, self.last_bow
        if last is None:
            return "the first" if now - self.started >= cfg["bow_first"] else None
        if now - last < cfg["bow_gap"]:
            return None
        if now - last >= cfg["bow_round_max"]:
            return f"{int(now - last)} s since the last"
        seen = [n for n in scores if now - self.last_on_air.get(n, -1e9) <= cfg["bow_window"]]
        if all(self.last_on_air.get(n, -1e9) > last for n in seen):
            return f"round over ({len(seen)} agents on air since the last)"
        return None

    def bow_target(self, name, until):
        """(QM1) A fixed view on a ship's bow: the bow's x extent fitted across (view `bow`: the foundation in the hull's
        first rows, live.py add_hulls), its north edge bow_ahead down the frame so the space ahead shows; None without
        a bow read."""
        row = self.plat_rows.get(name) or {}
        view, bow = row.get("view") or {}, (row.get("view") or {}).get("bow")
        if not view.get("surface") or not isinstance(bow, dict) or \
                not all(isinstance(bow.get(k), (int, float)) for k in ("left", "top", "right")):
            return None
        frac, ahead_frac = self.onair_frac(), self.cfg["bow_ahead"]
        zoom = round(max(0.3, min(1.0, 60.0 * frac / (bow["right"] - bow["left"] + 12))), 2)
        left, right = bow["left"], bow["right"]
        # (d24 batch188 QAD1, viewer Caleb 19:15: "when showing Asterion's bow can you zoom out enough to see the
        # asteroids in range?") with the guns read, the space ahead covers the turrets' reach ahead of the bow (model.
        # gun_reach: each turret +- its range) plus BOW_REACH_MARGIN, and the frame its width: the zoom that fits both,
        # no closer than the bow's own, at least 0.3, floored to the hundredth so the reach stays inside
        from model import gun_reach
        reach = gun_reach(view)
        if reach:
            rl, rt, rr, _ = reach
            left, right = min(left, rl), max(right, rr)
            ahead = bow["top"] - rt + BOW_REACH_MARGIN
            fit = min(zoom, 60.0 * frac / (right - left + 2 * BOW_REACH_MARGIN))
            if ahead > 0:
                fit = min(fit, 34.0 * ahead_frac / ahead)
            zoom = max(0.3, math.floor(fit * 100) / 100)
        vh = 34.0 / zoom
        label = self.platform_label(name)
        label = f"{name} · the bow" + label[len(name):] if label.startswith(name) else f"{name} · the bow"
        return {"position": {"x": round((left + right) / 2, 1),
                             "y": round(bow["top"] + (0.5 - ahead_frac) * vh, 1)},
                "surface": view["surface"], "zoom": zoom, "exact_zoom": True, "agents": [], "subject": "@platform",
                "until": until, "platform": {"name": name, "why": "bow", "label": label}}

    def bow_turn(self, want, reason, scores, now):
        """(d24 batch170 QM1, viewer Caleb, site 14:51-14:52: "show a view of the front of Asterion when it is in flight
        for a few seconds") At a story turn (direct is about to cut to `want`): a ship flying a long leg (it has a bow
        read, which live.py takes only on a leg to or from the solar system edge or the shattered planet) gets its bow
        on air for bow_hold, at most once a round (bow_round), the ship shown longest ago first; then the story goes to
        `want`. Never over an urgent shot, a battle or a segment (those hold the camera, so no story turn comes), a
        replay, a trio or a cut being framed. True when the bow went on air."""
        cfg = self.cfg
        if not cfg["bow"] or self.plat_busy(now, None):
            return False
        ships = sorted(n for n, r in self.plat_rows.items() if self.travelling(r) and ((r.get("view") or {}).get("bow"))
                       and now - self.plat_shown.get(n, -1e9) >= cfg["bow_recent"])
        why = ships and self.bow_round(scores, now)
        if not why:
            return False
        name = min(ships, key=lambda n: (self.plat_shown.get(n, -1e9), n))
        until = now + cfg["ready_s"] + cfg["bow_hold"]
        t = self.bow_target(name, until)
        if not t:
            return False
        self.last_bow = now
        self.bows.append((now, name, why))
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} bow: {t['platform']['label']} ({why}; "
              f"then {want}: {reason})", flush=True)
        self.show_platform(t, scores, now)
        self.resume = {"subject": want, "since": until, "after": "bow"}  # the story turn it came in
        return True

    @staticmethod
    def resumed_why(r):
        return f"after the bow: {r['subject']}" if r.get("after") == "bow" else f"back to {r['subject']}"

    def maybe_departure(self, scores, now, segment=None):
        """A departure seen (watch_platforms, watch_maiden): a maiden flight or news on air for depart_hold (maiden_hold);
        a routine one (AS1) on air for depart_routine_hold when routine_turn allows, else in a free inset, else not
        shown. One that comes back after an urgent shot (it has `until`) was decided already."""
        d = self.departure
        if not d or (self.n_clients() < 2 and not d.get("maiden")):  # one camera: only a maiden flight
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
                else "no client free for an inset" if self.inset_free(sb) is None else None)
        until = now + self.cfg["ready_s"] + self.cfg["depart_routine_hold"]
        t = None if busy else self.platform_target(d["name"], "departure", until, label=d["label"])
        if not t:
            self.log_departure(d, "none", f"{why}; {busy or 'no view of the ship'}", now)
            return
        slot = self.inset_free(sb)
        self.frame_on(slot, t, f"inset departure: {d['label']}", scores, now)
        self.inset = {"slot": slot["slot"], "until": until, "why": "departure", "platform": d["name"]}
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
        if not cfg["platform_every"] or not plats or self.n_clients() < 2 or self.mode != "onecam":
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
        the agent is on air or scores near the one on air; held while its requests keep coming.
        (d27 batch267 LB) A build there (BUILD_WORK) is news for work_build_fresh, not shown yet: it takes over a story
        on air work_build_min, and a view that yields to it (yields_to_build). Repeats: a platform shown for work within
        work_repeat comes back only for a build, work_build_gap after its last work shot, closer on where it landed."""
        cfg = self.cfg
        fresh, builds = {}, {}
        for w in snapshot.get("work") or []:
            if not (w.get("platform") and w.get("agent") in by_name):
                continue
            age = now - w.get("t", -1e9)
            if w.get("action") in BUILD_WORK and age < cfg["work_build_fresh"] and \
                    w["t"] > self.work_built.get((w["agent"], w["platform"]), -1e9) and \
                    w["t"] > builds.get(w["agent"], {}).get("t", -1e9):
                builds[w["agent"]] = w
            if age < cfg["work_fresh"] and w["t"] > fresh.get(w["agent"], {}).get("t", -1e9):
                fresh[w["agent"]] = w
        # (only those that may go on air: their platform's view known, its last work shot work_build_gap ago, the agent
        # not fighting; a launch waits for these)
        self.builds_waiting = sorted((w for w in builds.values() if (w.get("view") or (self.plat_rows.get(w["platform"]) or {}).get("view"))
                                      and now - self.plat_work_shown.get(w["platform"], -1e9) >= cfg["work_build_gap"]
                                      and not self.fighting(w["agent"], by_name, now)), key=lambda w: -w["t"])
        # (d28 batch312 A) one client (POG_CAMS=1, camera panels since d28 09:13): a build moves it to the work, as a
        # maiden flight or a tour does; an inspection, settings or requests stay off (they came every few seconds)
        one = self.n_clients() < 2
        if not (fresh or builds) or (one and not self.builds_waiting):
            return
        cur = self.state.get(self.onair)
        cp = (cur or {}).get("platform") or {}
        if cp.get("why") == "work" and now < cur.get("until", 0):
            w = fresh.get(cp.get("agent"))
            b = builds.get(cp.get("agent"))
            if b and b["platform"] == cp["name"]:
                cur["build"] = True  # its agent built there while on air: shown
                self.work_built[(b["agent"], b["platform"])] = b["t"]
            if w and w["platform"] == cp["name"] and now - cur.get("since", now) < cfg["work_max"] and not cur.get("again"):
                # (batch267: a return to a platform aired within work_repeat keeps work_hold, not the requests' run)
                cur["until"] = max(cur["until"], min(now + cfg["work_hold"], cur["since"] + cfg["work_max"]))
            if not any(x["platform"] != cp["name"] for x in builds.values()) or not self.yields_to_build(cur, now):
                return  # (batch267) another platform's build takes over an inspection once it has been up work_build_min
        if self.mode != "onecam" or self.hold_layout or self.pending or self.trio_pending or segment or \
                (cur and now < cur.get("hold_until", 0)):
            return
        held = cur and cur.get("subject") in HOLDS and now < cur.get("until", 0)
        subj = (cur or {}).get("subject")
        cands = [(w, True) for w in self.builds_waiting] + \
            ([] if one else [(w, False) for _, w in sorted(fresh.items(), key=lambda kv: -kv[1]["t"])])
        for w, build in cands:
            agent, name = w["agent"], w["platform"]
            if self.fighting(agent, by_name, now):
                continue
            if held and not (build and self.yields_to_build(cur, now)):
                continue  # a timed view holds: only a build takes it, after work_build_min
            last = self.plat_work_shown.get(name, -1e9)
            if build:
                if now - last < cfg["work_build_gap"]:
                    continue
            elif now - self.work_shown.get((agent, name), -1e9) < cfg["work_gap"] or now - last < cfg["work_repeat"]:
                continue  # (batch267) the same platform's inspection again: a repeat
            if agent != subj and not held:
                if subj not in scores or now - self.last_program_cut < cfg["cut_spacing"] or \
                        self.fighting(subj, by_name, now) or big_plan(by_name[subj]):
                    continue
                if build:  # (batch267) whatever the scores, unless the story on air has news of its own
                    if now - self.onair_since < cfg["work_build_min"] or self.newsworthy(subj, now):
                        continue
                elif now - self.onair_since < cfg["onair_dwell"] or scores.get(agent, 0) < scores[subj] * cfg["work_ratio"]:
                    continue
            who = by_name[agent].get("display_name") or agent
            if name not in self.plat_rows and w.get("view"):
                self.plat_rows[name] = {"name": name, "view": w["view"]}
            until = now + cfg["ready_s"] + cfg["work_hold"]
            verb = w.get("verb") or "building"
            label = f"{who} · {verb} on {name}" if build else f"{who} · working on {name}"
            spot = w.get("position") if build else None
            view = (self.plat_rows.get(name) or {}).get("view") or w.get("view") or {}
            close = self.work_close(w, view, who, name) if isinstance(spot, dict) and spot.get("x") is not None \
                and view.get("surface") else None
            if close and now - last < cfg["work_repeat"]:
                # (batch267) a closer view of where it landed: the platform aired lately
                t = {"agents": [agent], "subject": "@platform", "position": close["position"], "surface": view["surface"],
                     "zoom": close["zoom"], "solo_zoom": close["zoom"], "exact_zoom": True, "until": until,
                     "platform": {"name": name, "why": "work", "label": label, "agent": agent}, "work": close["caption"]}
            else:
                t = self.platform_target(name, "work", until, agent=agent, label=label)
                if t and close:  # (batch312) a first visit: the whole ship work_overview_s, then the work (closeup_step)
                    t["closeup"] = close
                    t["work"] = close["overview"]
            if not t:
                continue
            t.setdefault("work", f"{who} {verb} on {name}" if build else f"{who} working on {name}")
            if build:
                t["build"] = True
                self.work_built[(agent, name)] = w["t"]
            if now - last < cfg["work_repeat"]:
                t["again"] = True
            if held:
                cur["until"] = now  # (batch267) the view on air gives way
            self.work_shown[(agent, name)] = now
            self.plat_work_shown[name] = now
            self.show_platform(t, scores, now)
            if agent != subj:
                self.resume = {"subject": agent, "since": now}  # then the agent's own character
            return

    def maybe_story(self, snapshot, by_name, scores, now, segment=None):
        """(d28 batch312 B) An operation story's beat (snapshot `stories`, stories.py), each once: the ship on air
        story_hold, captioned with the question and handoff or the result; the agent who set the watch in the inset
        once the ship is up; a result with a repaired spot goes there (work_close). It waits for a free moment as a
        build does, and holds the camera its time; urgent shots and their resumption are as for any platform shot."""
        cfg = self.cfg
        cur = self.state.get(self.onair) or {}
        cp = cur.get("platform") or {}
        on = self.story_on
        if on:
            if cp.get("story") == on["key"] and now < cur.get("until", 0):
                if not on.get("inset") and not self.inset and on["agent"] in by_name:
                    slot = self.inset_free(self.standbys())
                    if slot:  # the agent who set the watch, beside its ship
                        z = self.zoom_for(by_name[on["agent"]], cfg["solo_zoom"]) or cfg["solo_zoom"]
                        shot = self.body_shot(on["agent"], by_name, z, now)
                        until = min(cur["until"], now + cfg["story_inset_s"])
                        self.frame_on(slot, dict(shot, until=until), f"inset story: {on['who']}", scores, now)
                        self.inset = {"slot": slot["slot"], "until": until, "why": "story", "agent": on["agent"]}
                        on["inset"] = now
                return
            self.story_on = None  # its time is up, or an urgent shot took the camera: the beat aired
        if not cfg["stories"] or self.mode != "onecam" or self.plat_busy(now, segment) or self.battle:
            return
        if cp.get("why") in ("work", "danger", "operator", "story") and now < cur.get("until", 0):
            return  # a build, danger or an operator's ship on air holds
        subj = cur.get("subject")
        if (subj in by_name and self.fighting(subj, by_name, now)) or now - self.last_story < cfg["story_gap"]:
            return
        for b in snapshot.get("stories") or []:
            if b.get("key") in self.stories_shown:
                continue
            name = b.get("platform")
            view = (self.plat_rows.get(name) or {}).get("view") or {}
            if not view.get("surface"):
                continue
            until = now + cfg["ready_s"] + cfg["story_hold"]
            agent = b.get("agent")
            who = (by_name.get(agent) or {}).get("display_name") or agent
            sp = b.get("spot") if b.get("beat") == "result" else None
            if sp and isinstance(sp.get("position"), dict):
                spw = (by_name.get(sp.get("agent")) or {}).get("display_name") or sp.get("agent") or who
                close = self.work_close(dict(sp), view, spw, name)
                t = {"agents": [agent] if agent in by_name else [], "subject": "@platform", "position": close["position"],
                     "surface": view["surface"], "zoom": close["zoom"], "solo_zoom": close["zoom"], "exact_zoom": True,
                     "until": until, "platform": {"name": name, "why": "story", "label": b.get("caption") or name}}
            else:
                t = self.platform_target(name, "story", until, agent=agent if agent in by_name else None,
                                         label=b.get("caption") or name)
            if not t:
                continue
            t["platform"]["story"] = b["key"]
            t["work"] = b.get("caption") or name
            self.stories_shown.add(b["key"])
            self.last_story = now
            self.show_platform(t, scores, now)
            self.story_on = {"key": b["key"], "agent": agent, "who": who, "until": until}
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
                # (d26 batch257 IB) busy means doing something: in shift83 18.3 of the busy trios' 30 min had a standing
                # character in the big tile, mostly right after "after the quiet view: X (all stale)", the tiles still too
                if why == "busy" and cfg["trio_busy_lively"] and self.stale_s(n, now) >= cfg["still_cut"] and \
                        not self.newsworthy(n, now):
                    continue
                pick.append(n)
                if len(pick) == 2:
                    return pick, why
        return None

    def maybe_trio(self, by_name, scores, ranked, now):
        """One camera long enough, nothing urgent: frame two standbys for a trio, switch once both are there."""
        cfg = self.cfg
        if not cfg["trio"] or self.n_clients() < 3:
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
        sb = [s for s in self.standbys() if not s.get("panel")]  # a trio's tiles are clients, not panels
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
        # (d26 batch257) a check-in trio gives way to an agent off it with news after quiet_min, as a quiet view does
        # (shift81 replay 10:35: one put up 2 s after a launch shot held Opus's spidertron outing 139 s off air)
        shown = set(self.trio["agents"]) | {cur.get("subject")}
        news = next((n for n in scores if n not in shown and self.newsworthy(n, now)), None) \
            if self.trio.get("why") == "check-in" and now - self.since_mode() >= self.cfg["quiet_min"] else None
        if news:
            self.leave_trio(f"{news} fresh: {self.fresh[news][1]}", now)
            return
        # (batch267 LB) a build on a platform by an agent off the big tile, once the trio has been up work_build_min:
        # maybe_work shows it from the next step
        b = next((w for w in self.builds_waiting if w["agent"] != cur.get("subject")), None) \
            if now - self.since_mode() >= self.cfg["work_build_min"] else None
        if b:
            self.leave_trio(f"{b['agent']} building on {b['platform']}", now)
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
            # (batch240 IA) a quiet view gives way to fresh news once it has been up quiet_min
            news = any(self.newsworthy(n, now) for n in ranked if n not in self.still_block or now >= self.still_block[n])
            build = any(self.fresh_build(n, now) for n in ranked if n not in self.still_block or now >= self.still_block[n])
            if not (news and (self.after_quiet and cur.get("subject") in ("@tour", "@map", "@platform") and
                              now - self.onair_since >= self.cfg["quiet_min"] or
                              (cur.get("launch") or {}).get("lifted")) or  # (batch257) a launch once its rockets are up
                    build and self.yields_to_build(cur, now)):  # (batch267) a build: a launch, an inspection too
                return
            cur["until"] = now
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
        need_reason = None  # (batch240) why a need cut went where it did, when not the plain need_why
        dropped = None      # (batch240) the story an urgent shot cut, not taken up again (direct's need branch)
        if need:
            r, self.resume = self.resume, None
            lively = [n for n in ranked if n not in inset_agents and
                      (self.stale_s(n, now) < self.cfg["still_cut"] or self.newsworthy(n, now))]
            if r and self.after_quiet and self.stale_s(r["subject"], now) >= self.cfg["still_cut"]:
                r = None  # (batch222) a quiet view cut a stale story: not back to it, to the best lively agent
            # (batch240 IA) back from any urgent or timed shot: fresh news first, unless the story it cut has its own or
            # a big action or fight going on; and not to a story standing still while another agent acts (shift80: 51.8
            # of 125 idle minutes came back that way, 20.1 of them with an agent acting that scored as high)
            fresh = [n for n in lively if self.newsworthy(n, now)]
            dropped = r.get("dropped") if r else None
            if r and not dropped:
                rs = r["subject"]
                busy = self.newsworthy(rs, now) or (rs in by_name and (big_plan(by_name[rs]) or self.fighting(rs, by_name, now)))
                if not busy and (any(n != rs for n in fresh) or
                                 self.stale_s(rs, now) >= self.cfg["still_cut"] and any(n != rs for n in lively)):
                    dropped = rs
            if dropped:
                self.resume, r = dict(r, dropped=dropped), None  # kept so until the cut (the standby frames first)
            if r and r["subject"] in scores and r["subject"] not in inset_agents and \
                    subj in (None, "@attack", "@segment", "@map", "@platform", "@battle", "@incoming", "@work", "@look",
                             "@tour") and \
                    not (floor_reason and r["subject"] not in others):
                want, resumed = r["subject"], r  # back to the story the urgent shot interrupted
                self.resume = r  # kept until the cut back happens
            elif floor_reason and others:
                want = others[0]  # a new planet under its floor: its best-scoring agent
            elif fresh and (dropped or not r):
                want = fresh[0]  # (batch240)
                need_reason = f"{want} fresh: {self.fresh[want][1]}" + (f" ({dropped} still {int(self.stale_s(dropped, now))} s)" if dropped else "")
            elif (self.after_quiet or dropped) and lively:
                want = lively[0]
                if dropped:
                    need_reason = f"{want} moving ({dropped} still {int(self.stale_s(dropped, now))} s)"
            else:
                want = ranked[0] if ranked else None
            if want is None:
                return
        else:
            cur_v = self.state.get(self.onair) or {}
            if cur_v.get("vehicle") and self.vehicle_stuck_s(subj, now) and not cur_v.get("stuck"):
                cur_v["stuck"] = True  # (batch245 SP) a stuck vehicle's unchanged scene has served its dwell
                self.onair_since = min(self.onair_since, now - self.cfg["onair_dwell"])
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
            still = self.stale_s(subj, now)  # (batch222) standing still, or walking its short loop
            looping = self.loop_s(subj, now) > 0
            ended = now - self.plan_end.get(subj, -1e9) < cfg["onair_dwell"]
            stale = still >= (cfg["plan_after"] if ended else cfg["still_cut"])
            # (batch222) a fresh agent (fresh_cut): after onair_dwell at fresh_ratio of the story's score, after still_min
            # from a stale story whatever the scores
            fresh = [n for n in others if self.newsworthy(n, now)]
            # (batch267) a build from an agent's journal: after fresh_min whatever the scores, unless the story on air
            # has news of its own
            built = [n for n in fresh if self.fresh_build(n, now)]
            if built and not self.newsworthy(subj, now):
                fresh = built + [n for n in fresh if n not in built]
            if not want and not holding and fresh and now - self.last_program_cut >= cfg["cut_spacing"] and \
                    (held >= cfg["onair_dwell"] and scores[fresh[0]] >= scores[subj] * cfg["fresh_ratio"] or
                     stale and held >= cfg["fresh_min"] or  # (batch240: was still_min)
                     fresh[0] in built and not self.newsworthy(subj, now) and held >= cfg["fresh_min"]):
                want = cand = fresh[0]
                why = f"{plan_kind(by_name[want])} ahead" if big_plan(by_name[want]) else f"fresh: {self.fresh[want][1]}"
                reason = f"{subj} {'on a loop' if looping else 'still'} {int(still)} s; {want} {why}" if stale else \
                    f"{want} {why}"
                if stale:
                    self.still_block[subj] = now + cfg["still_block"]
            if not want and not holding and held >= cfg["still_min"] and stale:
                moving = [n for n in others if self.stale_s(n, now) < cfg["moving_s"]
                          and scores[n] >= scores[subj] * cfg["still_worth"]]
                if moving:
                    want = cand = moving[0]
                    why = f"{plan_kind(by_name[want])} ahead" if big_plan(by_name[want]) else "moving"
                    reason = f"{subj} {'on a loop' if looping else 'still'} {int(still)} s; {want} {why}"
                    self.still_block[subj] = now + cfg["still_block"]
            self.keep(cur, by_name, now)
            if self.pending:
                return  # (batch224) keep() swapped to its vehicle (or back) on a standby: that slot is taken (shift79 03:56:42)
            if want and self.bow_turn(want, reason, scores, now):
                return  # the bow first; the story goes to `want` after it
        nxt = self.next_slot()
        lead = want or cand
        if nxt and lead:
            t = self.state.get(nxt["slot"])
            fit = self.plan_zoom(by_name[lead])  # framed on its action's bounds ahead of the cut
            z = fit or self.zoom_for(by_name[lead], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            shot = self.body_shot(lead, by_name, z, now, fit)  # (batch222) or its vehicle by remote view
            # (batch245 SP) a standby on a vehicle follows it off air; far off (shift82 14:59:54: 230 tiles after 20 s
            # unmoved), it is framed anew before the cut
            off = dist(t["position"], shot["position"]) if t and t.get("vehicle") and shot.get("vehicle") and \
                t.get("position") else 0.0
            if not t or t.get("subject") != lead or abs(t["zoom"] - shot["zoom"]) >= self.cfg["zoom_delta"] or \
                    bool(t.get("vehicle")) != bool(shot.get("vehicle")) or t.get("did") != shot.get("did") or \
                    off >= self.cfg["reframe_tiles"]:
                keep_framed = t and t.get("subject") == lead and bool(t.get("vehicle")) == bool(shot.get("vehicle")) and \
                    t.get("did") == shot.get("did") and off <= min(self.frame_half(t.get("game_zoom") or shot["zoom"]))
                shot.update(jump=True, since=now, framed=t["framed"] if keep_framed else now)
                self.apply(nxt, shot, f"standby: {lead}" + (f" ({plan_kind(by_name[lead])} bounds)" if fit else "") +
                           (f" ({shot['vehicle']})" if shot.get("vehicle") else "") +
                           (f" ({shot['did']})" if shot.get("did") else ""), scores, now, quiet=True)
        if want and nxt and self.state[nxt["slot"]].get("subject") == want and self.ready(nxt["slot"], now):
            self.cut(nxt["slot"], reason if not need else self.resumed_why(resumed) if resumed else floor_reason if floor_reason
                     and self.balance_surface(by_name.get(want)) == due["surface"] else need_reason or
                     self.need_why(subj, want) + self.surface_note(want, by_name), now)
            self.want[nxt["slot"]] = (self.state[nxt["slot"]]["zoom"], now)
            self.after_quiet = False
            if need and dropped:
                self.resume = None
            if resumed:
                self.resume = None
                self.onair_since = max(resumed["since"], now - self.cfg["onair_dwell"] + self.cfg["resume_min"])
        elif want and not nxt:  # one client only (POG_CAMS=1): the cut is a jump of the client on air to the subject
            fit = self.plan_zoom(by_name[want])
            z = fit or self.zoom_for(by_name[want], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            shot = self.body_shot(want, by_name, z, now, fit)
            why = reason if not need else self.resumed_why(resumed) if resumed else floor_reason if floor_reason \
                and self.balance_surface(by_name.get(want)) == due["surface"] else need_reason or \
                self.need_why(subj, want) + self.surface_note(want, by_name)
            self.retarget(shot, why, scores, now)
            self.after_quiet = False
            if need and dropped:
                self.resume = None
            if resumed:
                self.resume = None
                self.onair_since = max(resumed["since"], now - self.cfg["onair_dwell"] + self.cfg["resume_min"])

    def need_why(self, subj, want):
        """The cut's reason when nothing holds the camera: after a quiet view (batch222), the subject gone, the start."""
        if subj in ("@tour", "@map", "@platform") and self.after_quiet:
            return f"after the quiet view: {want}" + ("" if self.stale_s(want, self.step_t) < self.cfg["still_cut"] else " (all stale)")
        return f"{subj} unavailable" if subj else "initial"

    def keep_vehicle(self, cur, by_name, now):
        """(batch222) The agent on air drives a vehicle by remote view: the view on the vehicle, moved with it; back to
        the character when the read is stale or the vehicle is near it. True when it handled the shot."""
        subj = cur["subject"]
        a = by_name.get(subj)
        spot = self.vehicle_spot(a, now, held=bool(cur.get("vehicle")))
        solo = self.cfg["solo_zoom"]
        flip = now - self.vehicle_swapped.get(subj, -1e9) < self.cfg["vehicle_flip"]  # (batch224) no flapping
        if cur.get("vehicle"):
            if not spot and flip:
                return True
            if not spot:
                if self.mode == "trio":
                    return True  # (the big tile keeps its shot until the trio ends)
                z = self.zoom_for(a, solo) or solo
                self.swap({"agents": [subj], "follow": subj, "zoom": z, "solo_zoom": z, "subject": subj},
                          f"{subj}: back to the character (its vehicle's read is stale, or the vehicle is near)", now)
                self.vehicle_swapped[subj] = now
                return True
            p = cur.get("position") or {}
            lead = self.cfg["vehicle_ahead"]
            ahead = self.vehicle_spot(a, now, held=True, ahead=lead) or spot
            hw, hh = self.frame_half(cur.get("game_zoom") or cur["zoom"])  # (the zoom the game was sent)
            box = self.cfg["vehicle_still_box"]
            far, cap = dist(ahead, spot), box * min(hw, hh)
            if far > cap:  # (batch245) the aim at most the inner box ahead: at a stop the vehicle is still in the box
                ahead = dict(ahead, x=round(spot["x"] + (ahead["x"] - spot["x"]) * cap / far, 1),
                             y=round(spot["y"] + (ahead["y"] - spot["y"]) * cap / far, 1))
            d = dist(ahead, p) if p else 1e9
            inside = bool(p) and abs(spot["x"] - p["x"]) <= hw and abs(spot["y"] - p["y"]) <= hh
            if cur is self.state.get(self.onair):
                # (batch245) dwell counts while the vehicle is in the frame: held back while the view catches up
                last = cur.get("frame_t", now)
                if not inside:
                    self.onair_since = min(now, self.onair_since + max(0.0, now - last))
                cur["frame_t"] = now
            v = a.get("remote_vehicle") if isinstance(a.get("remote_vehicle"), dict) else {}
            if inside and not self.vehicle_where(v, now)[1] and abs(spot["x"] - p["x"]) <= hw * box and \
                    abs(spot["y"] - p["y"]) <= hh * box and self.vehicle_activity(a, now) != "walking":
                return True  # (batch245) stopped well inside the frame: the frame stays (no snap back at a stop)
            if d >= self.cfg["reframe_tiles"] and now - cur.get("sent", 0) >= 1.0:
                # (batch232) aimed lead s on, at no less than vehicle_glide x its speed: the view keeps up with it
                v = a.get("remote_vehicle") if isinstance(a.get("remote_vehicle"), dict) else {}
                kmh = v.get("speed") if isinstance(v.get("speed"), (int, float)) else (
                    self.cfg["vehicle_speed"] if v.get("target") else 0.0)
                glide = max(d / lead, self.cfg["vehicle_glide"] * kmh / 3.6)
                mv, last = (ahead["x"] - p["x"], ahead["y"] - p["y"]) if p else (0.0, 0.0), cur.get("vmove")
                near = bool(p) and abs(spot["x"] - p["x"]) <= 1.5 * hw and abs(spot["y"] - p["y"]) <= 1.5 * hh
                if near and last and mv[0] * last[0] + mv[1] * last[1] < 0:
                    # (batch245) back after a stop the aim ran past (up to a poll's walk): a settle, quicker when the
                    # vehicle is at the frame's edge
                    glide = d / self.cfg["vehicle_settle"] * (1.0 if inside else 2.0)
                target = {k: v for k, v in cur.items() if k != "jump"}
                target.update(position={"x": ahead["x"], "y": ahead["y"]}, vehicle=spot["label"], vmove=mv,
                              glide=round(max(1.0, min(200.0, glide)), 2))
                self.apply(self.slot(self.onair), target, "reframe", {}, now, quiet=True)
            return True
        if spot and self.mode != "trio" and not flip:
            self.swap(self.body_shot(subj, by_name, solo, now), f"vehicle: {spot['label']}", now)
            self.vehicle_swapped[subj] = now
            return True
        return False

    def keep_did(self, cur, by_name, now):
        """(batch240) The agent on air built away from its character (did_spot): the view where that landed while it is
        did_hold old, a newer one's when it builds elsewhere; then back to the character. True when it handled the shot."""
        subj = cur["subject"]
        a = by_name.get(subj)
        spot = self.did_spot(a, now)
        flip = now - self.vehicle_swapped.get(subj, -1e9) < self.cfg["vehicle_flip"]
        if cur.get("did"):
            p = cur.get("position") or {}
            same = spot and p and spot["surface"] == cur.get("surface") and dist(spot, p) < self.cfg["reframe_tiles"]
            if same or flip or self.mode == "trio":
                return True
            if spot:
                shot, why = self.body_shot(subj, by_name, self.cfg["solo_zoom"], now), f"build: {spot['label']}"
            else:
                z = self.zoom_for(a, self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
                shot = {"agents": [subj], "follow": subj, "zoom": z, "solo_zoom": z, "subject": subj}
                why = f"{subj}: back to the character (its build is {int(self.cfg['did_hold'])} s old)"
            self.swap(shot, why, now)
            self.vehicle_swapped[subj] = now
            return True
        if spot and self.mode != "trio" and not flip and not cur.get("vehicle"):
            self.swap(self.body_shot(subj, by_name, self.cfg["solo_zoom"], now), f"build: {spot['label']}", now)
            self.vehicle_swapped[subj] = now
            return True
        return False

    def swap(self, target, reason, now):
        """(batch222) The same subject in another shot (its vehicle, or its character again): framed on a standby and
        cut once it is there, as any cut; one client: moved on air."""
        if self.pending:
            return
        since = self.onair_since  # (batch232) the same story goes on: its dwell is not started again
        nxt = self.next_slot()
        if not nxt:
            self.retarget(target, reason, {}, now)
            self.onair_since = since
            return
        self.frame_on(nxt, target, f"standby: {reason}", {}, now)
        self.pending = {"slot": nxt["slot"], "reason": reason, "since": since}

    def keep(self, cur, by_name, now):
        """Zoom follows the on-air subject's activity once it has lasted zoom_settle (no pairs on air); while a big
        action with bounds runs, the zoom fits them."""
        if self.keep_vehicle(cur, by_name, now) or self.keep_did(cur, by_name, now):
            return
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
            if key == "main" and t.get("subject") in ("@look", "@tour") and t.get("look"):
                row["look"] = t["look"]  # the on-air card: "📍 The western wall" (lookcam.py); a base tour's own
            if t.get("tour"):
                row["tour"] = t["tour"]  # (batch222) a base tour: {surface, label, machines}
            if t.get("vehicle"):
                row["vehicle"] = t["vehicle"]  # (batch222) "Opus · spidertron by remote view": its vehicle, not its body
            if t.get("did"):
                row["did"] = t["did"]  # (batch240) "Astra · ghosts placed": where its build landed, not its body
            f = self.follow
            if key == "main" and f and f["label"] and now < f["until"] and f["agent"] in (t.get("agents") or []):
                row["follow"] = f["label"]  # the on-air card: "Following Sol · Sol vs the Demolisher"
            out[key] = row
        return out
